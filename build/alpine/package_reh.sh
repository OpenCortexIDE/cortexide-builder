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
    # Check for the actual code pattern from the patch, not just the variable name
    # The patch adds: dockerPlatform = '--platform=linux/arm64'; and uses it in docker run
    if ! grep -q "dockerPlatform.*--platform=linux/arm64" build/gulpfile.reh.js 2>/dev/null && ! grep -q "docker run --rm.*dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: Docker platform patch not found in gulpfile.reh.js"
      echo "The fix-node-docker.patch may not have been applied correctly."
      echo "This is required for Alpine ARM64 REH builds on x64 hosts."
      echo "Attempting to apply the patch now..."
      PATCH_PATH="../patches/alpine/reh/fix-node-docker.patch"
      if [[ -f "${PATCH_PATH}" ]]; then
        echo "Found patch at ${PATCH_PATH}, applying..."
        # Try to apply the patch, but handle "already applied" case
        PATCH_OUTPUT=$(apply_patch "${PATCH_PATH}" 2>&1) || PATCH_EXIT=$?
        if echo "${PATCH_OUTPUT}" | grep -q "already applied\|already exists\|patch does not apply"; then
          echo "Patch reports as already applied or not applicable, verifying actual code..."
          # Check again if the code is actually there
          if grep -q "dockerPlatform.*--platform=linux/arm64" build/gulpfile.reh.js 2>/dev/null || grep -q "docker run --rm.*dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
            echo "Docker platform patch verified in gulpfile.reh.js (code is present)"
          else
            echo "WARNING: Patch says already applied but code not found. Manually applying fix..."
            # Manually apply the fix using Node.js
            node << 'ALPINE_FIX'
const fs = require('fs');
const file = 'build/gulpfile.reh.js';
let content = fs.readFileSync(file, 'utf8');

// Check if the fix is already applied
if (content.includes("dockerPlatform") && content.includes("--platform=linux/arm64")) {
  console.log('Fix already present');
  process.exit(0);
}

// Find the extractAlpinefromDocker function and apply the fix
const functionPattern = /function extractAlpinefromDocker\(nodeVersion, platform, arch\) \{([\s\S]*?)\n\treturn es\.readArray/;
const match = content.match(functionPattern);

if (match) {
  let functionBody = match[1];

  // Check if already fixed
  if (functionBody.includes('dockerPlatform')) {
    console.log('Fix already present in function');
    process.exit(0);
  }

  // Apply the fix: replace the simple imageName assignment with the full logic
  const oldPattern = /const imageName = arch === 'arm64' \? 'arm64v8\/node' : 'node';/;
  const newCode = `let imageName = 'node';\n\tlet dockerPlatform = '';\n\n\tif (arch === 'arm64') {\n\t\timageName = 'arm64v8/node';\n\n\t\tconst architecture = cp.execSync(\`docker info --format '{{json .Architecture}}'\`, { encoding: 'utf8' }).trim();\n\t\tif (architecture != '"aarch64"') {\n\t\t\tdockerPlatform = '--platform=linux/arm64';\n\t\t}\n\t}`;

  if (oldPattern.test(functionBody)) {
    functionBody = functionBody.replace(oldPattern, newCode);
    // Also update the docker run command
    functionBody = functionBody.replace(
      /const contents = cp\.execSync\(`docker run --rm \${imageName}/,
      'const contents = cp.execSync(`docker run --rm ${dockerPlatform} ${imageName}'
    );
    content = content.replace(functionPattern, `function extractAlpinefromDocker(nodeVersion, platform, arch) {${functionBody}\n\treturn es.readArray`);
    fs.writeFileSync(file, content, 'utf8');
    console.log('Manually applied Alpine ARM64 Docker platform fix');
  } else {
    console.log('Could not find expected pattern to replace');
    process.exit(1);
  }
} else {
  console.log('Could not find extractAlpinefromDocker function');
  process.exit(1);
}
ALPINE_FIX
            # Verify the fix was applied
            if grep -q "dockerPlatform.*--platform=linux/arm64" build/gulpfile.reh.js 2>/dev/null || grep -q "docker run --rm.*dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
              echo "Docker platform fix verified in gulpfile.reh.js after manual application"
            else
              echo "ERROR: Failed to apply Docker platform fix"
              exit 1
            fi
          fi
        elif [[ "${PATCH_EXIT:-0}" -eq 0 ]]; then
          echo "Successfully applied fix-node-docker.patch"
          # Verify it was applied
          if grep -q "dockerPlatform.*--platform=linux/arm64" build/gulpfile.reh.js 2>/dev/null || grep -q "docker run --rm.*dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
            echo "Docker platform patch verified in gulpfile.reh.js after application"
          else
            echo "ERROR: Patch applied but dockerPlatform code still not found in gulpfile.reh.js"
            exit 1
          fi
        else
          echo "Failed to apply fix-node-docker.patch, attempting manual fix..."
          # Try manual fix as fallback
          node << 'ALPINE_FIX'
const fs = require('fs');
const file = 'build/gulpfile.reh.js';
let content = fs.readFileSync(file, 'utf8');
if (!content.includes("dockerPlatform") || !content.includes("--platform=linux/arm64")) {
  const functionPattern = /function extractAlpinefromDocker\(nodeVersion, platform, arch\) \{([\s\S]*?)\n\treturn es\.readArray/;
  const match = content.match(functionPattern);
  if (match) {
    let functionBody = match[1];
    const oldPattern = /const imageName = arch === 'arm64' \? 'arm64v8\/node' : 'node';/;
    const newCode = `let imageName = 'node';\n\tlet dockerPlatform = '';\n\n\tif (arch === 'arm64') {\n\t\timageName = 'arm64v8/node';\n\n\t\tconst architecture = cp.execSync(\`docker info --format '{{json .Architecture}}'\`, { encoding: 'utf8' }).trim();\n\t\tif (architecture != '"aarch64"') {\n\t\t\tdockerPlatform = '--platform=linux/arm64';\n\t\t}\n\t}`;
    if (oldPattern.test(functionBody)) {
      functionBody = functionBody.replace(oldPattern, newCode);
      functionBody = functionBody.replace(
        /const contents = cp\.execSync\(`docker run --rm \${imageName}/,
        'const contents = cp.execSync(`docker run --rm ${dockerPlatform} ${imageName}'
      );
      content = content.replace(functionPattern, `function extractAlpinefromDocker(nodeVersion, platform, arch) {${functionBody}\n\treturn es.readArray`);
      fs.writeFileSync(file, content, 'utf8');
      console.log('Manually applied Alpine ARM64 Docker platform fix');
    }
  }
}
ALPINE_FIX
          if grep -q "dockerPlatform.*--platform=linux/arm64" build/gulpfile.reh.js 2>/dev/null || grep -q "docker run --rm.*dockerPlatform" build/gulpfile.reh.js 2>/dev/null; then
            echo "Docker platform fix verified after manual application"
          else
            echo "ERROR: All attempts to apply Docker platform fix failed"
            exit 1
          fi
        fi
      else
        echo "ERROR: fix-node-docker.patch not found at ${PATCH_PATH}"
        echo "This patch is required for Alpine ARM64 REH builds."
        exit 1
      fi
    else
      echo "Docker platform patch verified in gulpfile.reh.js"
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
