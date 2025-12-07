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

for i in {1..5}; do # try 5 times
  npm ci && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

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

  # For Alpine ARM64, verify the Docker platform patch is applied
  # This is critical for cross-architecture builds (ARM64 on x64 hosts)
  if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
    echo "Verifying Docker platform patch for Alpine ARM64..."
    if ! grep -q "dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: Docker platform patch not found in gulpfile.reh.js"
      echo "The fix-node-docker.patch may not have been applied correctly."
      echo "This is required for Alpine ARM64 REH builds on x64 hosts."
      echo "Attempting to apply the patch now..."
      PATCH_PATH="../patches/alpine/reh/fix-node-docker.patch"
      if [[ -f "${PATCH_PATH}" ]]; then
        echo "Found patch at ${PATCH_PATH}, applying..."
        if apply_patch "${PATCH_PATH}"; then
          echo "Successfully applied fix-node-docker.patch"
          # Verify it was applied
          if grep -q "dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
            echo "Docker platform patch verified in gulpfile.reh.js after application"
          else
            echo "ERROR: Patch applied but dockerPlatform still not found in gulpfile.reh.js"
            exit 1
          fi
        else
          echo "Failed to apply fix-node-docker.patch"
          exit 1
        fi
      else
        echo "ERROR: fix-node-docker.patch not found at ${PATCH_PATH}"
        echo "This patch is required for Alpine ARM64 REH builds."
        exit 1
      fi
    else
      echo "Docker platform patch verified in gulpfile.reh.js"
      # Additional check: ensure the dockerPlatform variable is used correctly
      # The patch should add --platform=linux/arm64 when not on an ARM64 host
      if grep -q "dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
        echo "Verifying dockerPlatform usage in extractAlpinefromDocker function..."
        # Check if the dockerPlatform is being used in the docker run command
        if ! grep -q "docker run --rm.*dockerPlatform" build/gulpfile.reh.js 2>/dev/null && ! grep -q "\`docker run --rm \${dockerPlatform}" build/gulpfile.reh.js 2>/dev/null; then
          echo "WARNING: dockerPlatform variable found but may not be used correctly in docker command"
          echo "The patch may need to be updated to ensure --platform=linux/arm64 is always added for ARM64 on x64 hosts"
        fi
      fi
    fi
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
