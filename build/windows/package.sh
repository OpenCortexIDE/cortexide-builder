#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

tar -xzf ./vscode.tar.gz

cd vscode || { echo "'vscode' dir not found"; exit 1; }

# CRITICAL FIX: Skip Node.js version check in preinstall.js
# CI uses Node.js v20.18.2, but preinstall.js requires v22.15.1+
# The script supports VSCODE_SKIP_NODE_VERSION_CHECK to skip this check
export VSCODE_SKIP_NODE_VERSION_CHECK=1

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
        if (content.includes('// RCEDIT_WINE_FIX')) {
          console.error('rcedit already wrapped in try-catch');
          break;
        }
        
        // Wrap the rcedit call itself in try-catch
        // The rcedit call is inside a Promise.all map function
        const indent = lines[i].match(/^\s*/)[0];
        
        // Insert try before rcedit
        lines[i] = `${indent}try {\n${lines[i]}`;
        
        // Find the closing of rcedit call (should be a few lines later with });
        let rceditCloseLine = -1;
        for (let j = i + 1; j < lines.length && j <= i + 15; j++) {
          if (lines[j].includes('});') && lines[j].match(/^\s*/)[0].length === indent.length) {
            rceditCloseLine = j;
            break;
          }
        }
        
        if (rceditCloseLine >= 0) {
          // Add catch block after rcedit closing
          lines[rceditCloseLine] = `${lines[rceditCloseLine]}\n${indent}} catch (err) {\n${indent}  // RCEDIT_WINE_FIX: rcedit requires wine on Linux, skip if not available\n${indent}  if (err.message && (err.message.includes('wine') || err.message.includes('ENOENT') || err.code === 'ENOENT')) {\n${indent}    console.warn('Skipping rcedit (wine not available):', err.message);\n${indent}  } else {\n${indent}    throw err;\n${indent}  }\n${indent}}`;
          modified = true;
          console.error(`✓ Wrapped rcedit in try-catch at line ${i + 1}`);
          break;
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
