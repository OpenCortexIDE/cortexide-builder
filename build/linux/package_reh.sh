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

mkdir -p assets

tar -xzf ./vscode.tar.gz

cd vscode || { echo "'vscode' dir not found"; exit 1; }

GLIBC_VERSION="2.28"
GLIBCXX_VERSION="3.4.26"
NODE_VERSION="20.18.2"

# Default Node.js URL configuration (can be overridden per architecture)
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
  export VSCODE_SKIP_SETUPENV=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  EXPECTED_GLIBC_VERSION="2.30"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-armhf"

  export VSCODE_SKIP_SYSROOT=1
  export VSCODE_SKIP_SETUPENV=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-ppc64le"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20240129-253798'
  export USE_GNUPP2A=1
  export VSCODE_SKIP_SYSROOT=1
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-riscv64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLROOT='/download/release'
  export VSCODE_NODEJS_URLSUFFIX=''
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:beige-devtoolset-loong64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLROOT='/download/release'
  export VSCODE_NODEJS_URLSUFFIX=''
elif [[ "${VSCODE_ARCH}" == "s390x" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-s390x"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20241108'
  export VSCODE_SKIP_SYSROOT=1
fi

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
# Don't override VSCODE_SYSROOT_PREFIX - let setup-env.sh use the correct defaults

# Ensure Node.js environment variables are exported for gulp tasks
# These are needed for alternative architectures (riscv64, loong64) that use unofficial-builds.nodejs.org
export VSCODE_NODEJS_SITE="${VSCODE_NODEJS_SITE:-}"
export VSCODE_NODEJS_URLROOT="${VSCODE_NODEJS_URLROOT:-/download/release}"
export VSCODE_NODEJS_URLSUFFIX="${VSCODE_NODEJS_URLSUFFIX:-}"

EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION:=GLIBC_VERSION}"
VSCODE_HOST_MOUNT="$( pwd )"

export VSCODE_HOST_MOUNT
export VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME

sed -i "/target/s/\"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\"/\"${NODE_VERSION}\"/" remote/.npmrc

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

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
# Also skip for ARM architectures when sysroot is skipped (cross-compilation not available)
BUILD_NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "ppc64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]] || [[ "${VSCODE_ARCH}" == "arm64" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  BUILD_NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for build dependencies on ${VSCODE_ARCH}"
fi

mv .npmrc .npmrc.bak
cp ../npmrc .npmrc

for i in {1..5}; do # try 5 times
  npm ci --prefix build ${BUILD_NPM_CI_OPTS} && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

if [[ -z "${VSCODE_SKIP_SETUPENV}" ]]; then
  if [[ -n "${VSCODE_SKIP_SYSROOT}" ]]; then
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
  else
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# For ARM32 (armhf), verify Node.js binary is valid before proceeding
# The Docker container may have a corrupted or wrong-architecture Node.js binary
if [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  echo "Verifying Node.js binary for ARM32..."
  if command -v node >/dev/null 2>&1; then
    # Try to run node --version to verify the binary works
    if ! node --version >/dev/null 2>&1; then
      echo "ERROR: Node.js binary is corrupted or wrong architecture for ARM32"
      echo "Attempting to use system Node.js or download correct binary..."
      # Remove corrupted binary from PATH if it exists in .build directory
      if [[ -n "${PATH}" ]] && echo "${PATH}" | grep -q "nodejs-musl"; then
        echo "Warning: PATH contains nodejs-musl, which may be incompatible with ARM32"
        # Try to find a working Node.js binary
        if command -v /usr/bin/node >/dev/null 2>&1; then
          export PATH="/usr/bin:${PATH}"
          echo "Using /usr/bin/node instead"
        fi
      fi
    else
      echo "✓ Node.js binary verified: $(node --version)"
    fi
  else
    echo "WARNING: Node.js not found in PATH"
  fi
fi

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
# s390x needs this because native modules like @parcel/watcher try to build with s390x-specific
# compiler flags on x64 hosts, which fails. Skipping scripts allows the build to continue.
# ARM32 (armhf) also needs this to avoid Node.js binary compatibility issues in Docker containers.
NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "ppc64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for ${VSCODE_ARCH} (unsupported by some packages or cross-compilation issues)"
fi

for i in {1..5}; do # try 5 times
  npm ci ${NPM_CI_OPTS} && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# Install extension dependencies (required for TypeScript compilation)
echo "Installing extension dependencies..."
for ext_dir in extensions/*/; do
  if [[ -f "${ext_dir}package.json" ]] && [[ -f "${ext_dir}package-lock.json" ]]; then
    ext_name=$(basename "$ext_dir")
    echo "Installing deps for ${ext_name}..."
    if (cd "$ext_dir" && npm ci --ignore-scripts); then
      echo "✓ Successfully installed dependencies for ${ext_name}"
    else
      echo "⚠ Warning: Failed to install dependencies for ${ext_name}, continuing..."
    fi
  fi
done

mv .npmrc.bak .npmrc

node build/azure-pipelines/distro/mixin-npm

export VSCODE_NODE_GLIBC="-glibc-${GLIBC_VERSION}"

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building REH"
  # Compile extensions before minifying (extensions need their dependencies installed)
  echo "Compiling extensions for REH..."
  npm run gulp compile-extensions-build || echo "Warning: Extension compilation failed, continuing..."
  npm run gulp minify-vscode-reh

  # Fix fetch.js import issues that prevent REH builds
  if [[ -f "build/lib/fetch.js" ]]; then
    echo "Applying direct fix to fetch.js for REH compatibility..."
    node -e "
      const fs = require('fs');
      const path = './build/lib/fetch.js';
      let content = fs.readFileSync(path, 'utf8');
      content = content.replace(
        /return event_stream_1\.default\.readArray\(urls\)\.pipe\(event_stream_1\.default\.map\(/g,
        '// Use a classic CommonJS require for \`event-stream\` to avoid cases where the\n    // transpiled default import does not expose \`readArray\` in some environments.\n    // This mirrors how other build scripts (e.g. \`gulpfile.reh.js\`) consume it.\n    const es = require(\"event-stream\");\n    return es.readArray(urls).pipe(es.map('
      );
      content = content.replace(
        /const ansi_colors_1 = __importDefault\(require\(\"ansi-colors\"\)\);/g,
        '// Use direct require for ansi-colors to avoid default import issues in some environments\nconst ansiColors = require(\"ansi-colors\");'
      );
      content = content.replace(/ansi_colors_1\.default/g, 'ansiColors');
      fs.writeFileSync(path, content, 'utf8');
      console.log('fetch.js fixes applied successfully');
    "
  fi

  # Verify that ppc64le is supported in gulpfile.reh.js before attempting build
  # If the patch wasn't applied, the build will fail with "Invalid glob argument"
  if [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
    echo "Verifying ppc64le support in gulpfile.reh.js..."
    if ! grep -q "'ppc64le'" build/gulpfile.reh.js 2>/dev/null && ! grep -q '"ppc64le"' build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: ppc64le architecture not found in gulpfile.reh.js BUILD_TARGETS"
      echo "The arch-1-ppc64le.patch may not have been applied correctly."
      echo "This is required for REH builds on ppc64le."
      exit 1
    fi
    echo "ppc64le support verified in gulpfile.reh.js"
  fi

  # Verify that s390x is supported in gulpfile.reh.js before attempting build
  # If the patch wasn't applied, the build will fail with "Task never defined"
  if [[ "${VSCODE_ARCH}" == "s390x" ]]; then
    echo "Verifying s390x support in gulpfile.reh.js..."
    if ! grep -q "'s390x'" build/gulpfile.reh.js 2>/dev/null && ! grep -q '"s390x"' build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: s390x architecture not found in gulpfile.reh.js BUILD_TARGETS"
      echo "The arch-4-s390x.patch may not have been applied correctly."
      echo "This is required for REH builds on s390x."
      echo "Attempting to apply the patch now..."
      # Try to apply the patch if it exists
      # The patch should be in the builder root, not in vscode directory
      # We're currently in the vscode directory, so we need to go up to find the patch
      PATCH_PATH="../patches/linux/arch-4-s390x.patch"
      if [[ -f "${PATCH_PATH}" ]]; then
        echo "Found patch at ${PATCH_PATH}, applying..."
        if apply_patch "${PATCH_PATH}"; then
          echo "Successfully applied arch-4-s390x.patch"
          # Verify it was applied
          if grep -q "'s390x'" build/gulpfile.reh.js 2>/dev/null || grep -q '"s390x"' build/gulpfile.reh.js 2>/dev/null; then
            echo "s390x support verified in gulpfile.reh.js after patch application"
          else
            echo "ERROR: Patch applied but s390x still not found in gulpfile.reh.js"
            exit 1
          fi
        else
          echo "Failed to apply arch-4-s390x.patch"
          exit 1
        fi
      else
        echo "ERROR: arch-4-s390x.patch not found at ${PATCH_PATH}"
        echo "This patch is required for REH builds on s390x."
        exit 1
      fi
    else
      echo "s390x support verified in gulpfile.reh.js"
    fi
  fi

  # Verify that Node.js site patch is applied for riscv64 and loong64
  if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; then
    echo "Verifying Node.js site patch for ${VSCODE_ARCH}..."
    if ! grep -q "VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: Node.js site patch not found in gulpfile.reh.js"
      echo "The fix-nodejs-site-loong64.patch may not have been applied correctly."
      echo "This is required for REH builds on ${VSCODE_ARCH}."
      exit 1
    fi
    echo "Node.js site patch verified in gulpfile.reh.js"
    # Ensure environment variables are exported for the gulp task
    # These must be explicitly exported right before the gulp task runs
    export VSCODE_NODEJS_SITE="${VSCODE_NODEJS_SITE}"
    export VSCODE_NODEJS_URLROOT="${VSCODE_NODEJS_URLROOT}"
    export VSCODE_NODEJS_URLSUFFIX="${VSCODE_NODEJS_URLSUFFIX}"
    echo "Node.js environment variables for gulp task:"
    echo "  VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}"
    echo "  VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}"
    echo "  VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"
  fi

  # Export all Node.js environment variables before running gulp
  # This ensures they're available to the Node.js process running gulp
  export VSCODE_NODEJS_SITE="${VSCODE_NODEJS_SITE:-}"
  export VSCODE_NODEJS_URLROOT="${VSCODE_NODEJS_URLROOT:-/download/release}"
  export VSCODE_NODEJS_URLSUFFIX="${VSCODE_NODEJS_URLSUFFIX:-}"

  npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"

  EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

  pushd "../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
    bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "node_modules"
  fi

  echo "Archiving REH"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building REH-web"
  # Compile extensions before minifying (extensions need their dependencies installed)
  echo "Compiling extensions for REH-web..."
  npm run gulp compile-extensions-build || echo "Warning: Extension compilation failed, continuing..."
  npm run gulp minify-vscode-reh-web
  npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"

  EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

  pushd "../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
    bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "node_modules"
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
