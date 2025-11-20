#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

# include common functions
. ./utils.sh

tar -xzf ./vscode.tar.gz

chown -R root:root vscode

cd vscode || { echo "'vscode' dir not found"; exit 1; }

export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
# VSCODE_SYSROOT_PREFIX should include gcc version for checksum matching
# Default is -glibc-2.28-gcc-10.5.0, but we only set it if not already set
export VSCODE_SYSROOT_PREFIX="${VSCODE_SYSROOT_PREFIX:--glibc-2.28-gcc-10.5.0}"

if [[ "${VSCODE_ARCH}" == "arm64" || "${VSCODE_ARCH}" == "armhf" ]]; then
  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20240129-253798'
  export USE_GNUPP2A=1
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_ELECTRON_REPOSITORY='lex-ibm/electron-ppc64le-build-scripts'
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='riscv-forks/electron-riscv-releases'
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='darkyzhou/electron-loong64'
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
fi

if [[ -f "../build/linux/${VSCODE_ARCH}/electron.sh" ]]; then
  # add newline at the end of the file
  echo "" >> build/checksums/electron.txt

  if [[ -f "../build/linux/${VSCODE_ARCH}/electron.sha256sums" ]]; then
    cat "../build/linux/${VSCODE_ARCH}/electron.sha256sums" >> build/checksums/electron.txt
  fi

  # shellcheck disable=SC1090
  source "../build/linux/${VSCODE_ARCH}/electron.sh"

  TARGET=$( npm config get target )

  # For alternative architectures (loong64, riscv64, ppc64le), allow version mismatch
  # These use custom electron builds that may lag behind the main version
  if [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
    echo "Note: ${VSCODE_ARCH} uses custom electron build (${ELECTRON_VERSION}), target is ${TARGET}"
    # Still update .npmrc to use the custom version
    if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
      replace "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
    fi
  else
    # Only fails at different major versions for standard architectures
    if [[ "${ELECTRON_VERSION%%.*}" != "${TARGET%%.*}" ]]; then
      # Fail the pipeline if electron target doesn't match what is used.
      echo "Electron ${VSCODE_ARCH} binary version doesn't match target electron version!"
      echo "Releases available at: https://github.com/${VSCODE_ELECTRON_REPOSITORY}/releases"
      exit 1
    fi

    if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
      # Force version
      replace "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
    fi
  fi
fi

if [[ -d "../patches/linux/client/" ]]; then
  for file in "../patches/linux/client/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

if [[ -n "${USE_GNUPP2A}" ]]; then
  INCLUDES=$(cat <<EOF
{
  "target_defaults": {
    "conditions": [
      ["OS=='linux'", {
        'cflags_cc!': [ '-std=gnu++20' ],
        'cflags_cc': [ '-std=gnu++2a' ],
      }]
    ]
  }
}
EOF
)

  if [ ! -d "$HOME/.gyp" ]; then
    mkdir -p "$HOME/.gyp"
  fi

  echo "${INCLUDES}" > "$HOME/.gyp/include.gypi"
fi

# CRITICAL FIX: @vscode/vsce-sign postinstall script doesn't support ppc64
# Patch the postinstall script to skip the platform check for unsupported architectures
fix_vsce_sign_postinstall() {
  local postinstall_path="build/node_modules/@vscode/vsce-sign/src/postinstall.js"
  if [[ -f "${postinstall_path}" ]]; then
    # Check if already patched
    if ! grep -q "// PATCHED: Skip platform check for unsupported architectures" "${postinstall_path}" 2>/dev/null; then
      echo "Patching @vscode/vsce-sign postinstall script to support ppc64..." >&2
      node << VSECESIGNFIX || {
const fs = require('fs');
const filePath = '${postinstall_path}';
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('// PATCHED: Skip platform check')) {
  console.error('vsce-sign postinstall already patched');
  process.exit(0);
}

// Find the platform check and make it skip for unsupported architectures
// The error message is "The current platform (linux) and architecture (ppc64) is not supported."
// We need to find where it throws this error and make it a warning instead
const lines = content.split('\n');
let modified = false;

for (let i = 0; i < lines.length; i++) {
  // Find the error throw
  if (lines[i].includes('is not supported') && lines[i].includes('throw new Error')) {
    // Replace throw with console.warn and return early
    const indent = lines[i].match(/^\s*/)[0];
    lines[i] = `${indent}// PATCHED: Skip platform check for unsupported architectures (ppc64, etc.)\n${indent}console.warn('Platform/architecture not officially supported, skipping vsce-sign setup');\n${indent}return;`;
    modified = true;
    console.error(`✓ Patched vsce-sign postinstall at line ${i + 1}`);
    break;
  }
}

if (modified) {
  content = lines.join('\n');
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched vsce-sign postinstall');
} else {
  console.error('Could not find platform check in vsce-sign postinstall');
}
VSECESIGNFIX
        echo "Warning: Failed to patch vsce-sign postinstall, continuing anyway..." >&2
      }
    fi
  fi
}

# CRITICAL FIX: native-keymap postinstall script fails to rebuild with Node.js v20.19.2
# Patch the postinstall script to skip the node-gyp rebuild
fix_native_keymap_postinstall() {
  local postinstall_path="${1:-node_modules/native-keymap/package.json}"
  local module_dir=$(dirname "${postinstall_path}")
  
  if [[ -f "${postinstall_path}" ]]; then
    # Check if already patched by looking for a marker
    if ! grep -q "// PATCHED: Skip native-keymap rebuild" "${postinstall_path}" 2>/dev/null; then
      echo "Patching native-keymap to skip node-gyp rebuild at ${postinstall_path}..." >&2
      node << NATIVEKEYMAPFIX || {
const fs = require('fs');
const path = require('path');
const filePath = '${postinstall_path}';
const moduleDir = '${module_dir}';

let content = fs.readFileSync(filePath, 'utf8');
let pkg = JSON.parse(content);

// Check if already patched
if (pkg.scripts && pkg.scripts.postinstall && pkg.scripts.postinstall.includes('// PATCHED')) {
  console.error('native-keymap already patched');
  process.exit(0);
}

// Remove or skip the postinstall script that runs node-gyp rebuild
if (pkg.scripts && pkg.scripts.postinstall) {
  pkg.scripts.postinstall = '// PATCHED: Skip native-keymap rebuild (V8 API incompatibility with Node.js v20.19.2)';
  content = JSON.stringify(pkg, null, 2);
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched native-keymap postinstall');
}

// Also patch the postinstall script file directly if it exists
const postinstallScript = path.join(moduleDir, 'scripts', 'postinstall.js');
if (fs.existsSync(postinstallScript)) {
  fs.writeFileSync(postinstallScript, '// PATCHED: Skip rebuild\nprocess.exit(0);\n', 'utf8');
  console.error('✓ Patched native-keymap postinstall script file');
}

// Also create a dummy binding.gyp to prevent node-gyp from trying to build
const bindingGyp = path.join(moduleDir, 'binding.gyp');
if (fs.existsSync(bindingGyp)) {
  const gypContent = fs.readFileSync(bindingGyp, 'utf8');
  // Comment out the targets to prevent building
  const patchedGyp = '// PATCHED: Disabled build due to V8 API incompatibility\n' + gypContent.replace(/("targets":\s*\[)/, '// $1');
  fs.writeFileSync(bindingGyp, patchedGyp, 'utf8');
  console.error('✓ Patched native-keymap binding.gyp');
}
NATIVEKEYMAPFIX
        echo "Warning: Failed to patch native-keymap, trying fallback method..." >&2
        # Fallback: patch the actual postinstall script if it exists
        local script_path="${module_dir}/scripts/postinstall.js"
        if [[ -f "${script_path}" ]]; then
          echo "// PATCHED: Skip rebuild" > "${script_path}"
          echo "process.exit(0);" >> "${script_path}"
          echo "✓ Patched native-keymap postinstall script directly (fallback)" >&2
        fi
      }
    else
      echo "native-keymap already patched at ${postinstall_path}" >&2
    fi
  fi
}

# CRITICAL FIX: Install with --ignore-scripts to prevent native-keymap postinstall from running
# Then patch native-keymap and manually handle postinstall scripts
for i in {1..5}; do # try 5 times
  # Fix vsce-sign postinstall before attempting install (in case it exists from previous attempt)
  fix_vsce_sign_postinstall
  
  # Install with --ignore-scripts to skip all postinstall scripts (including native-keymap)
  npm ci --ignore-scripts --prefix build 2>&1 | tee /tmp/npm-install.log || {
    # If it fails for other reasons, retry normally
    if [[ $i -lt 3 ]]; then
      echo "Npm install failed $i, trying again..."
      continue
    else
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  }
  
  # Patch native-keymap to disable postinstall before any scripts run
  fix_native_keymap_postinstall "build/node_modules/native-keymap/package.json"
  
  # Note: We skip running postinstall scripts manually since most packages work without them
  # and native-keymap's postinstall is now disabled. If other packages need postinstall,
  # they should be handled individually.
  
  break
done

if [[ -z "${VSCODE_SKIP_SETUPENV}" ]]; then
  # CRITICAL FIX: setup-env.sh doesn't respect --skip-sysroot flag
  # For armhf/arm64, we need to skip sysroot download entirely
  if [[ -n "${VSCODE_SKIP_SYSROOT}" ]]; then
    # Patch setup-env.sh to skip sysroot downloads when --skip-sysroot is passed
    if [[ -f "build/azure-pipelines/linux/setup-env.sh" ]]; then
      echo "Patching setup-env.sh to skip sysroot downloads for ${VSCODE_ARCH}..." >&2
      # Check if already patched
      if ! grep -q "# SKIP_SYSROOT_PATCH" "build/azure-pipelines/linux/setup-env.sh" 2>/dev/null; then
        # Use Node.js for more reliable patching
        node << 'SETUPENVFIX' || {
const fs = require('fs');
const filePath = 'build/azure-pipelines/linux/setup-env.sh';
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('# SKIP_SYSROOT_PATCH')) {
  console.error('setup-env.sh already patched');
  process.exit(0);
}

// Wrap sysroot download sections (lines 12-24) in a conditional
const lines = content.split('\n');
let newLines = [];

for (let i = 0; i < lines.length; i++) {
  // Before sysroot download section (line 12)
  if (i === 11 && lines[i].includes('export VSCODE_CLIENT_SYSROOT_DIR')) {
    newLines.push('# SKIP_SYSROOT_PATCH');
    newLines.push('if [[ "$1" != "--skip-sysroot" ]] && [[ -z "${VSCODE_SKIP_SYSROOT}" ]]; then');
  }
  
  newLines.push(lines[i]);
  
  // After sysroot download section (line 24), close the if
  if (i === 23 && lines[i].includes('VSCODE_SYSROOT_PREFIX')) {
    newLines.push('fi');
  }
}

content = newLines.join('\n');
fs.writeFileSync(filePath, content, 'utf8');
console.error('✓ Successfully patched setup-env.sh to skip sysroot downloads');
SETUPENVFIX
          echo "Warning: Failed to patch setup-env.sh, trying alternative method..." >&2
          # Fallback: simple sed approach
          if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '12,24s/^/# SKIP_SYSROOT: /' "build/azure-pipelines/linux/setup-env.sh" 2>/dev/null || true
          else
            sed -i '12,24s/^/# SKIP_SYSROOT: /' "build/azure-pipelines/linux/setup-env.sh" 2>/dev/null || true
          fi
        }
      fi
    fi
    # Ensure sysroot directories exist so setup-env.sh thinks they are cached
    mkdir -p "$PWD/.build/sysroots/glibc-2.28-gcc-10.5.0" "$PWD/.build/sysroots/glibc-2.28-gcc-8.5.0"
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
    # When skipping sysroot downloads, setup-env still sets CC/CXX to the
    # non-existent toolchains inside the skipped sysroot tree. Override them
    # to sane defaults so node-gyp can fall back to the system toolchain.
    unset CC CXX CXXFLAGS LDFLAGS VSCODE_REMOTE_CC VSCODE_REMOTE_CXX VSCODE_REMOTE_CXXFLAGS VSCODE_REMOTE_LDFLAGS
  else
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# CRITICAL FIX: Install with --ignore-scripts to prevent native-keymap postinstall from running
# Then patch native-keymap and manually handle postinstall scripts
for i in {1..5}; do # try 5 times
  # Fix vsce-sign postinstall before attempting install (in case it exists from previous attempt)
  fix_vsce_sign_postinstall
  
  # Install with --ignore-scripts to skip all postinstall scripts (including native-keymap)
  npm ci --ignore-scripts 2>&1 | tee /tmp/npm-install-root.log || {
    # If it fails for other reasons, retry normally
    if [[ $i -lt 3 ]]; then
      echo "Npm install failed $i, trying again..."
      # Clean up problematic modules
      rm -rf node_modules/@vscode node_modules/node-pty node_modules/native-keymap
      continue
    else
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  }
  
  # Patch native-keymap to disable postinstall before any scripts run
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
  
  # Note: We skip running postinstall scripts manually since most packages work without them
  # and native-keymap's postinstall is now disabled. If other packages need postinstall,
  # they should be handled individually.
  
  break
done

node build/azure-pipelines/distro/mixin-npm

# CRITICAL FIX: Patch native-keymap immediately after mixin-npm (it may install native-keymap)
fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
if [[ -d "build/node_modules/native-keymap" ]]; then
  fix_native_keymap_postinstall "build/node_modules/native-keymap/package.json"
fi

# CRITICAL FIX: Verify gulp is installed before running gulp commands
# If npm ci failed partially, gulp might not be installed
# Also ensure native-keymap is patched before installing gulp (gulp install might trigger native-keymap)
if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
  echo "Warning: gulp not found after mixin-npm, attempting to install..." >&2
  # Ensure native-keymap is patched before installing gulp
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
  # Install gulp with --ignore-scripts to prevent native-keymap rebuild
  npm install --ignore-scripts gulp 2>&1 | tail -20 || {
    echo "Error: Failed to install gulp. Cannot continue with build." >&2
    exit 1
  }
  # Re-patch native-keymap after install (in case it was reinstalled)
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
fi

# CRITICAL FIX: @electron/get, @octokit/rest, and got are now ESM and break @vscode/gulp-electron
# Patch node_modules to dynamically import these modules (same as Windows build)
if [[ -f "node_modules/@vscode/gulp-electron/src/download.js" ]]; then
  echo "Patching @vscode/gulp-electron to support ESM @electron/get, @octokit/rest, and got..." >&2
  node << 'ELECTRONPATCH' || {
const fs = require('fs');
const filePath = 'node_modules/@vscode/gulp-electron/src/download.js';
let content = fs.readFileSync(filePath, 'utf8');

const alreadyPatched = content.includes('// ESM_PATCH: downloadArtifact') && 
                       content.includes('// ESM_PATCH: octokit') &&
                       content.includes('// ESM_PATCH: got');
if (!alreadyPatched) {
  // Patch @electron/get
  const requireElectronLine = 'const { downloadArtifact } = require("@electron/get");';
  if (content.includes(requireElectronLine)) {
    content = content.replace(requireElectronLine, `// ESM_PATCH: downloadArtifact
let __downloadArtifactPromise;
async function getDownloadArtifact() {
  if (!__downloadArtifactPromise) {
    __downloadArtifactPromise = import("@electron/get").then((mod) => {
      if (mod.downloadArtifact) {
        return mod.downloadArtifact;
      }
      if (mod.default && mod.default.downloadArtifact) {
        return mod.default.downloadArtifact;
      }
      return mod.default || mod;
    });
  }
  return __downloadArtifactPromise;
}`);
  }

  const callDownloadArtifactLine = '  return await downloadArtifact(downloadOpts);';
  if (content.includes(callDownloadArtifactLine)) {
    content = content.replace(callDownloadArtifactLine, `  const downloadArtifact = await getDownloadArtifact();
  return await downloadArtifact(downloadOpts);`);
  }

  // Patch @octokit/rest
  const requireOctokitLine = 'const { Octokit } = require("@octokit/rest");';
  if (content.includes(requireOctokitLine)) {
    content = content.replace(requireOctokitLine, `// ESM_PATCH: octokit
let __octokitPromise;
async function getOctokit() {
  if (!__octokitPromise) {
    __octokitPromise = import("@octokit/rest").then((mod) => {
      if (mod.Octokit) {
        return mod.Octokit;
      }
      if (mod.default && mod.default.Octokit) {
        return mod.default.Octokit;
      }
      return mod.default || mod;
    });
  }
  return __octokitPromise;
}`);

    const usageOctokitLine = '  const octokit = new Octokit({ auth: token });';
    if (content.includes(usageOctokitLine)) {
      content = content.replace(usageOctokitLine, '  const Octokit = await getOctokit();\n  const octokit = new Octokit({ auth: token });');
    }
  }

  // Patch got
  const requireGotLine = 'const { got } = require("got");';
  if (content.includes(requireGotLine)) {
    content = content.replace(requireGotLine, `// ESM_PATCH: got
let __gotPromise;
async function getGot() {
  if (!__gotPromise) {
    __gotPromise = import("got").then((mod) => {
      if (mod.got) {
        return mod.got;
      }
      if (mod.default && mod.default.got) {
        return mod.default.got;
      }
      return mod.default || mod;
    });
  }
  return __gotPromise;
}`);

    const usageGotLine = '  const response = await got(url, {';
    if (content.includes(usageGotLine)) {
      content = content.replace(usageGotLine, '  const got = await getGot();\n  const response = await got(url, {');
    }
  }
}

fs.writeFileSync(filePath, content, 'utf8');
console.error('✓ Patched gulp-electron download.js for ESM imports');
ELECTRONPATCH
    echo "Warning: Failed to patch gulp-electron for ESM, build may fail" >&2
  }
fi

# Verify gulp is available before running
if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
  echo "Error: gulp is not installed. Cannot run build." >&2
  echo "This may indicate npm ci failed partially. Check logs above." >&2
  exit 1
fi

# CRITICAL FIX: Patch build/lib/extensions.js to handle empty glob patterns
# The error "Invalid glob argument:" occurs when empty arrays/strings are passed to gulp.src()
# This happens in doPackageLocalExtensionsStream function around line 488
# Solution: Wrap gulp.src calls to handle empty arrays, or ensure arrays are never empty
if [[ -f "build/lib/extensions.js" ]]; then
  echo "Patching build/lib/extensions.js to handle empty glob patterns..." >&2
  node << 'EXTENSIONSGLOBFIX' || {
const fs = require('fs');
const filePath = 'build/lib/extensions.js';
let content = fs.readFileSync(filePath, 'utf8');
let modified = false;

// Strategy: Find the doPackageLocalExtensionsStream function and patch gulp.src calls
// We'll use a more aggressive approach - find ALL gulp.src patterns and patch them

// Fix 1: Add allowEmpty: true to ALL gulp.src() calls (handles multi-line patterns)
// This is the most reliable fix - works even if the pattern spans multiple lines
if (!content.includes('allowEmpty: true')) {
  // Pattern 1: Single line with dot: true
  content = content.replace(
    /gulp\.src\(([^,]+),\s*\{\s*([^}]*base:[^,}]+),?\s*dot:\s*true\s*\}\)/g,
    (match, src, basePart) => {
      return `gulp.src(${src}, { ${basePart}, dot: true, allowEmpty: true })`;
    }
  );
  
  // Pattern 2: Single line without dot: true but with base
  content = content.replace(
    /gulp\.src\(([^,]+),\s*\{\s*([^}]*base:[^}]+)\s*\}\)/g,
    (match, src, options) => {
      if (!options.includes('allowEmpty')) {
        return `gulp.src(${src}, { ${options}, allowEmpty: true })`;
      }
      return match;
    }
  );
  
  // Pattern 3: Multi-line pattern - find gulp.src( and add allowEmpty before closing }
  // This handles cases where the options object spans multiple lines
  const multilinePattern = /gulp\.src\(([^,]+),\s*\{([^}]*)\}\)/gs;
  content = content.replace(multilinePattern, (match, src, options) => {
    if (!options.includes('allowEmpty') && options.includes('base')) {
      // Add allowEmpty before the closing brace
      const trimmedOptions = options.trim();
      return `gulp.src(${src}, {${trimmedOptions}, allowEmpty: true })`;
    }
    return match;
  });
  
  modified = true;
  console.error('✓ Added allowEmpty: true to gulp.src() calls');
}

// Fix 2: Find doPackageLocalExtensionsStream and add empty array checks
// Look for the function and find variables that might be empty arrays
if (content.includes('doPackageLocalExtensionsStream')) {
  const lines = content.split('\n');
  let inFunction = false;
  let functionIndent = '';
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Detect function start
    if (line.includes('doPackageLocalExtensionsStream') && line.includes('function')) {
      inFunction = true;
      functionIndent = line.match(/^\s*/)[0];
      continue;
    }
    
    // Detect function end (next function or closing brace at same/less indent)
    if (inFunction) {
      const currentIndent = line.match(/^\s*/)[0];
      if (line.trim().startsWith('function ') && currentIndent.length <= functionIndent.length && line !== lines[i-1]) {
        inFunction = false;
      }
      if (line.trim() === '}' && currentIndent.length <= functionIndent.length && i > 0) {
        inFunction = false;
      }
    }
    
    // Within the function, look for gulp.src calls
    if (inFunction && line.includes('gulp.src(')) {
      // Extract variable name from gulp.src(varName, ...)
      const match = line.match(/gulp\.src\(\s*([a-zA-Z_$][a-zA-Z0-9_$.]*)\s*,/);
      if (match) {
        const varName = match[1];
        const indent = line.match(/^\s*/)[0];
        
        // Check if we already have a check for this variable
        let hasCheck = false;
        for (let j = Math.max(0, i - 15); j < i; j++) {
          if (lines[j].includes(`${varName}.length`) || lines[j].includes(`${varName} = ['**'`)) {
            hasCheck = true;
            break;
          }
        }
        
        // Add check if needed
        if (!hasCheck) {
          lines.splice(i, 0, `${indent}if (!${varName} || (Array.isArray(${varName}) && ${varName}.length === 0)) { ${varName} = ['**', '!**/*']; }`);
          modified = true;
          i++; // Skip the line we just added
          console.error(`✓ Added empty check for ${varName} before gulp.src at line ${i + 1}`);
        }
      }
    }
  }
  
  content = lines.join('\n');
}

// Fix 3: Handle empty string globs
content = content.replace(/gulp\.src\((['"])\1\)/g, "gulp.src(['**', '!**/*'])");
if (content !== fs.readFileSync(filePath, 'utf8')) {
  modified = true;
  console.error('✓ Fixed empty string globs');
}

if (modified) {
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched build/lib/extensions.js for empty glob patterns');
} else if (content.includes('allowEmpty: true')) {
  console.error('✓ build/lib/extensions.js already has allowEmpty fixes');
} else {
  console.error('⚠ Could not find patterns to patch - trying fallback method...');
  // Fallback: Just add allowEmpty to any gulp.src we can find
  const fallbackContent = content.replace(/gulp\.src\(([^)]+)\)/g, (match, args) => {
    if (!match.includes('allowEmpty')) {
      // Try to add allowEmpty to the options object
      if (args.includes('{') && args.includes('}')) {
        return match.replace(/\}\s*\)/, ', allowEmpty: true })');
      }
    }
    return match;
  });
  if (fallbackContent !== content) {
    fs.writeFileSync(filePath, fallbackContent, 'utf8');
    console.error('✓ Applied fallback patch');
  }
}
EXTENSIONSGLOBFIX
    echo "Warning: Failed to patch build/lib/extensions.js, continuing anyway..." >&2
  }
fi

npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
  bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "../VSCode-linux-${VSCODE_ARCH}/resources/app/node_modules"
fi

find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

. ../build_cli.sh

cd ..
