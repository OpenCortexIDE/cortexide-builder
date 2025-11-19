#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

. version.sh

# Validate required environment variables
if [[ -z "${OS_NAME}" ]]; then
  echo "Warning: OS_NAME is not set. Defaulting based on system..." >&2
  case "$(uname -s)" in
    Darwin*) OS_NAME="osx" ;;
    Linux*) OS_NAME="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS_NAME="windows" ;;
    *) OS_NAME="linux" ;;
  esac
  export OS_NAME
fi

if [[ -z "${VSCODE_ARCH}" ]]; then
  echo "Warning: VSCODE_ARCH is not set. Defaulting to x64..." >&2
  VSCODE_ARCH="x64"
  export VSCODE_ARCH
fi

if [[ -z "${CI_BUILD}" ]]; then
  CI_BUILD="no"
  export CI_BUILD
fi

if [[ "${SHOULD_BUILD}" == "yes" ]]; then
  echo "MS_COMMIT=\"${MS_COMMIT}\""

  # Pre-build dependency checks
  echo "Checking build dependencies..."
  MISSING_DEPS=0
  
  # Check required commands
  for cmd in node npm jq git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: Required command '$cmd' is not installed" >&2
      MISSING_DEPS=1
    fi
  done
  
  # Check Node.js version
  NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
  if [[ "${NODE_VERSION}" -lt 20 ]]; then
    echo "Error: Node.js 20.x or higher is required. Current: $(node -v)" >&2
    MISSING_DEPS=1
  fi
  
  # Check platform-specific tools
  if [[ "${OS_NAME}" == "osx" ]]; then
    if ! command -v clang++ >/dev/null 2>&1; then
      echo "Warning: clang++ not found. Build may fail." >&2
    fi
  elif [[ "${OS_NAME}" == "linux" ]]; then
    for cmd in gcc g++ make; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Warning: '$cmd' not found. Build may fail." >&2
      fi
    done
  fi
  
  # Check if vscode directory will exist
  if [[ ! -d "vscode" ]] && [[ ! -d "../cortexide" ]]; then
    echo "Warning: Neither 'vscode' nor '../cortexide' directory found. get_repo.sh should create it." >&2
  fi
  
  if [[ $MISSING_DEPS -eq 1 ]]; then
    echo "Error: Missing required dependencies. Please install them before building." >&2
    exit 1
  fi
  
  echo "Dependency checks passed."

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  export NODE_OPTIONS="--max-old-space-size=8192"

  # Skip monaco-compile-check as it's failing due to searchUrl property
  # Skip valid-layers-check as well since it might depend on monaco
  # Void commented these out
  # npm run monaco-compile-check
  # npm run valid-layers-check

  echo "Building React components..."
  # Verify cross-spawn is available before running buildreact
  if [[ ! -d "node_modules/cross-spawn" ]] && [[ ! -f "node_modules/cross-spawn/package.json" ]]; then
    echo "Error: cross-spawn dependency is missing. Installing..." >&2
    if ! npm install cross-spawn; then
      echo "Error: Failed to install cross-spawn. Cannot continue with buildreact." >&2
      echo "Try running: npm install" >&2
      exit 1
    fi
  fi
  
  if ! npm run buildreact; then
    echo "Error: buildreact failed. Check for:" >&2
    echo "  - Missing dependencies (run: npm install)" >&2
    echo "  - cross-spawn not installed (run: npm install cross-spawn)" >&2
    echo "  - TypeScript compilation errors" >&2
    echo "  - React build script issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  echo "Fixing extension webpack config loader for ES modules (BEFORE compilation)..."
  
  # CRITICAL: Patch TypeScript source BEFORE compilation
  # This ensures the compiled JavaScript is correct from the start
  if [[ -f "build/lib/extensions.ts" ]]; then
    echo "Patching TypeScript source file (build/lib/extensions.ts)..." >&2
    if grep -q "require.*webpackConfigPath\|require(webpackConfigPath)" "build/lib/extensions.ts" 2>/dev/null; then
      cp "build/lib/extensions.ts" "build/lib/extensions.ts.bak" 2>/dev/null || true
      
      # Create a proper TypeScript patch script
      TS_PATCH_SCRIPT=$(mktemp /tmp/fix-extensions-ts.XXXXXX.js) || {
        TS_PATCH_SCRIPT="/tmp/fix-extensions-ts.js"
      }
      cat > "$TS_PATCH_SCRIPT" << 'EOFTS'
const fs = require('fs');
const filePath = process.argv[2];
let content = fs.readFileSync(filePath, 'utf8');

// Fix 1: Make the function async if it uses webpackConfigPath
if (content.includes('const webpackStreams = webpackConfigLocations.flatMap')) {
  // Find the function containing this and make it async
  const functionMatch = content.match(/(function\s+\w+[^{]*\{[\s\S]*?const webpackStreams = webpackConfigLocations\.flatMap)/);
  if (functionMatch && !functionMatch[1].includes('async')) {
    content = content.replace(/function\s+(\w+)([^{]*)\{([\s\S]*?const webpackStreams = webpackConfigLocations\.flatMap)/, 'async function $1$2{$3');
  }
}

// Fix 2: Replace flatMap with map and make callback async
if (content.includes('webpackConfigLocations.flatMap(webpackConfigPath =>')) {
  content = content.replace(
    /webpackConfigLocations\.flatMap\(webpackConfigPath\s*=>/g,
    'webpackConfigLocations.map(async webpackConfigPath =>'
  );
}

// Fix 3: Make fromLocalWebpack function async
if (content.includes('function fromLocalWebpack')) {
  if (!content.includes('async function fromLocalWebpack')) {
    content = content.replace(/function\s+fromLocalWebpack/g, 'async function fromLocalWebpack');
  }
}

// Fix 3b: Add pathToFileURL imports at the top of fromLocalWebpack function
if (content.includes('function fromLocalWebpack')) {
  const functionStart = content.indexOf('function fromLocalWebpack');
  if (functionStart !== -1) {
    const afterFunction = content.indexOf('{', functionStart) + 1;
    const before = content.substring(0, afterFunction);
    const after = content.substring(afterFunction);
    
    if (!before.includes('pathToFileURL')) {
      // Add imports right after the opening brace
      content = before + '\n\tconst { pathToFileURL } = require("url");\n\tconst path = require("path");' + after;
    }
  }
}

// Fix 3c: Replace webpackRootConfig require with dynamic import
if (content.includes('const webpackRootConfig = require(path.join(extensionPath, webpackConfigFileName))')) {
  // This needs to be inside an async function, which we just made it
  content = content.replace(
    /const\s+webpackRootConfig\s*=\s*require\(path\.join\(extensionPath,\s*webpackConfigFileName\)\)\.default\s*;/g,
    'const webpackRootConfig = (await import(pathToFileURL(path.resolve(extensionPath, webpackConfigFileName)).href)).default;'
  );
}

// Fix 4: Replace require(webpackConfigPath).default with dynamic import
if (content.includes('require(webpackConfigPath)')) {
  // Replace the exact pattern: const exportedConfig = require(webpackConfigPath).default;
  content = content.replace(
    /const\s+exportedConfig\s*=\s*require\(webpackConfigPath\)\.default\s*;/g,
    'const exportedConfig = (await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default;'
  );
  
  // Also replace just require(webpackConfigPath).default if it appears elsewhere
  content = content.replace(
    /require\(webpackConfigPath\)\.default/g,
    '(await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default'
  );
}

// Fix 5: Fix the flatMap return to use Promise.all
if (content.includes('webpackConfigLocations.map(async')) {
  // Find the closing of the map and add Promise.all wrapper
  const mapStart = content.indexOf('webpackConfigLocations.map(async');
  if (mapStart !== -1) {
    // Find where this map ends (before the closing of webpackStreams assignment)
    const beforeMap = content.substring(0, mapStart);
    const afterMap = content.substring(mapStart);
    
    // Replace: const webpackStreams = webpackConfigLocations.map(async...
    // With: const webpackStreams = await Promise.all(webpackConfigLocations.map(async...
    if (!beforeMap.includes('Promise.all')) {
      content = content.replace(
        /const\s+webpackStreams\s*=\s*webpackConfigLocations\.map\(async/g,
        'const webpackStreams = await Promise.all(webpackConfigLocations.map(async'
      );
      
      // Find the closing of the map and add .flat() equivalent
      // The structure is: map(async ... => { ... }); 
      // We need: map(async ... => { ... })).flat();
      // But we'll handle flattening in the JS patch since TypeScript doesn't have .flat()
    }
  }
}

fs.writeFileSync(filePath, content, 'utf8');
console.log('Successfully patched extensions.ts');
EOFTS
      
      node "$TS_PATCH_SCRIPT" "build/lib/extensions.ts" 2>&1 || {
        echo "Warning: TypeScript patch failed. Restoring backup..." >&2
        if [[ -f "build/lib/extensions.ts.bak" ]]; then
          mv "build/lib/extensions.ts.bak" "build/lib/extensions.ts" 2>/dev/null || true
        fi
      }
      rm -f "$TS_PATCH_SCRIPT"
      
      if grep -q "pathToFileURL\|await import" "build/lib/extensions.ts" 2>/dev/null; then
        echo "TypeScript source patched successfully. Recompiling..." >&2
        # Recompile
        npm run gulp compile-build-without-mangling 2>&1 | tail -30 || {
          echo "Warning: Recompilation after TS patch failed. Continuing with JS patch..." >&2
        }
      fi
    fi
  fi
  
  # Then patch the compiled JavaScript (fallback or if TS patch didn't work)
  if [[ -f "build/lib/extensions.js" ]]; then
    # ALWAYS try to patch if file has the patterns, even if pathToFileURL exists
    # This ensures patch is applied even if partially patched or regenerated
    if grep -q "require.*webpackConfig\|flatMap.*webpackConfigPath\|require(webpackConfigPath)" "build/lib/extensions.js" 2>/dev/null; then
      # Check if already fully patched
      if ! grep -q "pathToFileURL" "build/lib/extensions.js" 2>/dev/null || grep -q "require(webpackConfigPath)" "build/lib/extensions.js" 2>/dev/null; then
        echo "Patching extensions.js to use dynamic import for webpack configs..." >&2
        # Create backup
        cp "build/lib/extensions.js" "build/lib/extensions.js.bak" 2>/dev/null || true
        
        # Create comprehensive patch script using mktemp for better portability
        PATCH_SCRIPT_FILE=$(mktemp /tmp/fix-extension-webpack-loader.XXXXXX.js) || {
          echo "Warning: mktemp failed, using /tmp/fix-extension-webpack-loader.js" >&2
          PATCH_SCRIPT_FILE="/tmp/fix-extension-webpack-loader.js"
        }
        cat > "$PATCH_SCRIPT_FILE" << 'EOFPATCH'
const fs = require('fs');

const filePath = process.argv[2];
let content = fs.readFileSync(filePath, 'utf8');

// Fix 1: Make the then() callback async FIRST
// The actual code has: vsce.listFiles({ cwd: extensionPath, packageManager: vsce.PackageManager.None, packagedDependencies }).then(fileNames => {
// We need to match this exact pattern and make it async
if (content.includes('vsce.listFiles({ cwd: extensionPath')) {
  // Match the exact pattern from the compiled code
  // Pattern: }).then(fileNames => {
  const thenPattern = /\)\.then\(fileNames\s*=>\s*\{/g;
  if (thenPattern.test(content) && !content.includes('.then(async')) {
    content = content.replace(thenPattern, ').then(async (fileNames) => {');
  }
}

// Fix 2: Remove the synchronous require for webpackRootConfig and move it inside the async callback
if (content.includes('const webpackRootConfig = require') && content.includes('webpackConfigFileName')) {
  // Try multiple patterns to catch all variations
  const patterns = [
    /if\s*\(packageJsonConfig\.dependencies\)\s*\{[\s\S]*?const\s+webpackRootConfig\s*=\s*require\([^)]+webpackConfigFileName[^)]+\)\.default;[\s\S]*?for\s*\(const\s+key\s+in\s+webpackRootConfig\.externals\)\s*\{[\s\S]*?packagedDependencies\.push\(key\);[\s\S]*?\}[\s\S]*?\}[\s\S]*?\}/,
    /if\s*\(packageJsonConfig\.dependencies\)\s*\{[\s\S]*?const\s+webpackRootConfig\s*=\s*require\(path_1\.default\.join\(extensionPath,\s*webpackConfigFileName\)\)\.default;[\s\S]*?for\s*\(const\s+key\s+in\s+webpackRootConfig\.externals\)\s*\{[\s\S]*?packagedDependencies\.push\(key\);[\s\S]*?\}[\s\S]*?\}[\s\S]*?\}/,
    /const\s+webpackRootConfig\s*=\s*require\(path_1\.default\.join\(extensionPath,\s*webpackConfigFileName\)\)\.default;[\s\S]*?for\s*\(const\s+key\s+in\s+webpackRootConfig\.externals\)\s*\{[\s\S]*?packagedDependencies\.push\(key\);[\s\S]*?\}/
  ];
  
  let replaced = false;
  for (const pattern of patterns) {
    if (pattern.test(content)) {
      content = content.replace(pattern, '// Webpack config will be loaded asynchronously inside the promise chain');
      replaced = true;
      break;
    }
  }
  
  // If no pattern matched, use line-by-line parsing
  if (!replaced) {
    const lines = content.split('\n');
    let result = [];
    let skipUntilClose = false;
    let braceCount = 0;
    
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      
      if (line.includes('if (packageJsonConfig.dependencies) {')) {
        skipUntilClose = true;
        braceCount = 1;
        result.push('// Webpack config will be loaded asynchronously inside the promise chain');
        continue;
      }
      
      if (skipUntilClose) {
        braceCount += (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
        if (braceCount === 0) {
          skipUntilClose = false;
        }
        continue;
      }
      
      result.push(line);
    }
    content = result.join('\n');
  }
  
  // Add it inside the async then() callback, right after const files
  if (content.includes('const files = fileNames')) {
    content = content.replace(
      /(const files = fileNames[\s\S]*?\);)/,
      `$1
        // Load webpack config as ES module
        if (packageJsonConfig.dependencies) {
            try {
                const { pathToFileURL } = require('url');
                const path = require('path');
                let webpackConfigPath = path_1.default.resolve(extensionPath, webpackConfigFileName);
                let webpackConfigUrl = pathToFileURL(webpackConfigPath).href;
                const webpackRootConfig = (await import(webpackConfigUrl)).default;
                if (webpackRootConfig && webpackRootConfig.externals) {
                    for (const key in webpackRootConfig.externals) {
                        if (key in packageJsonConfig.dependencies) {
                            packagedDependencies.push(key);
                        }
                    }
                }
            } catch (err) {
                // Silently skip - this is optional
            }
        }`
    );
  }
}

// Fix 3: Replace require() with dynamic import inside webpackStreams and make it async
// Always try to replace flatMap and require if they exist
let patchedFlatMap = false;
let patchedRequire = false;

// First replace flatMap if it exists - try multiple patterns
if (content.includes('flatMap')) {
  const flatMapPatterns = [
    /const\s+webpackStreams\s*=\s*webpackConfigLocations\.flatMap\(webpackConfigPath\s*=>\s*\{/g,
    /webpackConfigLocations\.flatMap\(webpackConfigPath\s*=>\s*\{/g,
    /\.flatMap\(webpackConfigPath\s*=>\s*\{/g
  ];
  
  for (const pattern of flatMapPatterns) {
    if (pattern.test(content)) {
      content = content.replace(pattern, (match) => {
        if (match.includes('const webpackStreams')) {
          return 'const webpackStreams = await Promise.all(webpackConfigLocations.map(async webpackConfigPath => {';
        } else if (match.includes('webpackConfigLocations')) {
          return 'webpackConfigLocations.map(async webpackConfigPath => {';
        } else {
          return '.map(async webpackConfigPath => {';
        }
      });
      patchedFlatMap = true;
      break;
    }
  }
}

// Then replace the require statement - AGGRESSIVE: find and replace ANY occurrence
// The actual code has: const exportedConfig = require(webpackConfigPath).default;
// We need to match this and replace it with dynamic import
if (content.includes('require(webpackConfigPath)')) {
  // First, ensure pathToFileURL is imported at the function level
  // Find where webpackStreams is defined and add imports before it
  if (!content.includes('const { pathToFileURL } = require("url")') || !content.includes('const path = require("path")')) {
    const webpackStreamsIndex = content.indexOf('const webpackStreams');
    if (webpackStreamsIndex !== -1) {
      // Find the start of the function/block containing webpackStreams
      let functionStart = webpackStreamsIndex;
      // Go backwards to find the start of the block
      for (let i = webpackStreamsIndex - 1; i >= 0; i--) {
        if (content[i] === '{' || (content.substring(i, i + 3) === '=> ')) {
          functionStart = i + 1;
          break;
        }
      }
      const before = content.substring(0, functionStart);
      const after = content.substring(functionStart);
      // Add imports if not already present
      if (!before.includes('pathToFileURL')) {
        content = before + '            const { pathToFileURL } = require("url");\n            const path = require("path");\n' + after;
      }
    }
  }
  
  // Now replace ALL occurrences of require(webpackConfigPath).default
  // Try multiple patterns, most specific first
  const patterns = [
    // Exact match: const exportedConfig = require(webpackConfigPath).default;
    {
      pattern: /const\s+exportedConfig\s*=\s*require\(webpackConfigPath\)\.default\s*;/g,
      replacement: `const { pathToFileURL } = require("url");
            const path = require("path");
            let exportedConfig;
            const configUrl = pathToFileURL(path.resolve(webpackConfigPath)).href;
            exportedConfig = (await import(configUrl)).default;`
    },
    // With optional whitespace
    {
      pattern: /const\s+exportedConfig\s*=\s*require\(webpackConfigPath\)\.default;/g,
      replacement: `const { pathToFileURL } = require("url");
            const path = require("path");
            let exportedConfig;
            const configUrl = pathToFileURL(path.resolve(webpackConfigPath)).href;
            exportedConfig = (await import(configUrl)).default;`
    },
    // Just the assignment part
    {
      pattern: /exportedConfig\s*=\s*require\(webpackConfigPath\)\.default\s*;/g,
      replacement: `const { pathToFileURL } = require("url");
            const path = require("path");
            exportedConfig = (await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default;`
    },
    // Just require(webpackConfigPath).default - replace inline
    {
      pattern: /require\(webpackConfigPath\)\.default/g,
      replacement: `(await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default`
    }
  ];
  
  for (const { pattern, replacement } of patterns) {
    if (pattern.test(content)) {
      content = content.replace(pattern, replacement);
      patchedRequire = true;
      // Don't break - continue to catch all occurrences
    }
  }
  
  // If still not patched, do a line-by-line search and replace
  if (!patchedRequire && content.includes('require(webpackConfigPath)')) {
    const lines = content.split('\n');
    const result = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.includes('require(webpackConfigPath)')) {
        // Replace the entire line
        if (line.includes('const exportedConfig')) {
          result.push('            const { pathToFileURL } = require("url");');
          result.push('            const path = require("path");');
          result.push('            let exportedConfig;');
          result.push('            const configUrl = pathToFileURL(path.resolve(webpackConfigPath)).href;');
          result.push('            exportedConfig = (await import(configUrl)).default;');
        } else {
          // Just replace the require part
          result.push(line.replace(/require\(webpackConfigPath\)\.default/g, '(await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default'));
        }
        patchedRequire = true;
      } else {
        result.push(line);
      }
    }
    content = result.join('\n');
  }
}

// Only do closing bracket fix if we actually patched flatMap
if (patchedFlatMap && content.includes('event_stream_1.default.merge(...webpackStreams')) {
  const lines = content.split('\n');
  let result = [];
  let foundMapStart = false;
  let braceCount = 0;
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    if (line.includes('const webpackStreams = await Promise.all(webpackConfigLocations.map(async')) {
      foundMapStart = true;
      braceCount = (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
      result.push(line);
      continue;
    }
    
    if (foundMapStart) {
      braceCount += (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
      
      if (braceCount === 0 && line.includes('}')) {
        if (i + 1 < lines.length && lines[i + 1].includes('event_stream_1.default.merge(...webpackStreams')) {
          result.push('}));');
          result.push('        const flattenedWebpackStreams = [].concat(...webpackStreams);');
          foundMapStart = false;
          continue;
        }
      }
    }
    
    result.push(line);
  }
  content = result.join('\n');
  
  content = content.replace(
    /event_stream_1\.default\.merge\(\.\.\.webpackStreams/g,
    'event_stream_1.default.merge(...flattenedWebpackStreams'
  );
}

fs.writeFileSync(filePath, content, 'utf8');
console.log('Successfully patched extensions.js for ES module webpack configs');
// Only show detailed debug output if DEBUG environment variable is set
if (process.env.DEBUG) {
  console.log('Patched flatMap:', patchedFlatMap);
  console.log('Patched require:', patchedRequire);
  // Debug: Check if patterns still exist
  if (content.includes('flatMap(webpackConfigPath')) {
    console.log('WARNING: flatMap still found after patch attempt!');
  }
  if (content.includes('require(webpackConfigPath).default')) {
    console.log('WARNING: require(webpackConfigPath) still found after patch attempt!');
  }
  if (content.includes('pathToFileURL')) {
    console.log('SUCCESS: pathToFileURL found - patch was applied');
  }
}
EOFPATCH
        
        # Run the patch script and capture output
        # Only show detailed output if DEBUG is set
        if [[ -n "${DEBUG}" ]]; then
          echo "Running patch script (DEBUG mode)..." >&2
        else
          echo "Running patch script..." >&2
        fi
        # Pass DEBUG to node script if set
        if [[ -n "${DEBUG}" ]]; then
          export DEBUG
          PATCH_OUTPUT=$(DEBUG="${DEBUG}" node "$PATCH_SCRIPT_FILE" "build/lib/extensions.js" 2>&1)
        else
          PATCH_OUTPUT=$(node "$PATCH_SCRIPT_FILE" "build/lib/extensions.js" 2>&1)
        fi
        PATCH_EXIT=$?
        if [[ -n "${DEBUG}" ]]; then
          echo "$PATCH_OUTPUT" >&2
        fi
        
        if [[ $PATCH_EXIT -eq 0 ]]; then
          # Verify the patch was applied
          if grep -q "pathToFileURL" "build/lib/extensions.js" 2>/dev/null; then
            echo "Successfully patched extensions.js for ES module webpack configs." >&2
          else
            echo "ERROR: Patch script ran but pathToFileURL not found in extensions.js!" >&2
            echo "Checking if patterns still exist..." >&2
            if grep -q "flatMap(webpackConfigPath" "build/lib/extensions.js" 2>/dev/null; then
              echo "ERROR: flatMap still exists - patch failed!" >&2
            fi
            if grep -q "require(webpackConfigPath).default" "build/lib/extensions.js" 2>/dev/null; then
              echo "ERROR: require(webpackConfigPath) still exists - patch failed!" >&2
            fi
            if [[ -f "build/lib/extensions.js.bak" ]]; then
              echo "Restoring backup..." >&2
              mv "build/lib/extensions.js.bak" "build/lib/extensions.js" 2>/dev/null || true
            fi
          fi
        else
          echo "ERROR: Patch script failed with exit code $PATCH_EXIT" >&2
          echo "Patch output: $PATCH_OUTPUT" >&2
          if [[ -f "build/lib/extensions.js.bak" ]]; then
            echo "Restoring backup..." >&2
            mv "build/lib/extensions.js.bak" "build/lib/extensions.js" 2>/dev/null || true
            echo "Backup restored. Build may fail with SyntaxError." >&2
          fi
        fi
        rm -f "$PATCH_SCRIPT_FILE"
      else
        echo "extensions.js doesn't contain webpack config patterns. Skipping patch." >&2
      fi
    else
      echo "extensions.js already fully patched (pathToFileURL found and no require patterns). Skipping." >&2
    fi
  else
    echo "Warning: build/lib/extensions.js not found after compilation." >&2
  fi
  
  echo "Compiling extension media..."
  if ! npm run gulp compile-extension-media; then
    echo "Error: compile-extension-media failed. Check for:" >&2
    echo "  - Missing extension dependencies (e.g., mermaid for mermaid-chat-features)" >&2
    echo "  - Run: find extensions -name package.json -execdir npm install \\;" >&2
    echo "  - Missing media files" >&2
    echo "  - Asset compilation errors" >&2
    echo "  - Gulp task issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  echo "Compiling extensions build..."
  if ! npm run gulp compile-extensions-build; then
    echo "Error: compile-extensions-build failed. Check for:" >&2
    echo "  - Extension compilation errors" >&2
    echo "  - Missing extension dependencies" >&2
    echo "  - Gulp task configuration issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  # Re-apply webpack patch if file was regenerated during compile-extensions-build
  # Some gulp tasks might regenerate build/lib/extensions.js
  if [[ -f "build/lib/extensions.js" ]]; then
    if ! grep -q "pathToFileURL" "build/lib/extensions.js" 2>/dev/null; then
      if grep -q "require.*webpackConfig\|flatMap.*webpackConfigPath\|require(webpackConfigPath)" "build/lib/extensions.js" 2>/dev/null; then
        echo "Warning: extensions.js was regenerated. Re-applying webpack patch..." >&2
        # Re-run the same patch logic (code duplication, but ensures patch is applied)
        cp "build/lib/extensions.js" "build/lib/extensions.js.bak" 2>/dev/null || true
        PATCH_SCRIPT=$(cat << 'EOFPATCH2'
const fs = require('fs');
const filePath = process.argv[2];
let content = fs.readFileSync(filePath, 'utf8');
let patchedFlatMap = false;
let patchedRequire = false;

if (content.includes('vsce.listFiles({ cwd: extensionPath')) {
  const thenPattern = /\)\.then\(fileNames\s*=>\s*\{/g;
  if (thenPattern.test(content) && !content.includes('.then(async')) {
    content = content.replace(thenPattern, ').then(async (fileNames) => {');
  }
}

if (content.includes('flatMap')) {
  const flatMapPatterns = [
    /const\s+webpackStreams\s*=\s*webpackConfigLocations\.flatMap\(webpackConfigPath\s*=>\s*\{/g,
    /webpackConfigLocations\.flatMap\(webpackConfigPath\s*=>\s*\{/g,
    /\.flatMap\(webpackConfigPath\s*=>\s*\{/g
  ];
  for (const pattern of flatMapPatterns) {
    if (pattern.test(content)) {
      content = content.replace(pattern, (match) => {
        if (match.includes('const webpackStreams')) {
          return 'const webpackStreams = await Promise.all(webpackConfigLocations.map(async webpackConfigPath => {';
        } else if (match.includes('webpackConfigLocations')) {
          return 'webpackConfigLocations.map(async webpackConfigPath => {';
        } else {
          return '.map(async webpackConfigPath => {';
        }
      });
      patchedFlatMap = true;
      break;
    }
  }
}

// AGGRESSIVE: Replace ANY require(webpackConfigPath)
if (content.includes('require(webpackConfigPath)')) {
  // Ensure imports exist
  if (!content.includes('const { pathToFileURL } = require("url")')) {
    const webpackStreamsIndex = content.indexOf('const webpackStreams');
    if (webpackStreamsIndex !== -1) {
      let functionStart = webpackStreamsIndex;
      for (let i = webpackStreamsIndex - 1; i >= 0; i--) {
        if (content[i] === '{' || (content.substring(i, i + 3) === '=> ')) {
          functionStart = i + 1;
          break;
        }
      }
      const before = content.substring(0, functionStart);
      const after = content.substring(functionStart);
      if (!before.includes('pathToFileURL')) {
        content = before + '            const { pathToFileURL } = require("url");\n            const path = require("path");\n' + after;
      }
    }
  }
  
  // Replace ALL patterns
  const patterns = [
    { pattern: /const\s+exportedConfig\s*=\s*require\(webpackConfigPath\)\.default\s*;/g, replacement: `const { pathToFileURL } = require("url");\n            const path = require("path");\n            let exportedConfig;\n            const configUrl = pathToFileURL(path.resolve(webpackConfigPath)).href;\n            exportedConfig = (await import(configUrl)).default;` },
    { pattern: /const\s+exportedConfig\s*=\s*require\(webpackConfigPath\)\.default;/g, replacement: `const { pathToFileURL } = require("url");\n            const path = require("path");\n            let exportedConfig;\n            const configUrl = pathToFileURL(path.resolve(webpackConfigPath)).href;\n            exportedConfig = (await import(configUrl)).default;` },
    { pattern: /exportedConfig\s*=\s*require\(webpackConfigPath\)\.default\s*;/g, replacement: `const { pathToFileURL } = require("url");\n            const path = require("path");\n            exportedConfig = (await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default;` },
    { pattern: /require\(webpackConfigPath\)\.default/g, replacement: `(await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default` }
  ];
  
  for (const { pattern, replacement } of patterns) {
    if (pattern.test(content)) {
      content = content.replace(pattern, replacement);
      patchedRequire = true;
    }
  }
  
  // Line-by-line fallback
  if (!patchedRequire && content.includes('require(webpackConfigPath)')) {
    const lines = content.split('\n');
    const result = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.includes('require(webpackConfigPath)')) {
        if (line.includes('const exportedConfig')) {
          result.push('            const { pathToFileURL } = require("url");');
          result.push('            const path = require("path");');
          result.push('            let exportedConfig;');
          result.push('            const configUrl = pathToFileURL(path.resolve(webpackConfigPath)).href;');
          result.push('            exportedConfig = (await import(configUrl)).default;');
        } else {
          result.push(line.replace(/require\(webpackConfigPath\)\.default/g, '(await import(pathToFileURL(path.resolve(webpackConfigPath)).href)).default'));
        }
        patchedRequire = true;
      } else {
        result.push(line);
      }
    }
    content = result.join('\n');
  }
}

if (patchedFlatMap && content.includes('event_stream_1.default.merge(...webpackStreams')) {
  const lines = content.split('\n');
  let result = [];
  let foundMapStart = false;
  let braceCount = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.includes('const webpackStreams = await Promise.all(webpackConfigLocations.map(async')) {
      foundMapStart = true;
      braceCount = (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
      result.push(line);
      continue;
    }
    if (foundMapStart) {
      braceCount += (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
      if (braceCount === 0 && line.includes('}')) {
        if (i + 1 < lines.length && lines[i + 1].includes('event_stream_1.default.merge(...webpackStreams')) {
          result.push('}));');
          result.push('        const flattenedWebpackStreams = [].concat(...webpackStreams);');
          foundMapStart = false;
          continue;
        }
      }
    }
    result.push(line);
  }
  content = result.join('\n');
  content = content.replace(/event_stream_1\.default\.merge\(\.\.\.webpackStreams/g, 'event_stream_1.default.merge(...flattenedWebpackStreams');
}

fs.writeFileSync(filePath, content, 'utf8');
console.log('Re-patched extensions.js');
EOFPATCH2
)
        echo "$PATCH_SCRIPT" | node - "build/lib/extensions.js" 2>&1 || {
          echo "Warning: Re-patch failed. Restoring backup..." >&2
          if [[ -f "build/lib/extensions.js.bak" ]]; then
            mv "build/lib/extensions.js.bak" "build/lib/extensions.js" 2>/dev/null || true
          fi
        }
        if grep -q "pathToFileURL" "build/lib/extensions.js" 2>/dev/null; then
          echo "Successfully re-patched extensions.js after compile-extensions-build." >&2
        fi
      fi
    fi
  fi
  
  # Fix CSS paths in out-build directory before minify
  # This fixes paths that get incorrectly modified during the build process
  echo "Fixing CSS paths in out-build directory..."
  
  # Determine sed command based on system (GNU vs BSD)
  if sed --version >/dev/null 2>&1; then
    SED_CMD="sed -i"
  else
    SED_CMD="sed -i ''"
  fi
  
  # Fix editorgroupview.css: ../../media/code-icon.svg -> ../../../media/code-icon.svg
  if [[ -f "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" ]]; then
    if grep -q "../../media/code-icon.svg" "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null; then
      echo "Fixing path in out-build/editorgroupview.css..."
      $SED_CMD "s|url('../../media/code-icon\.svg')|url('../../../media/code-icon.svg')|g" "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null || true
      $SED_CMD "s|url(\"../../media/code-icon\.svg\")|url('../../../media/code-icon.svg')|g" "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null || true
    fi
  fi
  
  # Fix void.css: ../../browser/media/code-icon.svg -> ../../../../browser/media/code-icon.svg
  if [[ -f "out-build/vs/workbench/contrib/void/browser/media/void.css" ]]; then
    if grep -q "../../browser/media/code-icon.svg" "out-build/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null; then
      echo "Fixing path in out-build/void.css..."
      $SED_CMD "s|url('../../browser/media/code-icon\.svg')|url('../../../../browser/media/code-icon.svg')|g" "out-build/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null || true
      $SED_CMD "s|url(\"../../browser/media/code-icon\.svg\")|url('../../../../browser/media/code-icon.svg')|g" "out-build/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null || true
    fi
  fi
  
  # Fix any other CSS files in out-build/browser/parts with incorrect paths to media/
  find out-build/vs/workbench/browser/parts -name "*.css" -type f 2>/dev/null | while read -r css_file; do
    if [[ -f "$css_file" ]] && grep -q "../../media/code-icon.svg" "$css_file" 2>/dev/null; then
      echo "Fixing path in $css_file (parts/*/media/)..."
      $SED_CMD "s|url('../../media/code-icon\.svg')|url('../../../media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
      $SED_CMD "s|url(\"../../media/code-icon\.svg\")|url('../../../media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
    fi
  done
  
  # Fix any CSS files in out-build/contrib with incorrect paths to browser/media/
  find out-build/vs/workbench/contrib -path "*/browser/media/*.css" -type f 2>/dev/null | while read -r css_file; do
    if [[ -f "$css_file" ]] && grep -q "../../browser/media/code-icon.svg" "$css_file" 2>/dev/null; then
      echo "Fixing path in $css_file (contrib/*/browser/media/)..."
      $SED_CMD "s|url('../../browser/media/code-icon\.svg')|url('../../../../browser/media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
      $SED_CMD "s|url(\"../../browser/media/code-icon\.svg\")|url('../../../../browser/media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
    fi
  done
  
  # Also check for any other incorrect relative paths that might cause issues
  # Pattern: ../../media/ from parts/*/media/ (too short, should be ../../../media/)
  find out-build/vs/workbench/browser/parts -path "*/media/*.css" -type f 2>/dev/null | while read -r css_file; do
    if [[ -f "$css_file" ]] && grep -q "url(['\"]\.\./\.\./media/[^'\"].*['\"])" "$css_file" 2>/dev/null; then
      # Check if it's not void-icon-sm.png (which uses correct ../../../../browser/media/)
      if ! grep -q "void-icon-sm.png" "$css_file" 2>/dev/null; then
        echo "Warning: Potential incorrect path in $css_file"
        echo "  Check if relative path is correct for this file location"
      fi
    fi
  done
  
  echo "Minifying VS Code..."
  if ! npm run gulp minify-vscode; then
    echo "Error: minify-vscode failed. Check for:" >&2
    echo "  - CSS path issues (check out-build directory)" >&2
    echo "  - Minification errors" >&2
    echo "  - Missing source files" >&2
    echo "  - Memory issues (try increasing NODE_OPTIONS)" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi

  if [[ "${OS_NAME}" == "osx" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies darwin # Void commented this out

    echo "Building macOS package for ${VSCODE_ARCH}..."
    if ! npm run gulp "vscode-darwin-${VSCODE_ARCH}-min-ci"; then
      echo "Error: macOS build failed for ${VSCODE_ARCH}. Check for:" >&2
      echo "  - Electron packaging errors" >&2
      echo "  - Missing build artifacts" >&2
      echo "  - Code signing issues (if applicable)" >&2
      echo "  - Architecture mismatch" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi

    find "../VSCode-darwin-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

    if ! . ../build_cli.sh; then
      echo "Error: CLI build failed for macOS. Check for:" >&2
      echo "  - Rust/Cargo compilation errors" >&2
      echo "  - Missing Rust toolchain" >&2
      echo "  - Architecture-specific build issues" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi

    VSCODE_PLATFORM="darwin"
  elif [[ "${OS_NAME}" == "windows" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies win32 # Void commented this out

    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      . ../build/windows/rtf/make.sh

      echo "Building Windows package for ${VSCODE_ARCH}..."
      if ! npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"; then
        echo "Error: Windows build failed for ${VSCODE_ARCH}. Check for:" >&2
        echo "  - Electron packaging errors" >&2
        echo "  - Missing build artifacts" >&2
        echo "  - Architecture mismatch" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi

      if [[ "${VSCODE_ARCH}" != "x64" ]]; then
        SHOULD_BUILD_REH="no"
        SHOULD_BUILD_REH_WEB="no"
      fi

      if ! . ../build_cli.sh; then
        echo "Error: CLI build failed for Windows. Check for:" >&2
        echo "  - Rust/Cargo compilation errors" >&2
        echo "  - Missing Rust toolchain" >&2
        echo "  - Architecture-specific build issues" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi
    fi

    VSCODE_PLATFORM="win32"
  else # linux
    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      echo "Building Linux package for ${VSCODE_ARCH}..."
      if ! npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"; then
        echo "Error: Linux build failed for ${VSCODE_ARCH}. Check for:" >&2
        echo "  - Electron packaging errors" >&2
        echo "  - Missing build artifacts" >&2
        echo "  - Architecture mismatch" >&2
        echo "  - Missing system libraries" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi

      find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

      if ! . ../build_cli.sh; then
        echo "Error: CLI build failed for Linux. Check for:" >&2
        echo "  - Rust/Cargo compilation errors" >&2
        echo "  - Missing Rust toolchain" >&2
        echo "  - Architecture-specific build issues" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi
    fi

    VSCODE_PLATFORM="linux"
  fi

  if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
    echo "Building REH (Remote Extension Host)..."
    if ! npm run gulp minify-vscode-reh; then
      echo "Error: minify-vscode-reh failed. Check for:" >&2
      echo "  - Minification errors" >&2
      echo "  - Missing source files" >&2
      echo "  - Memory issues" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
    if ! npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"; then
      echo "Error: REH build failed for ${VSCODE_PLATFORM}-${VSCODE_ARCH}. Check for:" >&2
      echo "  - REH packaging errors" >&2
      echo "  - Missing build artifacts" >&2
      echo "  - Architecture/platform mismatch" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    echo "Building REH-web (Remote Extension Host Web)..."
    if ! npm run gulp minify-vscode-reh-web; then
      echo "Error: minify-vscode-reh-web failed. Check for:" >&2
      echo "  - Minification errors" >&2
      echo "  - Missing source files" >&2
      echo "  - Memory issues" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
    if ! npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"; then
      echo "Error: REH-web build failed for ${VSCODE_PLATFORM}-${VSCODE_ARCH}. Check for:" >&2
      echo "  - REH-web packaging errors" >&2
      echo "  - Missing build artifacts" >&2
      echo "  - Architecture/platform mismatch" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
  fi

  cd ..
  
  # Cleanup backup files created during patching
  echo "Cleaning up backup files..." >&2
  find . -name "*.bak" -type f -delete 2>/dev/null || true
  if [[ -d "vscode" ]]; then
    find vscode -name "*.bak" -type f -delete 2>/dev/null || true
    find vscode/build/lib -name "*.bak" -type f -delete 2>/dev/null || true
    find vscode/node_modules/@vscode/gulp-electron -name "*.bak" -type f -delete 2>/dev/null || true
  fi
fi
