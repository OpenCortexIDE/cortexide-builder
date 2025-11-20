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
  if [[ -f "${postinstall_path}" ]]; then
    # Check if already patched by looking for a marker
    if ! grep -q "// PATCHED: Skip native-keymap rebuild" "${postinstall_path}" 2>/dev/null; then
      echo "Patching native-keymap to skip node-gyp rebuild at ${postinstall_path}..." >&2
      node << NATIVEKEYMAPFIX || {
const fs = require('fs');
const filePath = '${postinstall_path}';
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
} else {
  console.error('No postinstall script found in native-keymap');
}
NATIVEKEYMAPFIX
        echo "Warning: Failed to patch native-keymap postinstall, trying alternative method..." >&2
        # Alternative: patch the actual postinstall script if it exists
        local script_dir=$(dirname "${postinstall_path}")
        local script_path="${script_dir}/scripts/postinstall.js"
        if [[ -f "${script_path}" ]]; then
          echo "exit 0" > "${script_path}" || true
          echo "✓ Patched native-keymap postinstall script directly" >&2
        fi
      }
    else
      echo "native-keymap already patched at ${postinstall_path}" >&2
    fi
  fi
}

for i in {1..5}; do # try 5 times
  # Fix vsce-sign postinstall before attempting install (in case it exists from previous attempt)
  fix_vsce_sign_postinstall
  
  npm ci --prefix build 2>&1 | tee /tmp/npm-install.log || {
    # Check if it failed due to vsce-sign postinstall
    if grep -q "vsce-sign.*postinstall\|The current platform.*is not supported" /tmp/npm-install.log; then
      echo "npm install failed due to vsce-sign postinstall issue, fixing and retrying..." >&2
      fix_vsce_sign_postinstall
      # Remove vsce-sign to force reinstall
      rm -rf build/node_modules/@vscode/vsce-sign
      # Continue to retry
      continue
    fi
    # Check if it failed due to native-keymap node-gyp rebuild
    if grep -q "native-keymap.*node-gyp\|native-keymap.*rebuild\|keymapping.*error\|v8-object.h.*error\|v8-template.h.*error" /tmp/npm-install.log; then
      echo "npm install failed due to native-keymap rebuild issue, fixing and retrying..." >&2
      # Patch native-keymap in build/node_modules
      fix_native_keymap_postinstall "build/node_modules/native-keymap/package.json"
      # Remove native-keymap to force reinstall
      rm -rf build/node_modules/native-keymap
      # Continue to retry
      continue
    fi
    # Other errors, break and retry normally
    false
  } && break
  
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
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

for i in {1..5}; do # try 5 times
  # Fix vsce-sign postinstall before attempting install (in case it exists from previous attempt)
  fix_vsce_sign_postinstall
  # Fix native-keymap postinstall before attempting install (if it exists from previous attempt)
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
  
  npm ci 2>&1 | tee /tmp/npm-install-root.log || {
    # Check if it failed due to vsce-sign postinstall
    if grep -q "vsce-sign.*postinstall\|The current platform.*is not supported" /tmp/npm-install-root.log; then
      echo "npm install failed due to vsce-sign postinstall issue, fixing and retrying..." >&2
      fix_vsce_sign_postinstall
      # Remove vsce-sign to force reinstall
      rm -rf node_modules/@vscode/vsce-sign
      # Continue to retry
      continue
    fi
    # Check if it failed due to native-keymap node-gyp rebuild
    if grep -q "native-keymap.*node-gyp\|native-keymap.*rebuild\|keymapping.*error\|v8-object.h.*error\|v8-template.h.*error" /tmp/npm-install-root.log; then
      echo "npm install failed due to native-keymap rebuild issue, fixing and retrying..." >&2
      # Patch native-keymap if it was installed before failing
      fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
      # Remove native-keymap to force reinstall with patched package.json
      rm -rf node_modules/native-keymap
      # Continue to retry
      continue
    fi
    # Other errors, break and retry normally
    false
  } && break
  
  if [[ $i -eq 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

# CRITICAL FIX: Verify gulp is installed before running gulp commands
# If npm ci failed partially, gulp might not be installed
if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
  echo "Warning: gulp not found after mixin-npm, attempting to install..." >&2
  npm install gulp 2>&1 | tail -20 || {
    echo "Error: Failed to install gulp. Cannot continue with build." >&2
    exit 1
  }
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

npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
  bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "../VSCode-linux-${VSCODE_ARCH}/resources/app/node_modules"
fi

find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

. ../build_cli.sh

cd ..
