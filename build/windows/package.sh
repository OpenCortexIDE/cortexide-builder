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

# CRITICAL FIX: Make rcedit optional when wine is not available
# rcedit requires wine on Linux, but wine may not be installed in CI
if [[ -f "build/gulpfile.vscode.js" ]]; then
  echo "Patching gulpfile.vscode.js to make rcedit optional when wine is unavailable..." >&2
  node << 'RCEDITFIX' || {
const fs = require('fs');
const filePath = 'build/gulpfile.vscode.js';
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('// RCEDIT_WINE_FIX')) {
  console.error('gulpfile.vscode.js already patched for rcedit/wine');
  process.exit(0);
}

// Find the rcedit usage and wrap it in try-catch
const lines = content.split('\n');
let modified = false;

for (let i = 0; i < lines.length; i++) {
  // Find: await rcedit(path.join(cwd, dep), {
  if (lines[i].includes('await rcedit(path.join(cwd, dep), {')) {
    // Check if already wrapped
    if (lines[i - 1] && lines[i - 1].includes('try {')) {
      console.error('rcedit already wrapped in try-catch');
      break;
    }
    
    // Find the closing of this rcedit call (should be a few lines later)
    // Wrap the entire Promise.all block in try-catch
    // Look backwards for the Promise.all line
    let promiseAllLine = -1;
    for (let j = i; j >= 0 && j >= i - 5; j--) {
      if (lines[j].includes('Promise.all(deps.map')) {
        promiseAllLine = j;
        break;
      }
    }
    
    if (promiseAllLine >= 0) {
      // Add try-catch around Promise.all
      const indent = lines[promiseAllLine].match(/^\s*/)[0];
      lines[promiseAllLine] = `${indent}// RCEDIT_WINE_FIX: Make rcedit optional when wine is unavailable\n${indent}try {\n${lines[promiseAllLine]}`;
      
      // Find the closing of Promise.all (should be after the rcedit call)
      let closingLine = -1;
      for (let j = i; j < lines.length && j <= i + 15; j++) {
        if (lines[j].includes('}));') && lines[j].match(/^\s*/)[0].length === indent.length) {
          closingLine = j;
          break;
        }
      }
      
      if (closingLine >= 0) {
        // Add catch block after the closing
        lines[closingLine] = `${lines[closingLine]}\n${indent}} catch (err) {\n${indent}  // rcedit requires wine on Linux, skip if not available\n${indent}  if (err.message && err.message.includes('wine')) {\n${indent}    console.warn('Skipping rcedit (wine not available):', err.message);\n${indent}  } else {\n${indent}    throw err;\n${indent}  }\n${indent}}`;
        modified = true;
        console.error(`✓ Wrapped rcedit in try-catch at line ${promiseAllLine + 1}`);
        break;
      }
    }
  }
}

if (modified) {
  content = lines.join('\n');
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched gulpfile.vscode.js to make rcedit optional');
} else {
  console.error('Could not find rcedit usage to patch');
}
RCEDITFIX
    echo "Warning: Failed to patch gulpfile.vscode.js for rcedit, continuing anyway..." >&2
  }
fi

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
