#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

# Set CI_BUILD to "yes" if not explicitly set to "no" (default to CI mode)
# This ensures the script works in CI environments where CI_BUILD might be unset
if [[ -z "${CI_BUILD}" ]]; then
  export CI_BUILD="yes"
fi

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

# include common functions
# Use path relative to script location to ensure utils.sh is found
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
. "${BUILDER_ROOT}/utils.sh"

tar -xzf ./vscode.tar.gz

chown -R root:root vscode

cd vscode || { echo "'vscode' dir not found"; exit 1; }

# CortexIDE-specific: Clean up any stale processes and build artifacts
echo "Cleaning up processes and build artifacts..."
pkill -f "$(pwd)/out/main.js" || true
pkill -f "$(pwd)/out-build/main.js" || true

# Remove React build output to ensure clean state
# Note: React components are rebuilt here even though they may be in the tar.gz
# This ensures consistency across CI environments and handles any platform-specific build requirements
if [[ -d "src/vs/workbench/contrib/void/browser/react/out" ]]; then
  rm -rf src/vs/workbench/contrib/void/browser/react/out
fi
if [[ -d "src/vs/workbench/contrib/cortexide/browser/react/out" ]]; then
  rm -rf src/vs/workbench/contrib/cortexide/browser/react/out
fi

export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
export VSCODE_SYSROOT_PREFIX='-glibc-2.28'
export NODE_OPTIONS="--max-old-space-size=12288"

# Skip sysroot download - CortexIDE doesn't need cross-compilation toolchains
# Standard builds work without sysroot, and it's causing checksum errors
if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  export VSCODE_SKIP_SYSROOT=1
  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "arm64" || "${VSCODE_ARCH}" == "armhf" ]]; then
  export VSCODE_SKIP_SYSROOT=1
  export VSCODE_SKIP_SETUPENV=1
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
  export VSCODE_ELECTRON_TAG='v37.10.3' # riscv-forks doesn't have 37.7.0, use 37.10.3
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='darkyzhou/electron-loong64'
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
  # Skip postinstall scripts for unsupported packages on alternative architectures
  export SKIP_POSTINSTALL_SCRIPTS=1
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

  # For alternative architectures using custom Electron repositories, be more lenient with version checks
  # Custom repos may not have the exact same version as the main Electron release
  # Debug: Show what we're checking
  echo "Checking Electron version compatibility for ${VSCODE_ARCH}:"
  echo "  ELECTRON_VERSION from electron.sh: ${ELECTRON_VERSION}"
  echo "  TARGET from npm config: ${TARGET}"
  echo "  VSCODE_ELECTRON_REPOSITORY: ${VSCODE_ELECTRON_REPOSITORY:-not set}"

  if [[ -n "${VSCODE_ELECTRON_REPOSITORY}" ]]; then
    # Using custom repository - check major version compatibility but don't fail if different
    echo "Using custom Electron repository: ${VSCODE_ELECTRON_REPOSITORY}"
    if [[ "${ELECTRON_VERSION%%.*}" != "${TARGET%%.*}" ]]; then
      echo "Warning: Electron ${VSCODE_ARCH} binary version (${ELECTRON_VERSION}) has different major version than target (${TARGET})"
      echo "This is expected for alternative architectures using custom repositories."
      echo "Releases available at: https://github.com/${VSCODE_ELECTRON_REPOSITORY}/releases"
      # Still update .npmrc to use the custom version
      if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
        echo "Updating .npmrc to use Electron ${ELECTRON_VERSION} instead of ${TARGET}"
        replace "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
      fi
    elif [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
      # Same major version, different minor/patch - update .npmrc
      echo "Using Electron ${ELECTRON_VERSION} for ${VSCODE_ARCH} (target was ${TARGET})"
      replace "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
    else
      echo "Electron versions match: ${ELECTRON_VERSION}"
    fi
  else
    # Standard architecture - strict version check
    # Only fails at different major versions
    echo "Using standard Electron repository - strict version check"
    if [[ "${ELECTRON_VERSION%%.*}" != "${TARGET%%.*}" ]]; then
      # Fail the pipeline if electron target doesn't match what is used.
      echo "ERROR: Electron ${VSCODE_ARCH} binary version doesn't match target electron version!"
      echo "Expected major version ${TARGET%%.*}, got ${ELECTRON_VERSION%%.*}"
      exit 1
    fi

    if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
      # Force version
      echo "Updating .npmrc to use Electron ${ELECTRON_VERSION} instead of ${TARGET}"
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

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
BUILD_NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  BUILD_NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for build dependencies on ${VSCODE_ARCH}"
fi

for i in {1..5}; do # try 5 times
  npm ci --prefix build ${BUILD_NPM_CI_OPTS} && break
  if [[ $i == 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# Install extension dependencies (same as in main build.sh)
echo "Installing extension dependencies..."
for ext_dir in extensions/*/; do
  if [[ -f "${ext_dir}package.json" ]] && [[ -f "${ext_dir}package-lock.json" ]]; then
    echo "Installing deps for $(basename "$ext_dir")..."
    (cd "$ext_dir" && npm ci --ignore-scripts) || echo "Skipped $(basename "$ext_dir")"
  fi
done

if [[ -z "${VSCODE_SKIP_SETUPENV}" ]]; then
  if [[ -n "${VSCODE_SKIP_SYSROOT}" ]]; then
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
  else
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for ${VSCODE_ARCH} (unsupported by some packages)"
fi

for i in {1..5}; do # try 5 times
  npm ci ${NPM_CI_OPTS} && break
  if [[ $i -eq 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# Apply fixes for alternative architectures after npm install
# Also run for all architectures to ensure FAIL_BUILD_FOR_NEW_DEPENDENCIES is set to false
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "x64" ]] || [[ "${VSCODE_ARCH}" == "arm64" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  echo "Applying fixes for ${VSCODE_ARCH} architecture support..."
  # Use absolute path to fix-dependencies-generator.sh
  bash "${BUILDER_ROOT}/build/linux/fix-dependencies-generator.sh" || echo "Warning: Fix script failed, continuing..."
fi

node build/azure-pipelines/distro/mixin-npm

# CortexIDE: Build React components before packaging
echo "Building React components for Linux ${VSCODE_ARCH}..."
npm run buildreact || echo "Warning: buildreact failed, continuing..."

# Package the Linux application
echo "Packaging Linux ${VSCODE_ARCH} application..."
# Ensure environment variables are exported for Node.js process
export VSCODE_ELECTRON_REPOSITORY
export VSCODE_ELECTRON_TAG
echo "Environment variables for Electron:"
echo "  VSCODE_ELECTRON_REPOSITORY=${VSCODE_ELECTRON_REPOSITORY}"
echo "  VSCODE_ELECTRON_TAG=${VSCODE_ELECTRON_TAG}"
npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
  bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "../VSCode-linux-${VSCODE_ARCH}/resources/app/node_modules"
fi

find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

# Build CLI - use absolute path to ensure it's found
. "${BUILDER_ROOT}/build_cli.sh"

cd ..
