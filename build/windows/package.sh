#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

tar -xzf ./vscode.tar.gz

cd vscode || { echo "'vscode' dir not found"; exit 1; }

# CortexIDE-specific: Clean up any stale processes and build artifacts
echo "Cleaning up processes and build artifacts..."
pkill -f "$(pwd)/out/main.js" || true
pkill -f "$(pwd)/out-build/main.js" || true

# Remove React build output to ensure clean state
if [[ -d "src/vs/workbench/contrib/void/browser/react/out" ]]; then
  rm -rf src/vs/workbench/contrib/void/browser/react/out
fi
if [[ -d "src/vs/workbench/contrib/cortexide/browser/react/out" ]]; then
  rm -rf src/vs/workbench/contrib/cortexide/browser/react/out
fi

export NODE_OPTIONS="--max-old-space-size=12288"

for i in {1..5}; do # try 5 times
  npm ci && break
  if [[ $i -eq 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

. ../build/windows/rtf/make.sh

# CortexIDE: Build React components before packaging
echo "Building React components for Windows ${VSCODE_ARCH}..."
npm run buildreact || echo "Warning: buildreact failed, continuing..."

# Package the Windows application
echo "Packaging Windows ${VSCODE_ARCH} application..."
npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"

. ../build_cli.sh

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
    echo "Building REH"
    npm run gulp minify-vscode-reh

    # Fix fetch.js import issues that prevent Windows REH builds
    # This is a workaround for patch application issues in CI
    if [[ -f "build/lib/fetch.js" ]]; then
      echo "Applying direct fix to fetch.js for Windows REH compatibility..."

      # Use Node.js script to fix the imports more reliably
      node -e "
        const fs = require('fs');
        const path = './build/lib/fetch.js';
        let content = fs.readFileSync(path, 'utf8');

        // Fix event-stream usage
        content = content.replace(
          /return event_stream_1\.default\.readArray\(urls\)\.pipe\(event_stream_1\.default\.map\(/g,
          '// Use a classic CommonJS require for \`event-stream\` to avoid cases where the\n    // transpiled default import does not expose \`readArray\` in some environments.\n    // This mirrors how other build scripts (e.g. \`gulpfile.reh.js\`) consume it.\n    const es = require(\"event-stream\");\n    return es.readArray(urls).pipe(es.map('
        );

        // Fix ansi-colors import
        content = content.replace(
          /const ansi_colors_1 = __importDefault\(require\(\"ansi-colors\"\)\);/g,
          '// Use direct require for ansi-colors to avoid default import issues in some environments\nconst ansiColors = require(\"ansi-colors\");'
        );

        // Fix ansi-colors usage
        content = content.replace(/ansi_colors_1\.default/g, 'ansiColors');

        fs.writeFileSync(path, content, 'utf8');
        console.log('fetch.js fixes applied successfully');
      "
    fi

    npm run gulp "vscode-reh-win32-${VSCODE_ARCH}-min-ci"
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    echo "Building REH-web"
    npm run gulp minify-vscode-reh-web
    npm run gulp "vscode-reh-web-win32-${VSCODE_ARCH}-min-ci"
  fi
fi

cd ..
