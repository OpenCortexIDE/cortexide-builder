#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

tar -xzf ./vscode.tar.gz

cd vscode || { echo "'vscode' dir not found"; exit 1; }

for i in {1..5}; do # try 5 times
  npm ci && break
  if [[ $i -eq 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

. ../build/windows/rtf/make.sh

# CRITICAL FIX: Skip AppX building if win32ContextMenu is missing
if [[ -f "build/gulpfile.vscode.js" ]]; then
  echo "Checking for win32ContextMenu in product.json..." >&2
  node << 'APPXFIX' || {
const fs = require('fs');
const productPath = 'product.json';
const gulpfilePath = 'build/gulpfile.vscode.js';

try {
  const product = JSON.parse(fs.readFileSync(productPath, 'utf8'));
  const hasWin32ContextMenu = product.win32ContextMenu && 
                               product.win32ContextMenu.x64 && 
                               product.win32ContextMenu.x64.clsid;
  
  if (!hasWin32ContextMenu) {
    console.error('win32ContextMenu missing in product.json, skipping AppX build...');
    
    let content = fs.readFileSync(gulpfilePath, 'utf8');
    const lines = content.split('\n');
    let modified = false;
    
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].includes("if (quality === 'stable' || quality === 'insider')") && 
          i + 1 < lines.length && 
          lines[i + 1].includes('.build/win32/appx')) {
        if (lines[i].includes('product.win32ContextMenu')) {
          console.error('Already has win32ContextMenu check');
          break;
        }
        
        const indent = lines[i].match(/^\s*/)[0];
        const newCondition = `${indent}if ((quality === 'stable' || quality === 'insider') && product.win32ContextMenu && product.win32ContextMenu[arch]) {`;
        lines[i] = newCondition;
        modified = true;
        console.error(`✓ Added win32ContextMenu check at line ${i + 1}`);
        break;
      }
    }
    
    if (modified) {
      content = lines.join('\n');
      fs.writeFileSync(gulpfilePath, content, 'utf8');
      console.error('✓ Successfully patched gulpfile.vscode.js to skip AppX when win32ContextMenu is missing');
    }
  } else {
    console.error('✓ win32ContextMenu found in product.json, AppX building enabled');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  process.exit(1);
}
APPXFIX
    echo "Warning: Failed to patch gulpfile.vscode.js for AppX, continuing anyway..." >&2
  }
fi

npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"

. ../build_cli.sh

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
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
  
  if (modified) {
    content = lines.join('\n');
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully applied REH glob fix');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  process.exit(1);
}
REHFIX
        echo "Warning: Failed to patch gulpfile.reh.js, continuing anyway..." >&2
      }
    fi
    
    npm run gulp minify-vscode-reh
    npm run gulp "vscode-reh-win32-${VSCODE_ARCH}-min-ci"
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    echo "Building REH-web"
    npm run gulp minify-vscode-reh-web
    npm run gulp "vscode-reh-web-win32-${VSCODE_ARCH}-min-ci"
  fi
fi

cd ..
