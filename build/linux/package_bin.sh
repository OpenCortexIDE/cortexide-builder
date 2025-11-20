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

  if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
    # Force version
    replace "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
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

for i in {1..5}; do # try 5 times
  npm ci --prefix build && break
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
  npm ci && break
  if [[ $i -eq 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
  bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "../VSCode-linux-${VSCODE_ARCH}/resources/app/node_modules"
fi

find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

. ../build_cli.sh

cd ..
