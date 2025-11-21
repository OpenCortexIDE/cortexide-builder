#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

# include common functions
. ./utils.sh

mkdir -p assets

tar -xzf ./vscode.tar.gz

cd vscode || { echo "'vscode' dir not found"; exit 1; }

GLIBC_VERSION="2.28"
GLIBCXX_VERSION="3.4.26"
NODE_VERSION="20.18.2"

export VSCODE_NODEJS_URLROOT='/download/release'
export VSCODE_NODEJS_URLSUFFIX=''

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  GLIBC_VERSION="2.17"
  GLIBCXX_VERSION="3.4.22"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-x64"

  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLSUFFIX='-glibc-217'

  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  EXPECTED_GLIBC_VERSION="2.30"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-arm64"

  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  EXPECTED_GLIBC_VERSION="2.30"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-armhf"

  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-ppc64le"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20240129-253798'
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-riscv64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:beige-devtoolset-loong64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
elif [[ "${VSCODE_ARCH}" == "s390x" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-s390x"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20241108'
fi

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
export VSCODE_SYSROOT_PREFIX="-glibc-${GLIBC_VERSION}"

EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION:=GLIBC_VERSION}"
VSCODE_HOST_MOUNT="$( pwd )"

export VSCODE_HOST_MOUNT
export VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME

sed -i "/target/s/\"20.*\"/\"${NODE_VERSION}\"/" remote/.npmrc

if [[ -d "../patches/linux/reh/" ]]; then
  for file in "../patches/linux/reh/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

if [[ -d "../patches/linux/reh/${VSCODE_ARCH}/" ]]; then
  for file in "../patches/linux/reh/${VSCODE_ARCH}/"*.patch; do
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

  if [ ! -d "${HOME}/.gyp" ]; then
    mkdir -p "${HOME}/.gyp"
  fi

  echo "${INCLUDES}" > "${HOME}/.gyp/include.gypi"
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

mv .npmrc .npmrc.bak
cp ../npmrc .npmrc

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
        }
      fi
    fi
    mkdir -p "$PWD/.build/sysroots/glibc-2.28-gcc-10.5.0" "$PWD/.build/sysroots/glibc-2.28-gcc-8.5.0"
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
    unset CC CXX CXXFLAGS LDFLAGS VSCODE_REMOTE_CC VSCODE_REMOTE_CXX VSCODE_REMOTE_CXXFLAGS VSCODE_REMOTE_LDFLAGS
  else
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# CRITICAL FIX: Install with --ignore-scripts to prevent native-keymap postinstall from running
# Then patch native-keymap and manually handle postinstall scripts
for i in {1..5}; do # try 5 times
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

mv .npmrc.bak .npmrc

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

export VSCODE_NODE_GLIBC="-glibc-${GLIBC_VERSION}"

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building REH"
  
  # CRITICAL FIX: Handle empty glob patterns in gulpfile.reh.js (same fix as main build.sh)
  if [[ -f "build/gulpfile.reh.js" ]]; then
    echo "Applying critical fix to gulpfile.reh.js for empty glob patterns..." >&2
    node << 'REHFIX' || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
try {
  let content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  let modified = false;
  
  // Fix 1: dependenciesSrc
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('const dependenciesSrc =') && lines[i].includes('.flat()')) {
      if (!lines[i].includes('|| [\'**\', \'!**/*\']')) {
        let newLine = lines[i].replace(/const dependenciesSrc =/, 'let dependenciesSrc =');
        newLine = newLine.replace(/\.flat\(\);?$/, ".flat() || ['**', '!**/*'];");
        lines[i] = newLine;
        const indent = lines[i].match(/^\s*/)[0];
        lines.splice(i + 1, 0, `${indent}if (dependenciesSrc.length === 0) { dependenciesSrc = ['**', '!**/*']; }`);
        modified = true;
        console.error(`✓ Fixed dependenciesSrc at line ${i + 1}`);
      }
      break;
    }
  }
  
  // Fix 2: extensionPaths
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('const extensionPaths =') && lines[i].includes('.map(name =>')) {
      if (!lines[i].includes('|| [\'**\', \'!**/*\']')) {
        let newLine = lines[i].replace(/const extensionPaths =/, 'let extensionPaths =');
        // Match the pattern: .map(name => `.build/extensions/${name}/**`)
        newLine = newLine.replace(/\.map\(name => `\.build\/extensions\/\$\{name\}\/\*\*`\);?$/, ".map(name => `.build/extensions/${name}/**`) || ['**', '!**/*'];");
        lines[i] = newLine;
        const indent = lines[i].match(/^\s*/)[0];
        lines.splice(i + 1, 0, `${indent}if (extensionPaths.length === 0) { extensionPaths = ['**', '!**/*']; }`);
        modified = true;
        console.error(`✓ Fixed extensionPaths at line ${i + 1}`);
      }
      break;
    }
  }
  
  if (modified) {
    content = lines.join('\n');
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully applied REH glob fix (dependenciesSrc and extensionPaths)');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  process.exit(1);
}
REHFIX
      echo "Warning: Failed to patch gulpfile.reh.js, continuing anyway..." >&2
    }
  fi
  
  # Verify gulp is available before running
  if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
    echo "Error: gulp is not installed. Cannot run REH build." >&2
    echo "This may indicate npm ci failed partially. Check logs above." >&2
    exit 1
  fi
  
  npm run gulp minify-vscode-reh
  
  # Verify REH gulp task exists, especially for alternative architectures
  REH_GULP_TASK="vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  echo "Checking if REH gulp task '${REH_GULP_TASK}' exists..."
  
  # Try to list tasks and check if our task exists
  if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_GULP_TASK}$"; then
    echo "Warning: REH gulp task '${REH_GULP_TASK}' not found. Ensuring architecture is in BUILD_TARGETS..." >&2
    
    # For alternative architectures, ensure they're in BUILD_TARGETS in gulpfile.reh.js
    if [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]]; then
      echo "Ensuring ${VSCODE_ARCH} is in BUILD_TARGETS in gulpfile.reh.js..." >&2
      if [[ -f "build/gulpfile.reh.js" ]]; then
        if ! grep -q "{ platform: 'linux', arch: '${VSCODE_ARCH}' }" "build/gulpfile.reh.js"; then
          echo "Adding ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js..." >&2
          node << ARCHFIX || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
const arch = '${VSCODE_ARCH}';
try {
  let content = fs.readFileSync(filePath, 'utf8');
  
  if (content.includes(\`{ platform: 'linux', arch: '\${arch}' }\`)) {
    console.error(\`✓ \${arch} already in BUILD_TARGETS\`);
    process.exit(0);
  }
  
  // Find the BUILD_TARGETS array and add arch after ppc64le or arm64
  const pattern = /(\{\s*platform:\s*['"]linux['"],\s*arch:\s*['"](?:ppc64le|arm64)['"]\s*\},)/;
  if (pattern.test(content)) {
    content = content.replace(
      pattern,
      \`$1\n\t{ platform: 'linux', arch: '\${arch}' },\`
    );
    fs.writeFileSync(filePath, content, 'utf8');
    console.error(\`✓ Added \${arch} to BUILD_TARGETS in gulpfile.reh.js\`);
  } else {
    console.error('⚠ Could not find entry to add arch after');
    process.exit(1);
  }
} catch (error) {
  console.error('Error:', error.message);
  process.exit(1);
}
ARCHFIX
            echo "Warning: Failed to add ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js, but continuing..." >&2
          } else {
            echo "✓ ${VSCODE_ARCH} already in BUILD_TARGETS" >&2
          }
        fi
      fi
      
      # Re-check if task is now available
      if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_GULP_TASK}$"; then
        echo "Warning: REH gulp task '${REH_GULP_TASK}' still not found after patch attempt." >&2
        echo "Available REH tasks:" >&2
        npm run gulp -- --tasks-simple 2>&1 | grep "vscode-reh" | head -10 >&2 || true
        echo "Attempting to run task anyway..." >&2
      fi
    fi
  fi
  
  npm run gulp "${REH_GULP_TASK}"

  EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

  pushd "../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  if [[ -f "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" ]]; then
    bash "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" "node_modules"
  fi

  echo "Archiving REH"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building REH-web"
  # Verify gulp is available before running
  if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
    echo "Error: gulp is not installed. Cannot run REH-web build." >&2
    echo "This may indicate npm ci failed partially. Check logs above." >&2
    exit 1
  fi
  
  npm run gulp minify-vscode-reh-web
  
  # Verify REH-web gulp task exists, especially for alternative architectures
  REH_WEB_GULP_TASK="vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  echo "Checking if REH-web gulp task '${REH_WEB_GULP_TASK}' exists..."
  
  # Try to list tasks and check if our task exists
  if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_WEB_GULP_TASK}$"; then
    echo "Warning: REH-web gulp task '${REH_WEB_GULP_TASK}' not found. Ensuring architecture is in BUILD_TARGETS..." >&2
    
    # For alternative architectures, ensure they're in BUILD_TARGETS in gulpfile.reh.js
    if [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]]; then
      echo "Ensuring ${VSCODE_ARCH} is in BUILD_TARGETS in gulpfile.reh.js..." >&2
      if [[ -f "build/gulpfile.reh.js" ]]; then
        if ! grep -q "{ platform: 'linux', arch: '${VSCODE_ARCH}' }" "build/gulpfile.reh.js"; then
          echo "Adding ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js..." >&2
          node << ARCHFIX || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
const arch = '${VSCODE_ARCH}';
try {
  let content = fs.readFileSync(filePath, 'utf8');
  
  if (content.includes(\`{ platform: 'linux', arch: '\${arch}' }\`)) {
    console.error(\`✓ \${arch} already in BUILD_TARGETS\`);
    process.exit(0);
  }
  
  // Find the BUILD_TARGETS array and add arch after ppc64le or arm64
  const pattern = /(\{\s*platform:\s*['"]linux['"],\s*arch:\s*['"](?:ppc64le|arm64)['"]\s*\},)/;
  if (pattern.test(content)) {
    content = content.replace(
      pattern,
      \`$1\n\t{ platform: 'linux', arch: '\${arch}' },\`
    );
    fs.writeFileSync(filePath, content, 'utf8');
    console.error(\`✓ Added \${arch} to BUILD_TARGETS in gulpfile.reh.js\`);
  } else {
    console.error('⚠ Could not find entry to add arch after');
    process.exit(1);
  }
} catch (error) {
  console.error('Error:', error.message);
  process.exit(1);
}
ARCHFIX
            echo "Warning: Failed to add ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js, but continuing..." >&2
          } else {
            echo "✓ ${VSCODE_ARCH} already in BUILD_TARGETS" >&2
          }
        fi
      fi
      
      # Re-check if task is now available
      if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_WEB_GULP_TASK}$"; then
        echo "Warning: REH-web gulp task '${REH_WEB_GULP_TASK}' still not found after patch attempt." >&2
        echo "Available REH-web tasks:" >&2
        npm run gulp -- --tasks-simple 2>&1 | grep "vscode-reh-web" | head -10 >&2 || true
        echo "Attempting to run task anyway..." >&2
      fi
    fi
  fi
  
  npm run gulp "${REH_WEB_GULP_TASK}"

  EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

  pushd "../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  if [[ -f "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" ]]; then
    bash "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" "node_modules"
  fi

  echo "Archiving REH-web"
  tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

cd ..

npm install -g checksum

sum_file() {
  if [[ -f "${1}" ]]; then
    echo "Calculating checksum for ${1}"
    checksum -a sha256 "${1}" > "${1}".sha256
    checksum "${1}" > "${1}".sha1
  fi
}

cd assets

for FILE in *; do
  if [[ -f "${FILE}" ]]; then
    sum_file "${FILE}"
  fi
done

cd ..
