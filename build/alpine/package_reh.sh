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

export VSCODE_PLATFORM='alpine'
export VSCODE_SKIP_NODE_VERSION_CHECK=1

VSCODE_HOST_MOUNT="$( pwd )"
VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:alpine-${VSCODE_ARCH}"

export VSCODE_HOST_MOUNT VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME

if [[ -d "../patches/alpine/reh/" ]]; then
  for file in "../patches/alpine/reh/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

# For Alpine ARM64, skip native module builds to avoid compiler crashes
# Native modules like kerberos can't be built reliably in the Alpine ARM64 environment
NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for Alpine ARM64 (native modules can't build reliably)"
  # Also prevent node-gyp from trying to build native modules
  export npm_config_build_from_source=false
  export npm_config_ignore_scripts=true
fi

for i in {1..5}; do # try 5 times
  npm ci ${NPM_CI_OPTS} && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

# For Alpine ARM64, ensure ternary-stream is installed in build directory (it might be missing due to --ignore-scripts)
# ternary-stream is required by build/lib/util.js, so it needs to be in build/node_modules
# This must be done BEFORE running any gulp commands
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  echo "Checking for ternary-stream in build directory for Alpine ARM64..."
  # Check if ternary-stream exists in build/node_modules (more reliable than npm list)
  if [[ ! -d "build/node_modules/ternary-stream" ]] && [[ ! -f "build/node_modules/ternary-stream/package.json" ]]; then
    echo "Installing ternary-stream in build directory (required for build/lib/util.js but may be missing due to --ignore-scripts)..."
    # Ensure build directory exists and has a package.json
    if [[ ! -f "build/package.json" ]]; then
      echo "ERROR: build/package.json not found, cannot install ternary-stream"
      exit 1
    fi
    npm install ternary-stream --prefix build --no-save --legacy-peer-deps || {
      echo "ERROR: Failed to install ternary-stream in build directory!"
      echo "This is required for Alpine ARM64 REH builds"
      exit 1
    }
    # Verify installation
    if [[ ! -d "build/node_modules/ternary-stream" ]] && [[ ! -f "build/node_modules/ternary-stream/package.json" ]]; then
      echo "ERROR: ternary-stream installation verification failed!"
      exit 1
    fi
    echo "✓ ternary-stream installed successfully in build directory"
  else
    echo "✓ ternary-stream already present in build directory"
  fi
fi

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  PA_NAME="linux-alpine"
else
  PA_NAME="alpine-arm64"
fi

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building REH"
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

  npm run gulp "vscode-reh-${PA_NAME}-min-ci"

  pushd "../vscode-reh-${PA_NAME}"

  echo "Archiving REH"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building REH-web"
  npm run gulp minify-vscode-reh-web
  npm run gulp "vscode-reh-web-${PA_NAME}-min-ci"

  pushd "../vscode-reh-web-${PA_NAME}"

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
