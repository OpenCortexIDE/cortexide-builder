#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

. version.sh

# Download helper with retry/backoff to reduce transient GitHub outages
download_with_retries() {
  local url="$1"
  local dest="$2"
  local max_attempts="${3:-4}"
  local tmp="${dest}.partial"

  if [[ -z "${url}" || -z "${dest}" ]]; then
    return 1
  fi

  mkdir -p "$(dirname "${dest}")"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    echo "Prefetching ${url} (attempt ${attempt}/${max_attempts})..." >&2
    rm -f "${tmp}"

    local -a curl_headers=()
    if [[ "${url}" == https://github.com/* || "${url}" == https://objects.githubusercontent.com/* ]]; then
      if [[ -n "${GITHUB_TOKEN}" ]]; then
        curl_headers+=("-H" "Authorization: Bearer ${GITHUB_TOKEN}")
      fi
    fi

    if curl --fail --location --show-error --silent \
        --connect-timeout 20 --retry 0 \
        "${curl_headers[@]}" \
        --output "${tmp}" "${url}"; then
      if [[ -s "${tmp}" ]]; then
        mv "${tmp}" "${dest}"
        echo "✓ Downloaded ${url} -> ${dest}" >&2
        return 0
      fi
    fi

    echo "Download failed for ${url}, retrying in $((attempt * 5))s..." >&2
    sleep $((attempt * 5))
  done

  rm -f "${tmp}"
  echo "✗ Unable to download ${url}" >&2
  return 1
}

detect_electron_version() {
  local candidate version
  for candidate in ".npmrc" ".npmrc.bak"; do
    if [[ -f "${candidate}" ]]; then
      version=$(grep -E '^target=' "${candidate}" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'" )
      if [[ -n "${version}" ]]; then
        echo "${version}"
        return 0
      fi
    fi
  done

  if [[ -f "package.json" ]]; then
    version=$(node -p "(() => { try { const pkg = require('./package.json'); return pkg.electronVersion || (pkg.engines && pkg.engines.electron) || ''; } catch { return ''; } })()" 2>/dev/null)
    if [[ -n "${version}" ]]; then
      echo "${version}"
      return 0
    fi
  fi

  return 1
}

ensure_electron_cached() {
  local platform="$1"
  local arch="$2"
  local electron_version="$3"

  if [[ -z "${platform}" || -z "${arch}" ]]; then
    return 1
  fi

  if [[ -z "${electron_version}" ]]; then
    electron_version="$(detect_electron_version)" || true
  fi

  if [[ -z "${electron_version}" ]]; then
    echo "Warning: Could not detect Electron version, skipping cache warm-up" >&2
    return 1
  fi

  local artifact_arch="${arch}"
  if [[ "${platform}" == "linux" && "${arch}" == "armhf" ]]; then
    artifact_arch="armv7l"
  fi

  local cache_dir="${ELECTRON_DOWNLOAD_CACHE:-$(pwd)/.electron-cache}"
  mkdir -p "${cache_dir}"
  export ELECTRON_DOWNLOAD_CACHE="${cache_dir}"

  local artifact="electron-v${electron_version}-${platform}-${artifact_arch}.zip"
  local destination="${cache_dir}/${artifact}"

  if [[ -f "${destination}" && -s "${destination}" ]]; then
    echo "✓ Electron artifact already cached: ${artifact}" >&2
    return 0
  fi

  local -a mirrors=()
  if [[ -n "${CORTEXIDE_ELECTRON_BASE_URL}" ]]; then
    mirrors+=("${CORTEXIDE_ELECTRON_BASE_URL%/}/v${electron_version}/${artifact}")
  fi
  mirrors+=("https://github.com/electron/electron/releases/download/v${electron_version}/${artifact}")
  mirrors+=("https://registry.npmmirror.com/-/binary/electron/v${electron_version}/${artifact}")
  mirrors+=("https://download.npmmirror.com/electron/v${electron_version}/${artifact}")
  mirrors+=("https://npm.taobao.org/mirrors/electron/v${electron_version}/${artifact}")

  for mirror in "${mirrors[@]}"; do
    if download_with_retries "${mirror}" "${destination}"; then
      return 0
    fi
  done

  echo "Warning: Failed to prefetch ${artifact} from all mirrors" >&2
  return 1
}

# Copy a file from the various build output folders into a destination path.
# This is used when packaging misses critical runtime files (e.g. main.js).
copy_from_build_outputs() {
  local relative_path="$1"
  local destination="$2"
  local label="${3:-$1}"
  local -a search_roots=("out-vscode-min" "out-build" "out")

  if [[ -z "${relative_path}" || -z "${destination}" ]]; then
    return 1
  fi

  for source_root in "${search_roots[@]}"; do
    local source_file="${source_root}/${relative_path}"
    if [[ -f "${source_file}" ]]; then
      mkdir -p "$(dirname "${destination}")"
      if cp "${source_file}" "${destination}" 2>/dev/null; then
        echo "  ✓ Copied ${label} from ${source_root}/${relative_path}" >&2
        return 0
      else
        echo "  ✗ Failed to copy ${label} from ${source_root}" >&2
      fi
    fi
  done

  return 1
}

# Ensure a specific file exists inside the packaged app's out/ directory.
# Arguments: 1=platform label, 2=out directory path, 3=relative file (e.g. main.js)
ensure_bundle_out_file() {
  local platform_label="$1"
  local out_dir="$2"
  local relative_path="$3"
  local destination="${out_dir}/${relative_path}"

  if [[ -z "${platform_label}" || -z "${out_dir}" || -z "${relative_path}" ]]; then
    return 1
  fi

  if [[ -f "${destination}" ]]; then
    return 0
  fi

  echo "ERROR: ${relative_path} is missing from ${platform_label}!" >&2
  echo "  Expected at: ${destination}" >&2
  echo "  Attempting to restore ${relative_path} from build outputs..." >&2

  if copy_from_build_outputs "${relative_path}" "${destination}" "${relative_path}"; then
    echo "  ✓ Restored ${relative_path} in ${platform_label}" >&2
    return 0
  fi

  echo "  ✗ Could not restore ${relative_path} from out-vscode-min/out-build/out" >&2
  return 1
}

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
  
  # Check if vscode directory exists, and if not, call get_repo.sh to create it
  if [[ ! -d "vscode" ]] && [[ ! -d "../cortexide" ]]; then
    echo "Neither 'vscode' nor '../cortexide' directory found. Calling get_repo.sh to create it..." >&2
    if ! . get_repo.sh; then
      echo "Error: get_repo.sh failed. Please check:" >&2
      echo "  1. Network connectivity (if cloning from GitHub)" >&2
      echo "  2. That '../cortexide' exists and contains package.json (if using local repo)" >&2
      echo "  3. Git is installed and configured" >&2
      exit 1
    fi
    # Verify vscode directory was created
    if [[ ! -d "vscode" ]]; then
      echo "Error: get_repo.sh did not create 'vscode' directory." >&2
      exit 1
    fi
  elif [[ ! -d "vscode" ]] && [[ -d "../cortexide" ]]; then
    # If ../cortexide exists but vscode doesn't, call get_repo.sh to copy it
    echo "Found '../cortexide' but 'vscode' directory not found. Calling get_repo.sh to copy it..." >&2
    if ! . get_repo.sh; then
      echo "Error: get_repo.sh failed to copy '../cortexide' to 'vscode'." >&2
      exit 1
    fi
  fi
  
  if [[ $MISSING_DEPS -eq 1 ]]; then
    echo "Error: Missing required dependencies. Please install them before building." >&2
    exit 1
  fi
  
  echo "Dependency checks passed."

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }
  
  # CRITICAL: Pre-convert ALL .js webpack config files to .mjs BEFORE any build
  # This ensures Node.js treats them as ES modules from the start
  echo "Pre-converting extension webpack config files to .mjs..." >&2
  CONVERTED_COUNT=0
  FAILED_COUNT=0
  find extensions -type f \( -name "extension.webpack.config.js" -o -name "extension-browser.webpack.config.js" \) 2>/dev/null | while read -r jsfile; do
    if [[ -f "$jsfile" ]]; then
      mjsfile="${jsfile%.js}.mjs"
      # Only copy if .mjs doesn't exist or .js is newer
      if [[ ! -f "$mjsfile" ]] || [[ "$jsfile" -nt "$mjsfile" ]]; then
        if cp "$jsfile" "$mjsfile" 2>/dev/null; then
          echo "Converted: $jsfile -> $mjsfile" >&2
          CONVERTED_COUNT=$((CONVERTED_COUNT + 1))
        else
          echo "Warning: Failed to convert $jsfile" >&2
          FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
      fi
    fi
  done
  
  # Verify at least some conversions succeeded (if any .js files were found)
  JS_FILE_COUNT=$(find extensions -type f \( -name "extension.webpack.config.js" -o -name "extension-browser.webpack.config.js" \) 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${JS_FILE_COUNT}" -gt 0 ]]; then
    MJS_FILE_COUNT=$(find extensions -type f \( -name "extension.webpack.config.mjs" -o -name "extension-browser.webpack.config.mjs" \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${MJS_FILE_COUNT}" -lt "${JS_FILE_COUNT}" ]]; then
      echo "Warning: Only ${MJS_FILE_COUNT} of ${JS_FILE_COUNT} webpack config files have .mjs versions" >&2
      echo "  Some extensions may fail to build if they require ES module webpack configs" >&2
    else
      echo "✓ Verified: All ${JS_FILE_COUNT} webpack config files have .mjs versions"
    fi
  fi
  echo "Webpack config pre-conversion complete." >&2

  export NODE_OPTIONS="--max-old-space-size=12288"

  # Skip monaco-compile-check as it's failing due to searchUrl property
  # Skip valid-layers-check as well since it might depend on monaco
  # Void commented these out
  # npm run monaco-compile-check
  # npm run valid-layers-check

  # Clean React build output directory before building (matches local workflow)
  echo "Cleaning React build output directory..." >&2
  if [[ -d "src/vs/workbench/contrib/cortexide/browser/react/out" ]]; then
    rm -rf "src/vs/workbench/contrib/cortexide/browser/react/out"
    echo "✓ Removed stale React build output" >&2
  fi

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
  if [[ "${APPLY_TS_WEBPACK_PATCH:-no}" == "yes" ]] && [[ -f "build/lib/extensions.ts" ]]; then
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

// Fix 3c: Replace webpackRootConfig require with dynamic import and copy to .mjs if needed
if (content.includes('const webpackRootConfig = require(path.join(extensionPath, webpackConfigFileName))')) {
  content = content.replace(
    /const\s+webpackRootConfig\s*=\s*require\(path\.join\(extensionPath,\s*webpackConfigFileName\)\)\.default\s*;/g,
    `let rootConfigPath = path.join(extensionPath, webpackConfigFileName);
\tif (rootConfigPath.endsWith('.js')) {
\t\tconst rootMjsPath = rootConfigPath.replace(/\\.js$/, '.mjs');
\t\ttry {
\t\t\tconst srcStat = fs.statSync(rootConfigPath);
\t\t\tconst destStat = fs.existsSync(rootMjsPath) ? fs.statSync(rootMjsPath) : undefined;
\t\t\tif (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
\t\t\t\tfs.copyFileSync(rootConfigPath, rootMjsPath);
\t\t\t}
\t\t} catch (error) {
\t\t\t// ignore copy errors
\t\t}
\t\trootConfigPath = rootMjsPath;
\t}
\tconst webpackRootConfig = (await import(pathToFileURL(path.resolve(rootConfigPath)).href)).default;`
  );
}

// Fix 4: Replace require(webpackConfigPath).default with dynamic import and copy to .mjs if needed
if (content.includes('require(webpackConfigPath)')) {
  content = content.replace(
    /const\s+exportedConfig\s*=\s*require\(webpackConfigPath\)\.default\s*;/g,
    `let configToLoad = webpackConfigPath;
\tif (configToLoad.endsWith('.js')) {
\t\tconst mjsPath = configToLoad.replace(/\\.js$/, '.mjs');
\t\ttry {
\t\t\tconst srcStat = fs.statSync(configToLoad);
\t\t\tconst destStat = fs.existsSync(mjsPath) ? fs.statSync(mjsPath) : undefined;
\t\t\tif (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
\t\t\t\tfs.copyFileSync(configToLoad, mjsPath);
\t\t\t}
\t\t} catch (error) {
\t\t\t// ignore copy errors
\t\t}
\t\tconfigToLoad = mjsPath;
\t}
\tconst exportedConfig = (await import(pathToFileURL(path.resolve(configToLoad)).href)).default;`
  );
  
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
  
  echo "Compiling build without mangling..."
  # Verify ternary-stream is available before running gulp
  if [[ ! -d "node_modules/ternary-stream" ]] && [[ ! -f "node_modules/ternary-stream/package.json" ]]; then
    echo "Error: ternary-stream dependency is missing. Installing..." >&2
    if [[ -f "build/package.json" ]]; then
      (cd build && npm install ternary-stream 2>&1 | tail -20) || {
        echo "Trying to install at root level..." >&2
        npm install ternary-stream 2>&1 | tail -20 || {
          echo "Error: Failed to install ternary-stream. Cannot continue." >&2
          echo "Try running: cd vscode && npm install ternary-stream" >&2
          exit 1
        }
      }
    else
      npm install ternary-stream 2>&1 | tail -20 || {
        echo "Error: Failed to install ternary-stream. Cannot continue." >&2
        exit 1
      }
    fi
  fi

  if ! npm run gulp compile-build-without-mangling; then
    echo "Error: compile-build-without-mangling failed. Check for:" >&2
    echo "  - TypeScript compilation errors" >&2
    echo "  - Missing build dependencies (ternary-stream)" >&2
    echo "  - Gulp task configuration issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
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

// Ensure fromLocal handles Promise-returning streams
const fromLocalTailPattern = /if\s*\(isWebPacked\)\s*\{\s*input\s*=\s*updateExtensionPackageJSON\(([\s\S]*?)\);\s*\}\s*return\s+input;/;
if (fromLocalTailPattern.test(content)) {
  content = content.replace(fromLocalTailPattern, `if (input && typeof input.then === 'function') {
        const proxyStream = event_stream_1.default.through();
        input.then((actualStream) => {
            actualStream.pipe(proxyStream);
        }).catch((err) => proxyStream.emit('error', err));
        input = proxyStream;
    }

    if (isWebPacked) {
        input = updateExtensionPackageJSON($1);
    }
    return input;`);
}

// Ensure root-level webpack config imports copy .js -> .mjs before import()
const rootImportPattern = /let\s+webpackConfigPath\s*=\s*path_1\.default\.resolve\(extensionPath,\s*webpackConfigFileName\);\s+let\s+webpackConfigUrl\s*=\s*pathToFileURL\(webpackConfigPath\)\.href;/g;
content = content.replace(rootImportPattern, `let webpackConfigPath = path_1.default.resolve(extensionPath, webpackConfigFileName);
        if (webpackConfigPath.endsWith('.js')) {
            const webpackConfigMjs = webpackConfigPath.replace(/\\.js$/, '.mjs');
            try {
                const srcStat = fs_1.default.statSync(webpackConfigPath);
                const destStat = fs_1.default.existsSync(webpackConfigMjs) ? fs_1.default.statSync(webpackConfigMjs) : undefined;
                if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
                    fs_1.default.copyFileSync(webpackConfigPath, webpackConfigMjs);
                }
            } catch (error) {
                // ignore copy errors
            }
            webpackConfigPath = webpackConfigMjs;
        }
        let webpackConfigUrl = pathToFileURL(webpackConfigPath).href;`);

// Ensure per-extension webpack config imports ALWAYS use .mjs if available
// Handle the pattern: const exportedConfig = (await import(...webpackConfigPath...)).default;
const exportedImportPattern = /const\s+exportedConfig\s*=\s*\(await\s+import\(pathToFileURL\(path_1\.default\.resolve\(webpackConfigPath\)\)\.href\)\)\.default;/g;
content = content.replace(exportedImportPattern, function(match) {
  // Check if this pattern is already inside a conversion block by looking backwards
  const matchIndex = content.indexOf(match);
  const beforeMatch = content.substring(Math.max(0, matchIndex - 200), matchIndex);
  if (beforeMatch.includes('configToLoad') && beforeMatch.includes('.mjs')) {
    return match; // Already converted
  }
  // Otherwise, add conversion logic
  return 'let configToLoad = webpackConfigPath;\n' +
         '            // Always prefer .mjs if it exists (pre-converted in build.sh)\n' +
         '            if (configToLoad.endsWith(\'.js\')) {\n' +
         '                const mjsPath = configToLoad.replace(/\\.js$/, \'.mjs\');\n' +
         '                if (fs_1.default.existsSync(mjsPath)) {\n' +
         '                    configToLoad = mjsPath;\n' +
         '                } else {\n' +
         '                    try {\n' +
         '                        const srcStat = fs_1.default.statSync(configToLoad);\n' +
         '                        const destStat = fs_1.default.existsSync(mjsPath) ? fs_1.default.statSync(mjsPath) : undefined;\n' +
         '                        if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {\n' +
         '                            fs_1.default.copyFileSync(configToLoad, mjsPath);\n' +
         '                        }\n' +
         '                        configToLoad = mjsPath;\n' +
         '                    } catch (error) {\n' +
         '                        // ignore copy errors, will try .js\n' +
         '                    }\n' +
         '                }\n' +
         '            }\n' +
         '            const exportedConfig = (await import(pathToFileURL(path_1.default.resolve(configToLoad)).href)).default;';
});

// Also handle any direct webpackConfigPath usage in import statements that weren't caught above
if (content.includes('webpackConfigPath') && content.includes('pathToFileURL') && content.includes('import') && !content.includes('configToLoad')) {
  // Find lines with webpackConfigPath and pathToFileURL and import
  const lines = content.split('\n');
  const result = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // If this line has webpackConfigPath and import but no configToLoad conversion
    if (line.includes('webpackConfigPath') && line.includes('import') && line.includes('pathToFileURL') && !line.includes('configToLoad')) {
      // Check if previous lines already have conversion
      let hasConversion = false;
      for (let j = Math.max(0, i - 10); j < i; j++) {
        if (lines[j].includes('configToLoad') && lines[j].includes('.mjs')) {
          hasConversion = true;
          break;
        }
      }
      if (!hasConversion) {
        // Add conversion before this line
        const indent = (line.match(/^(\s*)/) || ['', '            '])[1];
        result.push(indent + 'let configToLoad = webpackConfigPath;');
        result.push(indent + 'if (configToLoad.endsWith(\'.js\')) {');
        result.push(indent + '    const mjsPath = configToLoad.replace(/\\.js$/, \'.mjs\');');
        result.push(indent + '    if (fs_1.default.existsSync(mjsPath)) {');
        result.push(indent + '        configToLoad = mjsPath;');
        result.push(indent + '    } else {');
        result.push(indent + '        try {');
        result.push(indent + '            const srcStat = fs_1.default.statSync(configToLoad);');
        result.push(indent + '            const destStat = fs_1.default.existsSync(mjsPath) ? fs_1.default.statSync(mjsPath) : undefined;');
        result.push(indent + '            if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {');
        result.push(indent + '                fs_1.default.copyFileSync(configToLoad, mjsPath);');
        result.push(indent + '            }');
        result.push(indent + '            configToLoad = mjsPath;');
        result.push(indent + '        } catch (error) {');
        result.push(indent + '            // ignore');
        result.push(indent + '        }');
        result.push(indent + '    }');
        result.push(indent + '}');
        result.push(line.replace(/webpackConfigPath/g, 'configToLoad'));
        continue;
      }
    }
    result.push(line);
  }
  content = result.join('\n');
}

// Old pattern for backward compatibility - handle require() patterns
if (content.includes('require(webpackConfigPath)')) {
  // Use a simpler replacement for require patterns
  const requirePattern = /require\(webpackConfigPath\)\.default/g;
  content = content.replace(requirePattern, function(match) {
    // Check if we're already in a conversion block
    const matchIndex = content.indexOf(match);
    const beforeMatch = content.substring(Math.max(0, matchIndex - 200), matchIndex);
    if (beforeMatch.includes('configToLoad') && beforeMatch.includes('.mjs')) {
      return match.replace('webpackConfigPath', 'configToLoad');
    }
    // Add conversion - but this should rarely happen since we patch before this
    return '(await import(pathToFileURL(path.resolve(configToLoad)).href)).default';
  });
  
  // Also add the conversion logic before require if needed
  if (content.includes('require(webpackConfigPath)') && !content.includes('configToLoad')) {
    const lines = content.split('\n');
    const result = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.includes('require(webpackConfigPath)') && !line.includes('configToLoad')) {
        const indent = (line.match(/^(\s*)/) || ['', '            '])[1];
        result.push(indent + 'let configToLoad = webpackConfigPath;');
        result.push(indent + 'if (configToLoad.endsWith(\'.js\')) {');
        result.push(indent + '    const mjsPath = configToLoad.replace(/\\.js$/, \'.mjs\');');
        result.push(indent + '    if (fs_1.default.existsSync(mjsPath)) {');
        result.push(indent + '        configToLoad = mjsPath;');
        result.push(indent + '    } else {');
        result.push(indent + '        try {');
        result.push(indent + '            const srcStat = fs_1.default.statSync(configToLoad);');
        result.push(indent + '            const destStat = fs_1.default.existsSync(mjsPath) ? fs_1.default.statSync(mjsPath) : undefined;');
        result.push(indent + '            if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {');
        result.push(indent + '                fs_1.default.copyFileSync(configToLoad, mjsPath);');
        result.push(indent + '            }');
        result.push(indent + '            configToLoad = mjsPath;');
        result.push(indent + '        } catch (error) {');
        result.push(indent + '            // ignore');
        result.push(indent + '        }');
        result.push(indent + '    }');
        result.push(indent + '}');
        result.push(line.replace(/webpackConfigPath/g, 'configToLoad'));
        continue;
      }
      result.push(line);
    }
    content = result.join('\n');
  }
}

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
  
  # CRITICAL: Patch extensions.js RIGHT BEFORE compile-extensions-build
  # This ensures the patch is fresh and applied correctly
  echo "Patching extensions.js before compile-extensions-build..." >&2
  if [[ -f "build/lib/extensions.js" ]]; then
    # Always check and patch if needed, regardless of previous patches
    if grep -q "require(webpackConfigPath)" "build/lib/extensions.js" 2>/dev/null; then
      echo "Applying webpack ES module patch before compile-extensions-build..." >&2
      cp "build/lib/extensions.js" "build/lib/extensions.js.bak" 2>/dev/null || true
      
      # Use inline Node.js script for direct patching
      PRE_BUILD_PATCH_SCRIPT=$(mktemp /tmp/fix-extensions-pre-build.XXXXXX.js) || {
        PRE_BUILD_PATCH_SCRIPT="/tmp/fix-extensions-pre-build.js"
      }
      cat > "$PRE_BUILD_PATCH_SCRIPT" << 'PREBUILDPATCH'
const fs = require('fs');
const filePath = process.argv[2];
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('pathToFileURL') && !content.includes('require(webpackConfigPath).default')) {
  console.log('Already patched');
  process.exit(0);
}

// Make fromLocalWebpack function async
if (content.includes('function fromLocalWebpack(') && !content.includes('async function fromLocalWebpack')) {
  content = content.replace(/function\s+fromLocalWebpack\(/g, 'async function fromLocalWebpack(');
}

// Add pathToFileURL imports at the start of fromLocalWebpack function
if (content.includes('function fromLocalWebpack')) {
  const funcStart = content.indexOf('async function fromLocalWebpack');
  if (funcStart === -1) {
    // Try without async
    const funcStart2 = content.indexOf('function fromLocalWebpack');
    if (funcStart2 !== -1) {
      const afterBrace = content.indexOf('{', funcStart2) + 1;
      const before = content.substring(0, afterBrace);
      const after = content.substring(afterBrace);
      
      if (!before.includes('pathToFileURL')) {
        // Find the indentation of the first line after the brace
        const firstLineMatch = after.match(/^(\s*)/);
        const indent = firstLineMatch ? firstLineMatch[1] : '    ';
        content = before + '\n' + indent + 'const { pathToFileURL } = require("url");\n' + indent + 'const path = require("path");\n' + indent + 'const fs = require("fs");' + after;
      }
    }
  } else {
    const afterBrace = content.indexOf('{', funcStart) + 1;
    const before = content.substring(0, afterBrace);
    const after = content.substring(afterBrace);
    
    if (!before.includes('pathToFileURL')) {
      // Find the indentation of the first line after the brace
      const firstLineMatch = after.match(/^(\s*)/);
      const indent = firstLineMatch ? firstLineMatch[1] : '    ';
      content = before + '\n' + indent + 'const { pathToFileURL } = require("url");\n' + indent + 'const path = require("path");\n' + indent + 'const fs = require("fs");' + after;
    }
  }
}

// Make then callback async - exact pattern from actual code
// Pattern: vsce.listFiles({ cwd: extensionPath, packageManager: vsce.PackageManager.None, packagedDependencies }).then(fileNames => {
if (content.includes('vsce.listFiles({ cwd: extensionPath')) {
  content = content.replace(/\)\.then\(fileNames\s*=>\s*\{/g, ').then(async (fileNames) => {');
}

// Replace webpackRootConfig import with .mjs copy logic
const rootRegex = /const\s+webpackRootConfig\s*=\s*\(await\s+import\(pathToFileURL\(path_1\.default\.resolve\(extensionPath,\s*webpackConfigFileName\)\)\.href\)\)\.default;/g;
content = content.replace(rootRegex, `let rootConfigPath = path_1.default.join(extensionPath, webpackConfigFileName);
        if (rootConfigPath.endsWith('.js')) {
            const rootMjsPath = rootConfigPath.replace(/\\.js$/, '.mjs');
            try {
                const srcStat = fs_1.default.statSync(rootConfigPath);
                const destStat = fs_1.default.existsSync(rootMjsPath) ? fs_1.default.statSync(rootMjsPath) : undefined;
                if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
                    fs_1.default.copyFileSync(rootConfigPath, rootMjsPath);
                }
            } catch (error) {
                // ignore copy errors
            }
            rootConfigPath = rootMjsPath;
        }
        const webpackRootConfig = (await import(pathToFileURL(path_1.default.resolve(rootConfigPath)).href)).default;`);

// Replace flatMap with map and Promise.all - exact pattern from actual code
// Pattern: const webpackStreams = webpackConfigLocations.flatMap(webpackConfigPath => {
if (content.includes('webpackConfigLocations.flatMap(webpackConfigPath =>')) {
  content = content.replace(
    /const\s+webpackStreams\s*=\s*webpackConfigLocations\.flatMap\(webpackConfigPath\s*=>/g,
    'const webpackStreams = await Promise.all(webpackConfigLocations.map(async webpackConfigPath =>'
  );
}

// Replace exportedConfig import with .mjs copy logic - ALWAYS prefer .mjs if it exists
// Match multiple patterns to catch all variations
const exportedPatterns = [
  /const\s+exportedConfig\s*=\s*\(await\s+import\(pathToFileURL\(path_1\.default\.resolve\(webpackConfigPath\)\)\.href\)\)\.default;/g,
  /const\s+exportedConfig\s*=\s*\(await\s+import\(pathToFileURL\(path\.resolve\(webpackConfigPath\)\)\.href\)\)\.default;/g,
  /exportedConfig\s*=\s*\(await\s+import\(pathToFileURL\([^)]+webpackConfigPath[^)]+\)\.href\)\)\.default;/g
];

for (const exportedRegex of exportedPatterns) {
  content = content.replace(exportedRegex, `let configToLoad = webpackConfigPath;
            // ALWAYS prefer .mjs if it exists (pre-converted in build.sh)
            if (configToLoad.endsWith('.js')) {
                const mjsPath = configToLoad.replace(/\\.js$/, '.mjs');
                if (fs_1.default.existsSync(mjsPath)) {
                    configToLoad = mjsPath;
                } else {
                    // Create .mjs if .js exists
                    try {
                        const srcStat = fs_1.default.statSync(configToLoad);
                        const destStat = fs_1.default.existsSync(mjsPath) ? fs_1.default.statSync(mjsPath) : undefined;
                        if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
                            fs_1.default.copyFileSync(configToLoad, mjsPath);
                        }
                        configToLoad = mjsPath;
                    } catch (error) {
                        // ignore copy errors, will try .js
                    }
                }
            }
            const exportedConfig = (await import(pathToFileURL(path_1.default.resolve(configToLoad)).href)).default;`);
}

// Also handle any direct webpackConfigPath usage in import statements
// This catches cases where the pattern wasn't matched above
if (content.includes('webpackConfigPath') && content.includes('pathToFileURL') && content.includes('import')) {
  // Find lines with webpackConfigPath and pathToFileURL and import
  const lines = content.split('\n');
  const result = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // If this line has webpackConfigPath and import but no configToLoad conversion
    if (line.includes('webpackConfigPath') && line.includes('import') && line.includes('pathToFileURL') && !line.includes('configToLoad')) {
      // Check if previous lines already have conversion
      let hasConversion = false;
      for (let j = Math.max(0, i - 10); j < i; j++) {
        if (lines[j].includes('configToLoad') && lines[j].includes('.mjs')) {
          hasConversion = true;
          break;
        }
      }
      if (!hasConversion) {
        // Add conversion before this line
        const indent = line.match(/^(\s*)/)[1] || '            ';
        result.push(indent + 'let configToLoad = webpackConfigPath;');
        result.push(indent + 'if (configToLoad.endsWith(\'.js\')) {');
        result.push(indent + '    const mjsPath = configToLoad.replace(/\\.js$/, \'.mjs\');');
        result.push(indent + '    if (fs_1.default.existsSync(mjsPath)) {');
        result.push(indent + '        configToLoad = mjsPath;');
        result.push(indent + '    } else {');
        result.push(indent + '        try {');
        result.push(indent + '            const srcStat = fs_1.default.statSync(configToLoad);');
        result.push(indent + '            const destStat = fs_1.default.existsSync(mjsPath) ? fs_1.default.statSync(mjsPath) : undefined;');
        result.push(indent + '            if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {');
        result.push(indent + '                fs_1.default.copyFileSync(configToLoad, mjsPath);');
        result.push(indent + '            }');
        result.push(indent + '            configToLoad = mjsPath;');
        result.push(indent + '        } catch (error) {');
        result.push(indent + '            // ignore');
        result.push(indent + '        }');
        result.push(indent + '    }');
        result.push(indent + '}');
        result.push(line.replace(/webpackConfigPath/g, 'configToLoad'));
        continue;
      }
    }
    result.push(line);
  }
  content = result.join('\n');
}

// Fix Promise.all closing and flattening
// The flatMap returns an array, so Promise.all will return an array of arrays
// We need to flatten it before passing to event_stream.merge
if (content.includes('await Promise.all(webpackConfigLocations.map(async')) {
  // Find where the map closes - look for the closing of the flatMap callback
  // Pattern: }); followed by event_stream_1.default.merge(...webpackStreams
  const lines = content.split('\n');
  const result = [];
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
      
      // When we close the map callback, check if next line is event_stream merge
      if (braceCount === 0 && line.includes('});')) {
        result.push(line);
        // Check next line for event_stream merge
        if (i + 1 < lines.length && lines[i + 1].includes('event_stream_1.default.merge(...webpackStreams')) {
          // Add flattening before the merge
          const indent = line.match(/^(\s*)/)[1] || '        ';
          result.push(indent + 'const flattenedWebpackStreams = [].concat(...webpackStreams);');
          foundMapStart = false;
          continue;
        }
        foundMapStart = false;
      }
    }
    
    result.push(line);
  }
  
  content = result.join('\n');
  
  // Replace event_stream merge to use flattened array
  content = content.replace(
    /event_stream_1\.default\.merge\(\.\.\.webpackStreams/g,
    'event_stream_1.default.merge(...flattenedWebpackStreams'
  );
}

fs.writeFileSync(filePath, content, 'utf8');
console.log('Patched extensions.js successfully');
PREBUILDPATCH
      
      node "$PRE_BUILD_PATCH_SCRIPT" "build/lib/extensions.js" 2>&1 || {
        echo "Warning: Pre-build patch failed. Restoring backup..." >&2
        if [[ -f "build/lib/extensions.js.bak" ]]; then
          mv "build/lib/extensions.js.bak" "build/lib/extensions.js" 2>/dev/null || true
        fi
      }
      rm -f "$PRE_BUILD_PATCH_SCRIPT"
      
      # Verify patch
      if grep -q "pathToFileURL" "build/lib/extensions.js" 2>/dev/null && ! grep -q "require(webpackConfigPath).default" "build/lib/extensions.js" 2>/dev/null; then
        echo "Patch verified successfully." >&2
      else
        echo "ERROR: Patch verification failed!" >&2
        echo "pathToFileURL found: $(grep -c 'pathToFileURL' build/lib/extensions.js 2>/dev/null || echo 0)" >&2
        echo "require(webpackConfigPath) still found: $(grep -c 'require(webpackConfigPath)' build/lib/extensions.js 2>/dev/null || echo 0)" >&2
        if [[ -f "build/lib/extensions.js.bak" ]]; then
          echo "Restoring backup..." >&2
          mv "build/lib/extensions.js.bak" "build/lib/extensions.js" 2>/dev/null || true
        fi
      fi
    else
      echo "No require(webpackConfigPath) found - patch may already be applied." >&2
      echo "Ensuring .mjs copies for ESM configs..." >&2
      PRE_BUILD_PATCH_SCRIPT=$(mktemp /tmp/fix-extensions-pre-build-ensure.XXXXXX.js) || {
        PRE_BUILD_PATCH_SCRIPT="/tmp/fix-extensions-pre-build-ensure.js"
      }
      cp "build/lib/extensions.js" "build/lib/extensions.js.bak" 2>/dev/null || true
      cat > "$PRE_BUILD_PATCH_SCRIPT" << 'PREBUILDPATCH_FORCE'
const fs = require('fs');
const filePath = process.argv[2];
let content = fs.readFileSync(filePath, 'utf8');

// Ensure fromLocal handles Promise-returning streams
const fromLocalTailPattern = /if\s*\(isWebPacked\)\s*\{\s*input\s*=\s*updateExtensionPackageJSON\(([\s\S]*?)\);\s*\}\s*return\s+input;/;
if (fromLocalTailPattern.test(content)) {
  content = content.replace(fromLocalTailPattern, `if (input && typeof input.then === 'function') {
        const proxyStream = event_stream_1.default.through();
        input.then((actualStream) => {
            actualStream.pipe(proxyStream);
        }).catch((err) => proxyStream.emit('error', err));
        input = proxyStream;
    }

    if (isWebPacked) {
        input = updateExtensionPackageJSON($1);
    }
    return input;`);
}

// Ensure fromLocalWebpack is async and has imports
if (content.includes('function fromLocalWebpack(') && !content.includes('async function fromLocalWebpack')) {
  content = content.replace(/function\s+fromLocalWebpack\(/g, 'async function fromLocalWebpack(');
}
if (content.includes('function fromLocalWebpack')) {
  const funcStart = content.indexOf('async function fromLocalWebpack');
  if (funcStart !== -1) {
    const afterBrace = content.indexOf('{', funcStart) + 1;
    const before = content.substring(0, afterBrace);
    const after = content.substring(afterBrace);
    if (!before.includes('pathToFileURL')) {
      const firstLineMatch = after.match(/^(\s*)/);
      const indent = firstLineMatch ? firstLineMatch[1] : '    ';
      content = before + '\n' + indent + 'const { pathToFileURL } = require("url");\n' + indent + 'const path = require("path");' + after;
    }
  }
}

const rootImportPattern = /const\s+webpackRootConfig\s*=\s*\(await\s+import\([^;]+\)\)\.default;/g;
const rootReplacement = `let rootConfigPath = path_1.default.join(extensionPath, webpackConfigFileName);
        if (rootConfigPath.endsWith('.js')) {
            const rootMjsPath = rootConfigPath.replace(/\.js$/, '.mjs');
            try {
                const srcStat = fs_1.default.statSync(rootConfigPath);
                const destStat = fs_1.default.existsSync(rootMjsPath) ? fs_1.default.statSync(rootMjsPath) : undefined;
                if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
                    fs_1.default.copyFileSync(rootConfigPath, rootMjsPath);
                }
            } catch (error) {
                // ignore copy errors
            }
            rootConfigPath = rootMjsPath;
        }
        const webpackRootConfig = (await import(pathToFileURL(path_1.default.resolve(rootConfigPath)).href)).default;`;
content = content.replace(rootImportPattern, rootReplacement);

const exportedImportPattern = /const\s+exportedConfig\s*=\s*\(await\s+import\([^;]+\)\)\.default;/g;
const exportedReplacement = `let configToLoad = webpackConfigPath;
            if (configToLoad.endsWith('.js')) {
                const mjsPath = configToLoad.replace(/\.js$/, '.mjs');
                try {
                    const srcStat = fs_1.default.statSync(configToLoad);
                    const destStat = fs_1.default.existsSync(mjsPath) ? fs_1.default.statSync(mjsPath) : undefined;
                    if (!destStat || srcStat.mtimeMs > destStat.mtimeMs) {
                        fs_1.default.copyFileSync(configToLoad, mjsPath);
                    }
                } catch (error) {
                    // ignore copy errors
                }
                configToLoad = mjsPath;
            }
            const exportedConfig = (await import(pathToFileURL(path_1.default.resolve(configToLoad)).href)).default;`;
content = content.replace(exportedImportPattern, exportedReplacement);

fs.writeFileSync(filePath, content, 'utf8');
console.log('Ensured .mjs copies for ESM configs');
PREBUILDPATCH_FORCE

      node "$PRE_BUILD_PATCH_SCRIPT" "build/lib/extensions.js" 2>&1 || {
        echo "Warning: ensure patch failed. Restoring backup..." >&2
        if [[ -f "build/lib/extensions.js.bak" ]]; then
          mv "build/lib/extensions.js.bak" "build/lib/extensions.js" 2>/dev/null || true
        fi
      }
      rm -f "$PRE_BUILD_PATCH_SCRIPT"
    fi
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
  
  # CRITICAL: Verify out-vscode-min has required files before packaging
  echo "Verifying out-vscode-min directory has required files..."
  CRITICAL_FILES=(
    "out-vscode-min/vs/workbench/workbench.desktop.main.js"
    "out-vscode-min/vs/base/common/lifecycle.js"
    "out-vscode-min/vs/platform/theme/common/theme.js"
    "out-vscode-min/main.js"
    "out-vscode-min/cli.js"
    "out-vscode-min/vs/code/electron-browser/workbench/workbench.html"
  )
  
  MISSING_FILES=0
  for file in "${CRITICAL_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: Critical file missing from out-vscode-min: ${file}" >&2
      MISSING_FILES=$((MISSING_FILES + 1))
    fi
  done
  
  if [[ ${MISSING_FILES} -gt 0 ]]; then
    echo "WARNING: ${MISSING_FILES} critical file(s) missing from out-vscode-min!" >&2
    echo "  The minify-vscode task may not have copied all individual module files." >&2
    echo "  Attempting to copy missing files from out-build..." >&2
    
    COPIED_COUNT=0
    for file in "${CRITICAL_FILES[@]}"; do
      if [[ ! -f "${file}" ]]; then
        out_build_file="${file/out-vscode-min/out-build}"
        if [[ -f "${out_build_file}" ]]; then
          # Create destination directory if it doesn't exist
          dest_dir=$(dirname "${file}")
          mkdir -p "${dest_dir}"
          # Copy the file
          if cp "${out_build_file}" "${file}" 2>/dev/null; then
            echo "  ✓ Copied ${file} from out-build" >&2
            COPIED_COUNT=$((COPIED_COUNT + 1))
          else
            echo "  ✗ Failed to copy ${file}" >&2
          fi
        else
          echo "  ✗ File not found in out-build: ${out_build_file}" >&2
        fi
      fi
    done
    
    if [[ ${COPIED_COUNT} -lt ${MISSING_FILES} ]]; then
      echo "ERROR: Could not copy all missing files. ${MISSING_FILES} file(s) still missing." >&2
      echo "  This will cause runtime errors." >&2
      exit 1
    else
      echo "  ✓ Successfully copied ${COPIED_COUNT} missing file(s) from out-build" >&2
      echo "  Note: This is a workaround. The minify-vscode task should copy these files." >&2
    fi
  fi
  
  echo "✓ Verified critical files exist in out-vscode-min"

  if [[ "${OS_NAME}" == "osx" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies darwin # Void commented this out

    echo "Building macOS package for ${VSCODE_ARCH}..."
    ensure_electron_cached "darwin" "${VSCODE_ARCH}" || {
      echo "Warning: Electron cache warm-up failed; gulp will download directly." >&2
    }
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

    # CRITICAL: Verify workbench.html exists in the built app to prevent blank screen
    echo "Verifying critical files in macOS app bundle..."
    # Get the actual app bundle name from product.json (nameShort), not APP_NAME
    # The app bundle is named after nameShort (e.g., "CortexIDE.app" or "CortexIDE - Insiders.app")
    if [[ ! -f "product.json" ]]; then
      echo "ERROR: product.json not found! Cannot determine app bundle name." >&2
      exit 1
    fi
    APP_BUNDLE_NAME=$( node -p "require('./product.json').nameShort || 'CortexIDE'" )
    if [[ -z "${APP_BUNDLE_NAME}" || "${APP_BUNDLE_NAME}" == "null" || "${APP_BUNDLE_NAME}" == "undefined" ]]; then
      echo "WARNING: nameShort not found in product.json, using APP_NAME as fallback" >&2
      APP_BUNDLE_NAME="${APP_NAME:-CortexIDE}"
    fi
    APP_BUNDLE="../VSCode-darwin-${VSCODE_ARCH}/${APP_BUNDLE_NAME}.app"
    
    # Verify the app bundle exists
    if [[ ! -d "${APP_BUNDLE}" ]]; then
      echo "ERROR: App bundle not found at expected location!" >&2
      echo "  Expected: ${APP_BUNDLE}" >&2
      echo "  Looking for alternative locations..." >&2
      # Try to find the actual app bundle
      if [[ -d "../VSCode-darwin-${VSCODE_ARCH}" ]]; then
        FOUND_BUNDLE=$( find "../VSCode-darwin-${VSCODE_ARCH}" -name "*.app" -type d | head -1 )
        if [[ -n "${FOUND_BUNDLE}" ]]; then
          echo "  Found app bundle at: ${FOUND_BUNDLE}" >&2
          APP_BUNDLE="${FOUND_BUNDLE}"
        else
          echo "  No .app bundle found in VSCode-darwin-${VSCODE_ARCH}!" >&2
          exit 1
        fi
      else
        echo "  VSCode-darwin-${VSCODE_ARCH} directory not found!" >&2
        exit 1
      fi
    fi
    
    WORKBENCH_HTML="${APP_BUNDLE}/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html"
    PRODUCT_JSON="${APP_BUNDLE}/Contents/Resources/app/product.json"
    
    if [[ ! -f "${WORKBENCH_HTML}" ]]; then
      echo "ERROR: workbench.html is missing from app bundle!" >&2
      echo "  Expected at: ${WORKBENCH_HTML}" >&2
      echo "  App bundle: ${APP_BUNDLE}" >&2
      echo "  This will cause a blank screen. Checking if file exists in out-build..." >&2
      if [[ -f "out-build/vs/code/electron-browser/workbench/workbench.html" ]]; then
        echo "  workbench.html exists in out-build but wasn't copied to app bundle!" >&2
        echo "  This indicates a packaging issue in gulpfile.vscode.js" >&2
        echo "  Attempting to manually copy workbench.html..." >&2
        mkdir -p "$(dirname "${WORKBENCH_HTML}")"
        cp "out-build/vs/code/electron-browser/workbench/workbench.html" "${WORKBENCH_HTML}" || {
          echo "  Failed to copy workbench.html!" >&2
          exit 1
        }
        echo "  ✓ Manually copied workbench.html to app bundle" >&2
      else
        echo "  workbench.html is also missing from out-build!" >&2
        echo "  The minify-vscode task may have failed silently." >&2
      exit 1
      fi
    fi
    
    # Verify product.json exists and has correct extensionsGallery
    if [[ ! -f "${PRODUCT_JSON}" ]]; then
      echo "ERROR: product.json is missing from app bundle!" >&2
      echo "  Expected at: ${PRODUCT_JSON}" >&2
      echo "  App bundle: ${APP_BUNDLE}" >&2
      exit 1
    fi
    
    # Verify extensionsGallery is correctly set (should be Open VSX, not Microsoft)
    if ! jq -e '.extensionsGallery.serviceUrl | contains("open-vsx")' "${PRODUCT_JSON}" >/dev/null 2>&1; then
      echo "ERROR: product.json in app bundle has incorrect extensionsGallery!" >&2
      echo "  Current serviceUrl: $(jq -r '.extensionsGallery.serviceUrl // "MISSING"' "${PRODUCT_JSON}")" >&2
      echo "  This will cause extension marketplace failures at runtime!" >&2
      exit 1
    fi
    
    # CRITICAL: Verify all required JS files are present in app bundle
    echo "Verifying required JS files in app bundle..."
    APP_OUT_DIR="${APP_BUNDLE}/Contents/Resources/app/out"

    if ! ensure_bundle_out_file "macOS app bundle" "${APP_OUT_DIR}" "main.js"; then
      exit 1
    fi

    if ! ensure_bundle_out_file "macOS app bundle" "${APP_OUT_DIR}" "cli.js"; then
      exit 1
    fi
    
    # First, check if the out directory exists and has files
    if [[ ! -d "${APP_OUT_DIR}" ]]; then
      echo "ERROR: out directory does not exist in app bundle: ${APP_OUT_DIR}" >&2
      exit 1
    fi
    
    # Count JS files in app bundle
    JS_FILE_COUNT=$(find "${APP_OUT_DIR}" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${JS_FILE_COUNT} -eq 0 ]]; then
      echo "ERROR: No JS files found in app bundle out directory!" >&2
      echo "  This indicates a serious packaging failure." >&2
      exit 1
    fi
    echo "  Found ${JS_FILE_COUNT} JS files in app bundle"
    
    CRITICAL_JS_FILES=(
      "vs/workbench/workbench.desktop.main.js"
      "vs/base/common/lifecycle.js"
      "vs/platform/theme/common/theme.js"
      "vs/platform/theme/common/themeService.js"
      "vs/base/common/uri.js"
      "vs/base/common/path.js"
      "vs/platform/instantiation/common/instantiation.js"
      "vs/platform/commands/common/commands.js"
    )
    
    MISSING_JS_FILES=0
    MISSING_FILE_LIST=()
    for js_file in "${CRITICAL_JS_FILES[@]}"; do
      full_path="${APP_OUT_DIR}/${js_file}"
      if [[ ! -f "${full_path}" ]]; then
        echo "ERROR: Required JS file missing: ${full_path}" >&2
        MISSING_JS_FILES=$((MISSING_JS_FILES + 1))
        MISSING_FILE_LIST+=("${js_file}")
      fi
    done
    
    if [[ ${MISSING_JS_FILES} -gt 0 ]]; then
      echo "ERROR: ${MISSING_JS_FILES} required JS file(s) missing from app bundle!" >&2
      echo "  This will cause ERR_FILE_NOT_FOUND errors at runtime." >&2
      echo "  Attempting to copy missing files from available build outputs..." >&2
      
      for js_file in "${MISSING_FILE_LIST[@]}"; do
        dest_file="${APP_OUT_DIR}/${js_file}"
          mkdir -p "$(dirname "${dest_file}")"
        COPIED_FILE=0
        for source_root in "out-vscode-min" "out-build" "out"; do
          source_file="${source_root}/${js_file}"
          if [[ -f "${source_file}" ]]; then
            echo "  Copying ${js_file} from ${source_root}..." >&2
            if cp "${source_file}" "${dest_file}" 2>/dev/null; then
              echo "  ✓ Copied ${js_file} from ${source_root}" >&2
              MISSING_JS_FILES=$((MISSING_JS_FILES - 1))
              COPIED_FILE=1
              break
            else
              echo "  ✗ Failed to copy ${js_file} from ${source_root}" >&2
            fi
          fi
        done
        if [[ ${COPIED_FILE} -eq 0 ]]; then
          echo "  ✗ Source file not found: ${js_file} (checked out-vscode-min, out-build, out)" >&2
        fi
      done
      
      if [[ ${MISSING_JS_FILES} -gt 0 ]]; then
        echo "ERROR: ${MISSING_JS_FILES} file(s) could not be copied. Build may fail at runtime." >&2
        echo "  This indicates a serious packaging issue. Check:" >&2
        echo "  1. The minify-vscode task completed successfully" >&2
        echo "  2. The out-vscode-min directory has all required files" >&2
        echo "  3. The packaging task (vscode-darwin-*-min-ci) copied files correctly" >&2
        exit 1
      else
        echo "✓ All missing files were successfully copied" >&2
      fi
    fi
    
    # CRITICAL FIX: Copy ALL vs/ module files from out-vscode-min to app bundle
    # workbench.desktop.main.js has ES module imports for individual files that must exist
    # The bundler should bundle these, but it's not working correctly, so we copy all files
    # FALLBACK: If out-vscode-min doesn't have all files, also copy from out-build/out
    echo "Copying all vs/ module files from build outputs to the app bundle..." >&2
    COPIED_ANY=0
    
    for source_root in "out-vscode-min" "out-build" "out"; do
      if [[ -d "${source_root}/vs" ]]; then
        if [[ "${source_root}" == "out-vscode-min" ]]; then
          VS_FILES_COUNT=$(find "${source_root}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
          echo "  Found ${VS_FILES_COUNT} .js files in ${source_root}/vs" >&2
        else
          echo "  Also copying from ${source_root} to ensure all files are present..." >&2
        fi
        
        if rsync -a --include="vs/" --include="vs/**" --exclude="*" "${source_root}/" "${APP_OUT_DIR}/" 2>/dev/null; then
        FINAL_COUNT=$(find "${APP_OUT_DIR}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
          echo "  ✓ Copied VS modules from ${source_root} (${FINAL_COUNT} total .js files now in bundle)" >&2
        COPIED_ANY=1
      else
          # Fallback: use cp -R if rsync isn't available
          if cp -R "${source_root}/vs" "${APP_OUT_DIR}/" 2>/dev/null; then
          FINAL_COUNT=$(find "${APP_OUT_DIR}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✓ Copied VS modules from ${source_root} (${FINAL_COUNT} total .js files now in bundle)" >&2
          COPIED_ANY=1
        fi
      fi
      else
        if [[ "${source_root}" == "out-vscode-min" ]]; then
          echo "  ⚠ ${source_root}/vs directory not found, trying other build outputs..." >&2
    fi
      fi
    done
    
    if [[ ${COPIED_ANY} -eq 0 ]]; then
      echo "  ✗ ERROR: Failed to copy vs/ directory from out-vscode-min, out-build, or out!" >&2
      echo "  This will cause ERR_FILE_NOT_FOUND errors at runtime." >&2
      exit 1
    fi
    
    # Verify workbench.desktop.main.js exists (most critical file)
    WORKBENCH_MAIN="${APP_OUT_DIR}/vs/workbench/workbench.desktop.main.js"
    if [[ ! -f "${WORKBENCH_MAIN}" ]]; then
      echo "ERROR: workbench.desktop.main.js is missing! This is the most critical file." >&2
      echo "  This will cause the app to fail immediately on launch." >&2
      exit 1
    fi
    
    echo "✓ Critical files verified in app bundle: ${APP_BUNDLE}"

    if [[ -x "./verify_bundle_files.sh" ]]; then
      echo "Running verify_bundle_files.sh for macOS bundle..."
      if ! ./verify_bundle_files.sh "${APP_BUNDLE}"; then
        echo "ERROR: verify_bundle_files.sh detected missing files in ${APP_BUNDLE}" >&2
        exit 1
      fi
    else
      echo "Warning: verify_bundle_files.sh not executable; skipping bundle verification script." >&2
    fi
    
    if [[ -x "./test_blank_screen.sh" ]]; then
      echo "Running comprehensive blank screen prevention test..."
      if ! ./test_blank_screen.sh "${APP_BUNDLE}"; then
        echo "ERROR: Blank screen prevention test failed for ${APP_BUNDLE}" >&2
        echo "  This bundle will likely show a blank screen when launched." >&2
        exit 1
      fi
    else
      echo "Warning: test_blank_screen.sh not executable; skipping blank screen test." >&2
    fi

    echo ""
    echo "Note: If you encounter a blank screen after installation, run:"
    echo "  ./fix_macos_blank_screen.sh"
    echo "  See docs/troubleshooting.md for more help"
    echo ""
    echo "IMPORTANT: If the app launches but no window appears (processes run but window is missing),"
    echo "  this may indicate a window creation issue in the main process. Check:"
    echo "  - Window bounds are valid (not 0x0 or off-screen)"
    echo "  - Window.show() or window.showInactive() is being called"
    echo "  - Window is not being created with show: false"
    echo "  This may require a code fix in the cortexide source repository."
    echo ""

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

      # CRITICAL FIX: Make rcedit optional when wine is not available
      # rcedit requires wine on Linux, but wine may not be installed
      if [[ -f "build/gulpfile.vscode.js" ]]; then
        echo "Patching gulpfile.vscode.js to make rcedit optional when wine is unavailable..." >&2
        node << 'RCEDITFIX' || {
const fs = require('fs');
const filePath = 'build/gulpfile.vscode.js';
let content = fs.readFileSync(filePath, 'utf8');

if (content.includes('// RCEDIT_WINE_FIX')) {
  console.error('gulpfile.vscode.js already patched for rcedit/wine');
  process.exit(0);
}

const lines = content.split('\n');
let modified = false;

for (let i = 0; i < lines.length; i++) {
  if (lines[i].includes('await rcedit(path.join(cwd, dep), {')) {
    const indent = lines[i].match(/^\s*/)[0];
    lines[i] = `${indent}try {\n${lines[i]}`;
    
    let rceditCloseLine = -1;
    for (let j = i + 1; j < lines.length && j <= i + 15; j++) {
      if (lines[j].includes('});') && lines[j].match(/^\s*/)[0].length === indent.length) {
        rceditCloseLine = j;
        break;
      }
    }
    
    if (rceditCloseLine >= 0) {
      lines[rceditCloseLine] = `${lines[rceditCloseLine]}\n${indent}} catch (err) {\n${indent}  // RCEDIT_WINE_FIX: rcedit requires wine on Linux, skip if not available\n${indent}  if (err.message && (err.message.includes('wine') || err.message.includes('ENOENT') || err.code === 'ENOENT')) {\n${indent}    console.warn('Skipping rcedit (wine not available):', err.message);\n${indent}  } else {\n${indent}    throw err;\n${indent}  }\n${indent}}`;
      modified = true;
      console.error(`✓ Wrapped rcedit in try-catch at line ${i + 1}`);
      break;
    }
  }
}

if (modified) {
  content = lines.join('\n');
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched gulpfile.vscode.js to make rcedit optional');
}
RCEDITFIX
          echo "Warning: Failed to patch gulpfile.vscode.js for rcedit, continuing anyway..." >&2
        }
      fi

      # CRITICAL FIX: Skip AppX building if win32ContextMenu is missing
      # AppX packages are for Windows Store and require win32ContextMenu in product.json
      if [[ -f "build/gulpfile.vscode.js" ]]; then
        echo "Checking for win32ContextMenu in product.json..." >&2
        node << 'APPXFIX' || {
const fs = require('fs');
const productPath = 'product.json';
const gulpfilePath = 'build/gulpfile.vscode.js';

try {
  // Check if win32ContextMenu exists in product.json
  const product = JSON.parse(fs.readFileSync(productPath, 'utf8'));
  const hasWin32ContextMenu = product.win32ContextMenu && 
                               product.win32ContextMenu.x64 && 
                               product.win32ContextMenu.x64.clsid;
  
  if (!hasWin32ContextMenu) {
    console.error('win32ContextMenu missing in product.json, skipping AppX build...');
    
    // Patch gulpfile.vscode.js to skip AppX building
    let content = fs.readFileSync(gulpfilePath, 'utf8');
    const lines = content.split('\n');
    let modified = false;
    
    // Find the AppX building block (lines 409-424)
    for (let i = 0; i < lines.length; i++) {
      // Find: if (quality === 'stable' || quality === 'insider') {
      if (lines[i].includes("if (quality === 'stable' || quality === 'insider')") && 
          i + 1 < lines.length && 
          lines[i + 1].includes('.build/win32/appx')) {
        // Check if already patched
        if (lines[i].includes('product.win32ContextMenu')) {
          console.error('Already has win32ContextMenu check');
          break;
        }
        
        // Add check for win32ContextMenu before AppX building
        const indent = lines[i].match(/^\s*/)[0];
        const newCondition = `${indent}if ((quality === 'stable' || quality === 'insider') && product.win32ContextMenu && product.win32ContextMenu[arch]) {`;
        lines[i] = newCondition;
        modified = true;
        console.error(`✓ Added win32ContextMenu check at line ${i + 1}`);
        break;
      }
    }
    
    if (modified) {
      content = lines.join('\n');
      fs.writeFileSync(gulpfilePath, content, 'utf8');
      console.error('✓ Successfully patched gulpfile.vscode.js to skip AppX when win32ContextMenu is missing');
    }
  } else {
    console.error('✓ win32ContextMenu found in product.json, AppX building enabled');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  process.exit(1);
}
APPXFIX
          echo "Warning: Failed to patch gulpfile.vscode.js for AppX, continuing anyway..." >&2
        }
      fi

      echo "Building Windows package for ${VSCODE_ARCH}..."

      if ! npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"; then
        echo "Error: Windows build failed for ${VSCODE_ARCH}. Check for:" >&2
        echo "  - Electron packaging errors" >&2
        echo "  - Missing build artifacts" >&2
        echo "  - Architecture mismatch" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi

      # Optional: Patch InnoSetup code.iss to escape PowerShell curly braces AFTER gulp task
      # Disabled by default because the naive escaping was breaking other Run entries.
      # Set PATCH_INNO_POWERSHELL=yes to re-enable once a safer implementation exists.
      PATCH_INNO_POWERSHELL="${PATCH_INNO_POWERSHELL:-no}"
      if [[ "${PATCH_INNO_POWERSHELL}" == "yes" ]]; then
      if [[ -f "vscode/build/win32/code.iss" ]]; then
        echo "Patching InnoSetup code.iss to escape PowerShell curly braces (after gulp task)..." >&2
        node << 'POWERSHELLESCAPEFIX' || {
const fs = require('fs');
const filePath = 'vscode/build/win32/code.iss';

try {
  let content = fs.readFileSync(filePath, 'utf8');
  const originalContent = content;
  let modified = false;

  // Find [Run] section
  const runSectionMatch = content.match(/\[Run\][\s\S]*?(?=\[|$)/m);
  if (runSectionMatch) {
    const runSection = runSectionMatch[0];
    let newRunSection = runSection;
    const originalRunSection = runSection;

    // Step 1: Temporarily replace Inno Setup constants with placeholders
    const constants = [
      '{code:GetShellFolderPath|0}',
      '{tmp}', '{app}', '{sys}', '{pf}', '{cf}', 
      '{userdocs}', '{commondocs}', '{userappdata}', '{commonappdata}', '{localappdata}', 
      '{sendto}', '{startmenu}', '{startup}', '{desktop}', '{fonts}', '{group}', '{reg}'
    ];
    const placeholders = {};
    constants.forEach((constant, idx) => {
      const placeholder = `__INNO_CONST_${idx}__`;
      placeholders[placeholder] = constant;
      const escaped = constant.replace(/[{}()\[\]\\^$.*+?|]/g, '\\$&');
      const regex = new RegExp(escaped, 'g');
      newRunSection = newRunSection.replace(regex, placeholder);
    });

    // Step 2: Escape all remaining { and } (these belong to PowerShell)
    newRunSection = newRunSection.replace(/\{/g, '{{').replace(/\}/g, '}}');

    // Step 3: Restore Inno Setup constants from placeholders
    Object.keys(placeholders).reverse().forEach(placeholder => {
      const constant = placeholders[placeholder];
      const regex = new RegExp(placeholder.replace(/[()\[\]\\^$.*+?|]/g, '\\$&'), 'g');
      newRunSection = newRunSection.replace(regex, constant);
    });

    if (newRunSection !== originalRunSection) {
      content = content.replace(originalRunSection, newRunSection);
      modified = true;
      console.error('✓ Successfully escaped PowerShell curly braces in [Run] section');
      
      // Debug: Show line 114 if it exists (where the error occurs)
      const lines = content.split(/\r?\n/);
      if (lines.length >= 114) {
        console.error(`  Line 114: ${lines[113].substring(0, 100)}...`);
      }
    } else {
      console.error('⚠ No changes made to [Run] section');
    }
  } else {
    console.error('⚠ [Run] section not found in code.iss');
  }

  if (modified) {
    const hasCRLF = originalContent.includes('\r\n');
    const lineEnding = hasCRLF ? '\r\n' : '\n';
    if (!content.endsWith(lineEnding)) {
      content += lineEnding;
    }
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Saved patched code.iss file');
  } else {
    console.error('⚠ No PowerShell escaping needed or [Run] section not found');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
}
POWERSHELLESCAPEFIX
          echo "Warning: Failed to patch code.iss for PowerShell escaping, continuing anyway..." >&2
        }
      else
        echo "Warning: code.iss not found after gulp task, cannot patch for PowerShell escaping" >&2
        fi
      else
        echo "Skipping PowerShell escaping patch (PATCH_INNO_POWERSHELL!=yes)" >&2
      fi

      # CRITICAL: Verify workbench.html exists in the built Windows package to prevent blank screen
      echo "Verifying critical files in Windows package..."
      WORKBENCH_HTML="${WIN_PACKAGE}/resources/app/out/vs/code/electron-browser/workbench/workbench.html"
      PRODUCT_JSON="${WIN_PACKAGE}/resources/app/product.json"
      
      if [[ ! -f "${WORKBENCH_HTML}" ]]; then
        echo "ERROR: workbench.html is missing from Windows package!" >&2
        echo "  Expected at: ${WORKBENCH_HTML}" >&2
        echo "  This will cause a blank screen. Checking if file exists in out-build..." >&2
        if [[ -f "out-build/vs/code/electron-browser/workbench/workbench.html" ]]; then
          echo "  workbench.html exists in out-build but wasn't copied to package!" >&2
          echo "  This indicates a packaging issue in gulpfile.vscode.js" >&2
          echo "  Attempting to manually copy workbench.html..." >&2
          mkdir -p "$(dirname "${WORKBENCH_HTML}")"
          cp "out-build/vs/code/electron-browser/workbench/workbench.html" "${WORKBENCH_HTML}" || {
            echo "  Failed to copy workbench.html!" >&2
            exit 1
          }
          echo "  ✓ Manually copied workbench.html to Windows package" >&2
        else
          echo "  workbench.html is also missing from out-build!" >&2
          echo "  The minify-vscode task may have failed silently." >&2
          exit 1
        fi
      fi
      
      # Verify product.json exists and has correct extensionsGallery
      if [[ ! -f "${PRODUCT_JSON}" ]]; then
        echo "ERROR: product.json is missing from Windows package!" >&2
        echo "  Expected at: ${PRODUCT_JSON}" >&2
        exit 1
      fi
      
      if ! jq -e '.extensionsGallery.serviceUrl | contains("open-vsx")' "${PRODUCT_JSON}" >/dev/null 2>&1; then
        echo "ERROR: product.json in Windows package has incorrect extensionsGallery!" >&2
        echo "  Current serviceUrl: $(jq -r '.extensionsGallery.serviceUrl // "MISSING"' "${PRODUCT_JSON}")" >&2
        exit 1
      fi
      
      # CRITICAL: Verify all required JS files are present in Windows package
      echo "Verifying required JS files in Windows package..."
      WIN_OUT_DIR="${WIN_PACKAGE}/resources/app/out"

      if ! ensure_bundle_out_file "Windows package" "${WIN_OUT_DIR}" "main.js"; then
        exit 1
      fi

      if ! ensure_bundle_out_file "Windows package" "${WIN_OUT_DIR}" "cli.js"; then
        exit 1
      fi
      
      # First, check if the out directory exists and has files
      if [[ ! -d "${WIN_OUT_DIR}" ]]; then
        echo "ERROR: out directory does not exist in Windows package: ${WIN_OUT_DIR}" >&2
        exit 1
      fi
      
      # Count JS files in package
      JS_FILE_COUNT=$(find "${WIN_OUT_DIR}" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
      if [[ ${JS_FILE_COUNT} -eq 0 ]]; then
        echo "ERROR: No JS files found in Windows package out directory!" >&2
        echo "  This indicates a serious packaging failure." >&2
        exit 1
      fi
      echo "  Found ${JS_FILE_COUNT} JS files in Windows package"
      
      CRITICAL_JS_FILES=(
        "vs/workbench/workbench.desktop.main.js"
        "vs/base/common/lifecycle.js"
        "vs/platform/theme/common/theme.js"
        "vs/platform/theme/common/themeService.js"
        "vs/base/common/uri.js"
        "vs/base/common/path.js"
        "vs/platform/instantiation/common/instantiation.js"
        "vs/platform/commands/common/commands.js"
      )
      
      MISSING_JS_FILES=0
      MISSING_FILE_LIST=()
      for js_file in "${CRITICAL_JS_FILES[@]}"; do
        full_path="${WIN_OUT_DIR}/${js_file}"
        if [[ ! -f "${full_path}" ]]; then
          echo "ERROR: Required JS file missing: ${full_path}" >&2
          MISSING_JS_FILES=$((MISSING_JS_FILES + 1))
          MISSING_FILE_LIST+=("${js_file}")
        fi
      done
      
      if [[ ${MISSING_JS_FILES} -gt 0 ]]; then
        echo "ERROR: ${MISSING_JS_FILES} required JS file(s) missing from Windows package!" >&2
        echo "  This will cause ERR_FILE_NOT_FOUND errors at runtime." >&2
        echo "  Attempting to copy missing files from available build outputs..." >&2
        
        for js_file in "${MISSING_FILE_LIST[@]}"; do
          dest_file="${WIN_OUT_DIR}/${js_file}"
            mkdir -p "$(dirname "${dest_file}")"
          COPIED_FILE=0
          for source_root in "out-vscode-min" "out-build" "out"; do
            source_file="${source_root}/${js_file}"
            if [[ -f "${source_file}" ]]; then
              echo "  Copying ${js_file} from ${source_root}..." >&2
              if cp "${source_file}" "${dest_file}" 2>/dev/null; then
                echo "  ✓ Copied ${js_file} from ${source_root}" >&2
                MISSING_JS_FILES=$((MISSING_JS_FILES - 1))
                COPIED_FILE=1
                break
              else
                echo "  ✗ Failed to copy ${js_file} from ${source_root}" >&2
              fi
            fi
          done
          if [[ ${COPIED_FILE} -eq 0 ]]; then
            echo "  ✗ Source file not found: ${js_file} (checked out-vscode-min, out-build, out)" >&2
          fi
        done
        
        if [[ ${MISSING_JS_FILES} -gt 0 ]]; then
          echo "ERROR: ${MISSING_JS_FILES} file(s) could not be copied. Build may fail at runtime." >&2
          echo "  This indicates a serious packaging issue. Check:" >&2
          echo "  1. The minify-vscode task completed successfully" >&2
          echo "  2. The out-vscode-min directory has all required files" >&2
          echo "  3. The packaging task (vscode-win32-*-min-ci) copied files correctly" >&2
          exit 1
        else
          echo "✓ All missing files were successfully copied" >&2
        fi
      fi
      
      # CRITICAL FIX: Copy ALL vs/ module files from out-vscode-min to Windows package
      # workbench.desktop.main.js has ES module imports for individual files that must exist
      # FALLBACK: If out-vscode-min doesn't have all files, also copy from out-build/out
      echo "Copying all vs/ module files from build outputs to Windows package..." >&2
      COPIED_ANY=0
      
      for source_root in "out-vscode-min" "out-build" "out"; do
        if [[ -d "${source_root}/vs" ]]; then
          if [[ "${source_root}" == "out-vscode-min" ]]; then
            VS_FILES_COUNT=$(find "${source_root}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
            echo "  Found ${VS_FILES_COUNT} .js files in ${source_root}/vs" >&2
          else
            echo "  Also copying from ${source_root} to ensure all files are present..." >&2
          fi
        
          if rsync -a --include="vs/" --include="vs/**" --exclude="*" "${source_root}/" "${WIN_OUT_DIR}/" 2>/dev/null; then
          FINAL_COUNT=$(find "${WIN_OUT_DIR}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✓ Copied VS modules from ${source_root} (${FINAL_COUNT} total .js files now in package)" >&2
          COPIED_ANY=1
        else
            if cp -R "${source_root}/vs" "${WIN_OUT_DIR}/" 2>/dev/null; then
            FINAL_COUNT=$(find "${WIN_OUT_DIR}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
              echo "  ✓ Copied VS modules from ${source_root} (${FINAL_COUNT} total .js files now in package)" >&2
            COPIED_ANY=1
          fi
        fi
        else
          if [[ "${source_root}" == "out-vscode-min" ]]; then
            echo "  ⚠ ${source_root}/vs directory not found, trying other build outputs..." >&2
      fi
        fi
      done
      
      if [[ ${COPIED_ANY} -eq 0 ]]; then
        echo "  ✗ ERROR: Failed to copy vs/ directory from out-vscode-min, out-build, or out!" >&2
        echo "  This will cause ERR_FILE_NOT_FOUND errors at runtime." >&2
        exit 1
      fi
      
      # Verify workbench.desktop.main.js exists (most critical file)
      WORKBENCH_MAIN="${WIN_OUT_DIR}/vs/workbench/workbench.desktop.main.js"
      if [[ ! -f "${WORKBENCH_MAIN}" ]]; then
        echo "ERROR: workbench.desktop.main.js is missing! This is the most critical file." >&2
        echo "  This will cause the app to fail immediately on launch." >&2
        exit 1
      fi
      
      echo "✓ Critical files verified in Windows package"

      if [[ -x "./verify_bundle_files.sh" ]]; then
        echo "Running verify_bundle_files.sh for Windows package..."
        if ! ./verify_bundle_files.sh "${WIN_PACKAGE}"; then
          echo "ERROR: verify_bundle_files.sh detected missing files in ${WIN_PACKAGE}" >&2
          exit 1
        fi
      else
        echo "Warning: verify_bundle_files.sh not executable; skipping bundle verification script." >&2
      fi
      
      if [[ -x "./test_blank_screen.sh" ]]; then
        echo "Running comprehensive blank screen prevention test for Windows package..."
        if ! ./test_blank_screen.sh "${WIN_PACKAGE}"; then
          echo "ERROR: Blank screen prevention test failed for ${WIN_PACKAGE}" >&2
          echo "  This package will likely show a blank screen when launched." >&2
          exit 1
        fi
      else
        echo "Warning: test_blank_screen.sh not executable; skipping blank screen test." >&2
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

      # CRITICAL: Verify workbench.html exists in the built Linux package to prevent blank screen
      echo "Verifying critical files in Linux package..."
      WORKBENCH_HTML="${LINUX_PACKAGE}/resources/app/out/vs/code/electron-browser/workbench/workbench.html"
      PRODUCT_JSON="${LINUX_PACKAGE}/resources/app/product.json"
      
      if [[ ! -f "${WORKBENCH_HTML}" ]]; then
        echo "ERROR: workbench.html is missing from Linux package!" >&2
        echo "  Expected at: ${WORKBENCH_HTML}" >&2
        echo "  This will cause a blank screen. Checking if file exists in out-build..." >&2
        if [[ -f "out-build/vs/code/electron-browser/workbench/workbench.html" ]]; then
          echo "  workbench.html exists in out-build but wasn't copied to package!" >&2
          echo "  This indicates a packaging issue in gulpfile.vscode.js" >&2
          echo "  Attempting to manually copy workbench.html..." >&2
          mkdir -p "$(dirname "${WORKBENCH_HTML}")"
          cp "out-build/vs/code/electron-browser/workbench/workbench.html" "${WORKBENCH_HTML}" || {
            echo "  Failed to copy workbench.html!" >&2
            exit 1
          }
          echo "  ✓ Manually copied workbench.html to Linux package" >&2
        else
          echo "  workbench.html is also missing from out-build!" >&2
          echo "  The minify-vscode task may have failed silently." >&2
          exit 1
        fi
      fi
      
      # Verify product.json exists and has correct extensionsGallery
      if [[ ! -f "${PRODUCT_JSON}" ]]; then
        echo "ERROR: product.json is missing from Linux package!" >&2
        echo "  Expected at: ${PRODUCT_JSON}" >&2
        exit 1
      fi
      
      if ! jq -e '.extensionsGallery.serviceUrl | contains("open-vsx")' "${PRODUCT_JSON}" >/dev/null 2>&1; then
        echo "ERROR: product.json in Linux package has incorrect extensionsGallery!" >&2
        echo "  Current serviceUrl: $(jq -r '.extensionsGallery.serviceUrl // "MISSING"' "${PRODUCT_JSON}")" >&2
        exit 1
      fi
      
      # CRITICAL: Verify all required JS files are present in Linux package
      echo "Verifying required JS files in Linux package..."
      LINUX_OUT_DIR="${LINUX_PACKAGE}/resources/app/out"
      
      # First, check if the out directory exists and has files
      if [[ ! -d "${LINUX_OUT_DIR}" ]]; then
        echo "ERROR: out directory does not exist in Linux package: ${LINUX_OUT_DIR}" >&2
        exit 1
      fi

      if ! ensure_bundle_out_file "Linux package" "${LINUX_OUT_DIR}" "main.js"; then
        exit 1
      fi

      if ! ensure_bundle_out_file "Linux package" "${LINUX_OUT_DIR}" "cli.js"; then
        exit 1
      fi
      
      # Count JS files in package
      JS_FILE_COUNT=$(find "${LINUX_OUT_DIR}" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
      if [[ ${JS_FILE_COUNT} -eq 0 ]]; then
        echo "ERROR: No JS files found in Linux package out directory!" >&2
        echo "  This indicates a serious packaging failure." >&2
        exit 1
      fi
      echo "  Found ${JS_FILE_COUNT} JS files in Linux package"
      
      CRITICAL_JS_FILES=(
        "vs/workbench/workbench.desktop.main.js"
        "vs/base/common/lifecycle.js"
        "vs/platform/theme/common/theme.js"
        "vs/platform/theme/common/themeService.js"
        "vs/base/common/uri.js"
        "vs/base/common/path.js"
        "vs/platform/instantiation/common/instantiation.js"
        "vs/platform/commands/common/commands.js"
      )
      
      MISSING_JS_FILES=0
      MISSING_FILE_LIST=()
      for js_file in "${CRITICAL_JS_FILES[@]}"; do
        full_path="${LINUX_OUT_DIR}/${js_file}"
        if [[ ! -f "${full_path}" ]]; then
          echo "ERROR: Required JS file missing: ${full_path}" >&2
          MISSING_JS_FILES=$((MISSING_JS_FILES + 1))
          MISSING_FILE_LIST+=("${js_file}")
        fi
      done
      
      if [[ ${MISSING_JS_FILES} -gt 0 ]]; then
        echo "ERROR: ${MISSING_JS_FILES} required JS file(s) missing from Linux package!" >&2
        echo "  This will cause ERR_FILE_NOT_FOUND errors at runtime." >&2
        echo "  Attempting to copy missing files from available build outputs..." >&2
        
        for js_file in "${MISSING_FILE_LIST[@]}"; do
          dest_file="${LINUX_OUT_DIR}/${js_file}"
            mkdir -p "$(dirname "${dest_file}")"
          COPIED_FILE=0
          for source_root in "out-vscode-min" "out-build" "out"; do
            source_file="${source_root}/${js_file}"
            if [[ -f "${source_file}" ]]; then
              echo "  Copying ${js_file} from ${source_root}..." >&2
              if cp "${source_file}" "${dest_file}" 2>/dev/null; then
                echo "  ✓ Copied ${js_file} from ${source_root}" >&2
                MISSING_JS_FILES=$((MISSING_JS_FILES - 1))
                COPIED_FILE=1
                break
              else
                echo "  ✗ Failed to copy ${js_file} from ${source_root}" >&2
              fi
            fi
          done
          if [[ ${COPIED_FILE} -eq 0 ]]; then
            echo "  ✗ Source file not found: ${js_file} (checked out-vscode-min, out-build, out)" >&2
          fi
        done
        
        if [[ ${MISSING_JS_FILES} -gt 0 ]]; then
          echo "ERROR: ${MISSING_JS_FILES} file(s) could not be copied. Build may fail at runtime." >&2
          echo "  This indicates a serious packaging issue. Check:" >&2
          echo "  1. The minify-vscode task completed successfully" >&2
          echo "  2. The out-vscode-min directory has all required files" >&2
          echo "  3. The packaging task (vscode-linux-*-min-ci) copied files correctly" >&2
          exit 1
        else
          echo "✓ All missing files were successfully copied" >&2
        fi
      fi
      
      # CRITICAL FIX: Copy ALL vs/ module files from out-vscode-min to Linux package
      # workbench.desktop.main.js has ES module imports for individual files that must exist
      # FALLBACK: If out-vscode-min doesn't have all files, also copy from out-build/out
      echo "Copying all vs/ module files from build outputs to Linux package..." >&2
      COPIED_ANY=0
      
      for source_root in "out-vscode-min" "out-build" "out"; do
        if [[ -d "${source_root}/vs" ]]; then
          if [[ "${source_root}" == "out-vscode-min" ]]; then
            VS_FILES_COUNT=$(find "${source_root}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
            echo "  Found ${VS_FILES_COUNT} .js files in ${source_root}/vs" >&2
          else
            echo "  Also copying from ${source_root} to ensure all files are present..." >&2
          fi
        
          if rsync -a --include="vs/" --include="vs/**" --exclude="*" "${source_root}/" "${LINUX_OUT_DIR}/" 2>/dev/null; then
          FINAL_COUNT=$(find "${LINUX_OUT_DIR}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✓ Copied VS modules from ${source_root} (${FINAL_COUNT} total .js files now in package)" >&2
          COPIED_ANY=1
        else
            if cp -R "${source_root}/vs" "${LINUX_OUT_DIR}/" 2>/dev/null; then
            FINAL_COUNT=$(find "${LINUX_OUT_DIR}/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
              echo "  ✓ Copied VS modules from ${source_root} (${FINAL_COUNT} total .js files now in package)" >&2
            COPIED_ANY=1
          fi
        fi
        else
          if [[ "${source_root}" == "out-vscode-min" ]]; then
            echo "  ⚠ ${source_root}/vs directory not found, trying other build outputs..." >&2
      fi
        fi
      done
      
      if [[ ${COPIED_ANY} -eq 0 ]]; then
        echo "  ✗ ERROR: Failed to copy vs/ directory from out-vscode-min, out-build, or out!" >&2
        echo "  This will cause ERR_FILE_NOT_FOUND errors at runtime." >&2
        exit 1
      fi
      
      # Verify workbench.desktop.main.js exists (most critical file)
      WORKBENCH_MAIN="${LINUX_OUT_DIR}/vs/workbench/workbench.desktop.main.js"
      if [[ ! -f "${WORKBENCH_MAIN}" ]]; then
        echo "ERROR: workbench.desktop.main.js is missing! This is the most critical file." >&2
        echo "  This will cause the app to fail immediately on launch." >&2
        exit 1
      fi
      
      echo "✓ Critical files verified in Linux package"

      if [[ -x "./verify_bundle_files.sh" ]]; then
        echo "Running verify_bundle_files.sh for Linux package..."
        if ! ./verify_bundle_files.sh "${LINUX_PACKAGE}"; then
          echo "ERROR: verify_bundle_files.sh detected missing files in ${LINUX_PACKAGE}" >&2
          exit 1
        fi
      else
        echo "Warning: verify_bundle_files.sh not executable; skipping bundle verification script." >&2
      fi
      
      if [[ -x "./test_blank_screen.sh" ]]; then
        echo "Running comprehensive blank screen prevention test for Linux package..."
        if ! ./test_blank_screen.sh "${LINUX_PACKAGE}"; then
          echo "ERROR: Blank screen prevention test failed for ${LINUX_PACKAGE}" >&2
          echo "  This package will likely show a blank screen when launched." >&2
          exit 1
        fi
      else
        echo "Warning: test_blank_screen.sh not executable; skipping blank screen test." >&2
      fi

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
    
    # CRITICAL FIX: Handle empty glob patterns in gulpfile.reh.js
    # Root cause: dependenciesSrc can be an empty array [], and allowEmpty: true doesn't work for empty arrays
    # Solution: Ensure dependenciesSrc is never empty by providing a fallback, OR handle empty case before gulp.src
    if [[ -f "build/gulpfile.reh.js" ]]; then
      echo "Applying critical fix to gulpfile.reh.js for empty glob patterns..." >&2
      
      # Use Node.js to apply the fix - ensure array is never empty
      node << 'NODEFIX' || {
const fs = require('fs');

const filePath = 'build/gulpfile.reh.js';

try {
  let content = fs.readFileSync(filePath, 'utf8');
  const original = content;
  const lines = content.split('\n');
  let modified = false;
  
  // Fix 1: dependenciesSrc - CRITICAL FIX
  // Root cause: empty array [] causes "Invalid glob argument" error
  // allowEmpty: true doesn't work for empty arrays, and ['!**'] needs a positive glob
  // Solution: Modify the assignment to include fallback, OR change const to let
  for (let i = 0; i < lines.length; i++) {
    // Find: const dependenciesSrc = ... .flat();
    if (lines[i].includes('const dependenciesSrc =') && lines[i].includes('.flat()')) {
      console.error(`Found dependenciesSrc at line ${i + 1}: ${lines[i].trim()}`);
      
      // Check if we already fixed it
      if (lines[i].includes('|| [\'**\', \'!**/*\']') || lines[i].includes('|| ["**", "!**/*"]')) {
        console.error('✓ Already has empty array protection');
      } else {
        // Change const to let so we can reassign, then add check
        const originalLine = lines[i];
        const indent = originalLine.match(/^\s*/)[0];
        
        // Change const to let
        let newLine = originalLine.replace(/const dependenciesSrc =/, 'let dependenciesSrc =');
        
        // Add fallback to the assignment: .flat() || ['**', '!**/*']
        newLine = newLine.replace(/\.flat\(\);?$/, ".flat() || ['**', '!**/*'];");
        
        lines[i] = newLine;
        
        // Add check on next line to handle empty case
        lines.splice(i + 1, 0, `${indent}if (dependenciesSrc.length === 0) { dependenciesSrc = ['**', '!**/*']; }`);
        
        modified = true;
        console.error(`✓ Changed const to let and added fallback at line ${i + 1}`);
        console.error(`✓ Added empty array check at line ${i + 2}`);
        console.error(`New line ${i + 1}: ${lines[i].trim()}`);
        console.error(`New line ${i + 2}: ${lines[i + 1].trim()}`);
      }
      break;
    }
  }
  
  // Fix 2: extensionPaths
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('gulp.src(extensionPaths') && lines[i].includes("base: '.build'")) {
      if (!lines[i].includes('allowEmpty: true')) {
        if (lines[i].trim().endsWith('})')) {
          lines[i] = lines[i].replace(/dot:\s*true\s*\}\)/, 'dot: true, allowEmpty: true })');
        } else if (lines[i].includes('dot: true')) {
          lines[i] = lines[i].replace(/dot:\s*true/, 'dot: true, allowEmpty: true');
        }
        modified = true;
        console.error(`✓ Fixed extensionPaths at line ${i + 1}`);
      }
      break;
    }
  }
  
  if (modified) {
    content = lines.join('\n');
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully applied allowEmpty fixes');
    
    // Final verification - check the exact line that was causing the error
    const verify = fs.readFileSync(filePath, 'utf8');
    const verifyLines = verify.split('\n');
    for (let i = 0; i < verifyLines.length; i++) {
      if (verifyLines[i].includes('gulp.src(dependenciesSrc')) {
        if (verifyLines[i].includes('allowEmpty: true')) {
          console.error(`✓ Verified line ${i + 1} has allowEmpty: true`);
        } else {
          console.error(`✗ ERROR: Line ${i + 1} still missing allowEmpty!`);
          console.error(`Line content: ${verifyLines[i].trim()}`);
          process.exit(1);
        }
        break;
      }
    }
  } else {
    console.error('No changes needed - fixes already applied');
  }
  
} catch (error) {
  console.error(`✗ ERROR applying fix: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
}
NODEFIX
        echo "Node.js fix failed, trying alternative method..." >&2
        # Fallback: Direct sed replacement
        if [[ "$(uname)" == "Darwin" ]]; then
          sed -i '' 's/gulp\.src(dependenciesSrc, { base: '\''remote'\'', dot: true })/gulp.src(dependenciesSrc, { base: '\''remote'\'', dot: true, allowEmpty: true })/g' "build/gulpfile.reh.js" 2>/dev/null
          sed -i '' 's/gulp\.src(extensionPaths, { base: '\''\.build'\'', dot: true })/gulp.src(extensionPaths, { base: '\''.build'\'', dot: true, allowEmpty: true })/g' "build/gulpfile.reh.js" 2>/dev/null
        else
          sed -i 's/gulp\.src(dependenciesSrc, { base: '\''remote'\'', dot: true })/gulp.src(dependenciesSrc, { base: '\''remote'\'', dot: true, allowEmpty: true })/g' "build/gulpfile.reh.js" 2>/dev/null
          sed -i 's/gulp\.src(extensionPaths, { base: '\''\.build'\'', dot: true })/gulp.src(extensionPaths, { base: '\''.build'\'', dot: true, allowEmpty: true })/g' "build/gulpfile.reh.js" 2>/dev/null
        fi
      }
      
      # Final verification
      if grep -q "allowEmpty: true" "build/gulpfile.reh.js" 2>/dev/null; then
        echo "✓ Verification: allowEmpty fix is present in gulpfile.reh.js" >&2
      else
        echo "✗ CRITICAL: Fix verification failed! Showing problematic lines:" >&2
        grep -n "gulp.src(dependenciesSrc\|gulp.src(extensionPaths" "build/gulpfile.reh.js" 2>/dev/null | head -5 >&2 || true
        exit 1
      fi
    else
      echo "ERROR: build/gulpfile.reh.js not found!" >&2
      exit 1
    fi
    
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
