#!/usr/bin/env bash
# shellcheck disable=SC1091,2154

set -e

# include common functions
. ./utils.sh

# CortexIDE - disable icon copying, we already handled icons
# if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
#   cp -rp src/insider/* vscode/
# else
#   cp -rp src/stable/* vscode/
# fi

# CortexIDE - keep our license...
# cp -f LICENSE vscode/LICENSE.txt

cd vscode || { echo "'vscode' dir not found"; exit 1; }

../update_settings.sh

# apply patches
{ set +x; } 2>/dev/null

echo "APP_NAME=\"${APP_NAME}\""
echo "APP_NAME_LC=\"${APP_NAME_LC}\""
echo "BINARY_NAME=\"${BINARY_NAME}\""
echo "GH_REPO_PATH=\"${GH_REPO_PATH}\""
echo "ORG_NAME=\"${ORG_NAME}\""

echo "Applying patches at ../patches/*.patch..."
for file in ../patches/*.patch; do
  if [[ -f "${file}" ]]; then
    apply_patch "${file}"
  fi
done

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  echo "Applying insider patches..."
  for file in ../patches/insider/*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

if [[ -d "../patches/${OS_NAME}/" ]]; then
  echo "Applying OS patches (${OS_NAME})..."
  for file in "../patches/${OS_NAME}/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

echo "Applying user patches..."
for file in ../patches/user/*.patch; do
  if [[ -f "${file}" ]]; then
    apply_patch "${file}"
  fi
done

# Fix CSS paths for code-icon.svg if they were modified during build
# This comprehensive fix handles all CSS files with incorrect relative paths
# The correct paths depend on the file location relative to browser/media/

echo "Checking and fixing CSS paths for code-icon.svg..."

# Fix specific known issues first (most common cases)

# Fix editorgroupview.css: ../../media/code-icon.svg -> ../../../media/code-icon.svg
if [[ -f "src/vs/workbench/browser/parts/editor/media/editorgroupview.css" ]]; then
  if grep -q "../../media/code-icon.svg" "src/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null; then
    echo "Fixing path in editorgroupview.css..."
    replace "s|url('../../media/code-icon\.svg')|url('../../../media/code-icon.svg')|g" "src/vs/workbench/browser/parts/editor/media/editorgroupview.css"
    replace "s|url(\"../../media/code-icon\.svg\")|url('../../../media/code-icon.svg')|g" "src/vs/workbench/browser/parts/editor/media/editorgroupview.css"
  fi
fi

# Fix void.css: ../../browser/media/code-icon.svg -> ../../../../browser/media/code-icon.svg
if [[ -f "src/vs/workbench/contrib/void/browser/media/void.css" ]]; then
  if grep -q "../../browser/media/code-icon.svg" "src/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null; then
    echo "Fixing path in void.css..."
    replace "s|url('../../browser/media/code-icon\.svg')|url('../../../../browser/media/code-icon.svg')|g" "src/vs/workbench/contrib/void/browser/media/void.css"
    replace "s|url(\"../../browser/media/code-icon\.svg\")|url('../../../../browser/media/code-icon.svg')|g" "src/vs/workbench/contrib/void/browser/media/void.css"
  fi
fi

# General fix: Find all CSS files with incorrect paths and fix them
# Pattern 1: Fix ../../media/code-icon.svg in parts/*/media/ directories (should be ../../../media/code-icon.svg)
find src/vs/workbench/browser/parts -name "*.css" -type f 2>/dev/null | while read -r css_file; do
  if [[ -f "$css_file" ]] && grep -q "../../media/code-icon.svg" "$css_file" 2>/dev/null; then
    echo "Fixing path in $css_file (parts/*/media/)..."
    replace "s|url('../../media/code-icon\.svg')|url('../../../media/code-icon.svg')|g" "$css_file"
    replace "s|url(\"../../media/code-icon\.svg\")|url('../../../media/code-icon.svg')|g" "$css_file"
  fi
done

# Pattern 2: Fix ../../browser/media/code-icon.svg in contrib/*/browser/media/ directories (should be ../../../../browser/media/code-icon.svg)
find src/vs/workbench/contrib -path "*/browser/media/*.css" -type f 2>/dev/null | while read -r css_file; do
  if [[ -f "$css_file" ]] && grep -q "../../browser/media/code-icon.svg" "$css_file" 2>/dev/null; then
    echo "Fixing path in $css_file (contrib/*/browser/media/)..."
    replace "s|url('../../browser/media/code-icon\.svg')|url('../../../../browser/media/code-icon.svg')|g" "$css_file"
    replace "s|url(\"../../browser/media/code-icon\.svg\")|url('../../../../browser/media/code-icon.svg')|g" "$css_file"
  fi
done

# Pattern 3: Fix ../../media/code-icon.svg in contrib/*/media/ directories (should be ../../../../media/code-icon.svg)
find src/vs/workbench/contrib -path "*/media/*.css" -type f 2>/dev/null | while read -r css_file; do
  if [[ -f "$css_file" ]] && [[ "$css_file" != *"browser/media/"* ]] && grep -q "../../media/code-icon.svg" "$css_file" 2>/dev/null; then
    echo "Fixing path in $css_file (contrib/*/media/)..."
    replace "s|url('../../media/code-icon\.svg')|url('../../../../media/code-icon.svg')|g" "$css_file"
    replace "s|url(\"../../media/code-icon\.svg\")|url('../../../../media/code-icon.svg')|g" "$css_file"
  fi
done

echo "CSS path fixes completed."

set -x

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# Ensure npm uses a valid shell for scripts
export SHELL=/bin/bash
export npm_config_script_shell=/bin/bash

if [[ "${OS_NAME}" == "linux" ]]; then
  export VSCODE_SKIP_NODE_VERSION_CHECK=1

   if [[ "${npm_config_arch}" == "arm" ]]; then
    export npm_config_arm_version=7
  fi
elif [[ "${OS_NAME}" == "windows" ]]; then
  if [[ "${npm_config_arch}" == "arm" ]]; then
    export npm_config_arm_version=7
  fi
else
  if [[ "${CI_BUILD}" != "no" ]]; then
    clang++ --version
  fi
fi

mv .npmrc .npmrc.bak
cp ../npmrc .npmrc

# Create @vscode/ripgrep bin folder to skip download during npm install
# This prevents 403 errors from GitHub rate limiting during npm ci
# We'll handle the download manually after npm install with proper error handling
mkdir -p node_modules/@vscode/ripgrep/bin 2>/dev/null || true

# Function to fix node-pty post-install script
fix_node_pty_postinstall() {
  if [[ -f "node_modules/node-pty/scripts/post-install.js" ]]; then
    if grep -q "npx node-gyp configure" "node_modules/node-pty/scripts/post-install.js" && ! grep -q "nodeGypCmd" "node_modules/node-pty/scripts/post-install.js"; then
      echo "Fixing node-pty post-install script to use local node-gyp..."
      cat > /tmp/fix-node-pty-postinstall.js << 'FIXSCRIPT'
const fs = require('fs');
const path = require('path');

const cwd = process.cwd();
const postInstallPath = path.join(cwd, 'node_modules/node-pty/scripts/post-install.js');

if (fs.existsSync(postInstallPath)) {
  let content = fs.readFileSync(postInstallPath, 'utf8');
  
  if (content.includes('nodeGypCmd')) {
    process.exit(0);
  }
  
  const fixCode = `// Try to use local node-gyp first to respect package.json overrides
let nodeGypCmd = 'npx node-gyp';
const localNodeGyp = path.join(__dirname, '../../node-gyp/bin/node-gyp.js');
if (fs.existsSync(localNodeGyp)) {
  nodeGypCmd = \`node "\${localNodeGyp}"\`;
}

`;
  
  content = content.replace(
    /console\.log\(`\\x1b\[32m> Generating compile_commands\.json\.\.\.\\x1b\[0m`\);/,
    fixCode + 'console.log(`\\x1b[32m> Generating compile_commands.json...\\x1b[0m`);'
  );
  
  content = content.replace(
    /execSync\('npx node-gyp configure -- -f compile_commands_json'\);/,
    'execSync(`${nodeGypCmd} configure -- -f compile_commands_json`);'
  );
  
  fs.writeFileSync(postInstallPath, content, 'utf8');
  console.log('Fixed node-pty post-install script');
}
FIXSCRIPT
      node /tmp/fix-node-pty-postinstall.js
      rm -f /tmp/fix-node-pty-postinstall.js
    fi
  fi
}

# Temporarily disable node-pty postinstall to prevent it from running during npm ci
# We'll run it manually after fixing the script
if [[ -f "package.json" ]]; then
  # Check if we need to patch package.json to skip node-pty postinstall
  # Actually, we can't easily do this without modifying the package.json file
  # So we'll let it fail and fix it in the retry loop
  echo "Note: node-pty postinstall may fail on first attempt, will be fixed on retry"
fi

for i in {1..5}; do # try 5 times
  # Fix the script before attempting install (in case it exists from previous attempt)
  fix_node_pty_postinstall
  
  # Try npm install with ignore-scripts for node-pty, then run postinstall manually
  # Actually, we can't selectively ignore scripts, so we'll need to handle failures
  if [[ "${CI_BUILD}" != "no" && "${OS_NAME}" == "osx" ]]; then
    CXX=clang++ npm ci 2>&1 | tee /tmp/npm-install.log || {
      # If it failed, check if it's due to node-pty postinstall or ripgrep download
      if grep -q "node-pty.*postinstall\|ERR_REQUIRE_ESM.*env-paths" /tmp/npm-install.log; then
        echo "npm install failed due to node-pty postinstall issue, fixing and retrying..."
        fix_node_pty_postinstall
        # Remove node-pty to force reinstall
        rm -rf node_modules/node-pty
        # Continue to retry
        continue
      elif grep -q "ripgrep.*403\|Request failed: 403.*ripgrep\|@vscode/ripgrep.*403\|Downloading ripgrep failed" /tmp/npm-install.log; then
        echo "npm install failed due to ripgrep download 403 error, will handle manually after install..."
        # Create bin folder to skip download on retry
        mkdir -p node_modules/@vscode/ripgrep/bin 2>/dev/null || true
        # Continue - the download will be handled manually after successful install
        continue
      fi
      # Other errors, break and retry normally
      false
    } && break
  else
    npm ci 2>&1 | tee /tmp/npm-install.log || {
      if grep -q "node-pty.*postinstall\|ERR_REQUIRE_ESM.*env-paths" /tmp/npm-install.log; then
        echo "npm install failed due to node-pty postinstall issue, fixing and retrying..."
        fix_node_pty_postinstall
        rm -rf node_modules/node-pty
        continue
      elif grep -q "ripgrep.*403\|Request failed: 403.*ripgrep\|@vscode/ripgrep.*403\|Downloading ripgrep failed" /tmp/npm-install.log; then
        echo "npm install failed due to ripgrep download 403 error, will handle manually after install..."
        # Create bin folder to skip download on retry
        mkdir -p node_modules/@vscode/ripgrep/bin 2>/dev/null || true
        # Continue - the download will be handled manually after successful install
        continue
      fi
      false
    } && break
  fi

  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
  
  # Fix the script after failure (it may have been partially installed)
  fix_node_pty_postinstall

  sleep $(( 15 * (i + 1)))
done

rm -f /tmp/npm-install.log
mv .npmrc.bak .npmrc

# Ensure the script is fixed after successful install
fix_node_pty_postinstall

# Handle @vscode/ripgrep download manually after npm install
# This allows us to use GITHUB_TOKEN and handle errors gracefully
if [[ -d "node_modules/@vscode/ripgrep" ]] && [[ ! -f "node_modules/@vscode/ripgrep/bin/rg" ]]; then
  echo "Downloading ripgrep binary manually..."
  # Remove the empty bin folder we created earlier
  rm -rf node_modules/@vscode/ripgrep/bin
  # Run the postinstall script with GITHUB_TOKEN if available
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    (cd node_modules/@vscode/ripgrep && GITHUB_TOKEN="${GITHUB_TOKEN}" node lib/postinstall.js) || {
      echo "Warning: ripgrep download failed, will retry during build if needed"
      # Create empty bin folder to prevent repeated failures
      mkdir -p node_modules/@vscode/ripgrep/bin
    }
  else
    echo "Warning: GITHUB_TOKEN not set, ripgrep download may fail"
    (cd node_modules/@vscode/ripgrep && node lib/postinstall.js) || {
      echo "Warning: ripgrep download failed without token"
      mkdir -p node_modules/@vscode/ripgrep/bin
    }
  fi
fi

# If node-pty was installed but postinstall didn't run, run it manually
# Only run on Linux (Windows and macOS handle this differently)
if [[ "$(uname -s)" == "Linux" ]] && [[ -f "node_modules/node-pty/scripts/post-install.js" ]]; then
  if [[ ! -f "node_modules/node-pty/build/Release/pty.node" ]]; then
    echo "Running node-pty postinstall manually..."
    (cd node_modules/node-pty && node scripts/post-install.js) || echo "node-pty postinstall completed with warnings"
  fi
fi

setpath() {
  local jsonTmp
  { set +x; } 2>/dev/null
  jsonTmp=$( jq --arg 'path' "${2}" --arg 'value' "${3}" 'setpath([$path]; $value)' "${1}.json" )
  echo "${jsonTmp}" > "${1}.json"
  set -x
}

setpath_json() {
  local jsonTmp
  { set +x; } 2>/dev/null
  jsonTmp=$( jq --arg 'path' "${2}" --argjson 'value' "${3}" 'setpath([$path]; $value)' "${1}.json" )
  echo "${jsonTmp}" > "${1}.json"
  set -x
}

# product.json
cp product.json{,.bak}

setpath "product" "checksumFailMoreInfoUrl" "https://go.microsoft.com/fwlink/?LinkId=828886"
setpath "product" "documentationUrl" "https://cortexide.com"
# setpath_json "product" "extensionsGallery" '{"serviceUrl": "https://open-vsx.org/vscode/gallery", "itemUrl": "https://open-vsx.org/vscode/item"}'
setpath "product" "introductoryVideosUrl" "https://go.microsoft.com/fwlink/?linkid=832146"
setpath "product" "keyboardShortcutsUrlLinux" "https://go.microsoft.com/fwlink/?linkid=832144"
setpath "product" "keyboardShortcutsUrlMac" "https://go.microsoft.com/fwlink/?linkid=832143"
setpath "product" "keyboardShortcutsUrlWin" "https://go.microsoft.com/fwlink/?linkid=832145"
setpath "product" "licenseUrl" "https://github.com/cortexide/cortexide/blob/main/LICENSE.txt"
# setpath_json "product" "linkProtectionTrustedDomains" '["https://open-vsx.org"]'
# setpath "product" "releaseNotesUrl" "https://go.microsoft.com/fwlink/?LinkID=533483#vscode"
setpath "product" "reportIssueUrl" "https://github.com/cortexide/cortexide/issues/new"
setpath "product" "requestFeatureUrl" "https://github.com/cortexide/cortexide/issues/new"
setpath "product" "tipsAndTricksUrl" "https://go.microsoft.com/fwlink/?linkid=852118"
setpath "product" "twitterUrl" "https://x.com/cortexide"

if [[ "${DISABLE_UPDATE}" != "yes" ]]; then
  setpath "product" "updateUrl" "https://raw.githubusercontent.com/OpenCortexIDE/cortexide-versions/refs/heads/main"
  setpath "product" "downloadUrl" "https://github.com/OpenCortexIDE/cortexide-binaries/releases"
fi

# Note: CortexIDE product.json already has correct branding, so these overrides may not be needed
# but we keep them for consistency and to override if needed
if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  setpath "product" "nameShort" "CortexIDE - Insiders"
  setpath "product" "nameLong" "CortexIDE - Insiders"
  setpath "product" "applicationName" "cortexide-insiders"
  setpath "product" "dataFolderName" ".cortexide-insiders"
  setpath "product" "linuxIconName" "cortexide-insiders"
  setpath "product" "quality" "insider"
  setpath "product" "urlProtocol" "cortexide-insiders"
  setpath "product" "serverApplicationName" "cortexide-server-insiders"
  setpath "product" "serverDataFolderName" ".cortexide-server-insiders"
  setpath "product" "darwinBundleIdentifier" "com.cortexide.code-insiders"
  setpath "product" "win32AppUserModelId" "CortexIDE.CortexIDEInsiders"
  setpath "product" "win32DirName" "CortexIDE Insiders"
  setpath "product" "win32MutexName" "cortexideinsiders"
  setpath "product" "win32NameVersion" "CortexIDE Insiders"
  setpath "product" "win32RegValueName" "CortexIDEInsiders"
  setpath "product" "win32ShellNameShort" "CortexIDE Insiders"
  setpath "product" "win32AppId" "{{5893CE20-77AA-4856-A655-ECE65CBCF1C7}"
  setpath "product" "win32x64AppId" "{{7A261980-5847-44B6-B554-31DF0F5CDFC9}"
  setpath "product" "win32arm64AppId" "{{EE4FF7AA-A874-419D-BAE0-168C9DBCE211}"
  setpath "product" "win32UserAppId" "{{FA3AE0C7-888E-45DA-AB58-B8E33DE0CB2E}"
  setpath "product" "win32x64UserAppId" "{{5B1813E3-1D97-4E00-AF59-C59A39CF066A}"
  setpath "product" "win32arm64UserAppId" "{{C2FA90D8-B265-41B1-B909-3BAEB21CAA9D}"
else
  # CortexIDE product.json already has most of these, but we set them for consistency
  setpath "product" "nameShort" "CortexIDE"
  setpath "product" "nameLong" "CortexIDE"
  setpath "product" "applicationName" "cortexide"
  setpath "product" "linuxIconName" "cortexide"
  setpath "product" "quality" "stable"
  setpath "product" "urlProtocol" "cortexide"
  setpath "product" "serverApplicationName" "cortexide-server"
  setpath "product" "serverDataFolderName" ".cortexide-server"
  setpath "product" "darwinBundleIdentifier" "com.cortexide.code"
  setpath "product" "win32AppUserModelId" "CortexIDE.Editor"
  setpath "product" "win32DirName" "CortexIDE"
  setpath "product" "win32MutexName" "cortexide"
  setpath "product" "win32NameVersion" "CortexIDE"
  setpath "product" "win32RegValueName" "CortexIDE"
  setpath "product" "win32ShellNameShort" "CortexIDE"
  # CortexIDE product.json already has these AppIds set
fi

jsonTmp=$( jq -s '.[0] * .[1]' product.json ../product.json )
echo "${jsonTmp}" > product.json && unset jsonTmp

cat product.json

# package.json
cp package.json{,.bak}

setpath "package" "version" "${RELEASE_VERSION%-insider}"

replace 's|Microsoft Corporation|CortexIDE|' package.json

cp resources/server/manifest.json{,.bak}

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  setpath "resources/server/manifest" "name" "CortexIDE - Insiders"
  setpath "resources/server/manifest" "short_name" "CortexIDE - Insiders"
else
  setpath "resources/server/manifest" "name" "CortexIDE"
  setpath "resources/server/manifest" "short_name" "CortexIDE"
fi

# announcements
# replace "s|\\[\\/\\* BUILTIN_ANNOUNCEMENTS \\*\\/\\]|$( tr -d '\n' < ../announcements-builtin.json )|" src/vs/workbench/contrib/welcomeGettingStarted/browser/gettingStarted.ts

../undo_telemetry.sh

replace 's|Microsoft Corporation|CortexIDE|' build/lib/electron.js
replace 's|Microsoft Corporation|CortexIDE|' build/lib/electron.ts
replace 's|([0-9]) Microsoft|\1 CortexIDE|' build/lib/electron.js
replace 's|([0-9]) Microsoft|\1 CortexIDE|' build/lib/electron.ts

if [[ "${OS_NAME}" == "linux" ]]; then
  # microsoft adds their apt repo to sources
  # unless the app name is code-oss
  # as we are renaming the application to cortexide
  # we need to edit a line in the post install template
  if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
    sed -i "s/code-oss/cortexide-insiders/" resources/linux/debian/postinst.template
  else
    sed -i "s/code-oss/cortexide/" resources/linux/debian/postinst.template
  fi

  # fix the packages metadata
  # code.appdata.xml
  sed -i 's|Visual Studio Code|CortexIDE|g' resources/linux/code.appdata.xml
  sed -i 's|https://code.visualstudio.com/docs/setup/linux|https://cortexide.com|' resources/linux/code.appdata.xml
  sed -i 's|https://code.visualstudio.com/home/home-screenshot-linux-lg.png|https://cortexide.com/img/cortexide.png|' resources/linux/code.appdata.xml
  sed -i 's|https://code.visualstudio.com|https://cortexide.com|' resources/linux/code.appdata.xml

  # control.template
  sed -i 's|Microsoft Corporation <vscode-linux@microsoft.com>|CortexIDE Team <team@cortexide.com>|'  resources/linux/debian/control.template
  sed -i 's|Visual Studio Code|CortexIDE|g' resources/linux/debian/control.template
  sed -i 's|https://code.visualstudio.com/docs/setup/linux|https://cortexide.com|' resources/linux/debian/control.template
  sed -i 's|https://code.visualstudio.com|https://cortexide.com|' resources/linux/debian/control.template

  # code.spec.template
  sed -i 's|Microsoft Corporation|CortexIDE Team|' resources/linux/rpm/code.spec.template
  sed -i 's|Visual Studio Code Team <vscode-linux@microsoft.com>|CortexIDE Team <team@cortexide.com>|' resources/linux/rpm/code.spec.template
  sed -i 's|Visual Studio Code|CortexIDE|' resources/linux/rpm/code.spec.template
  sed -i 's|https://code.visualstudio.com/docs/setup/linux|https://cortexide.com|' resources/linux/rpm/code.spec.template
  sed -i 's|https://code.visualstudio.com|https://cortexide.com|' resources/linux/rpm/code.spec.template

  # snapcraft.yaml
  sed -i 's|Visual Studio Code|CortexIDE|'  resources/linux/rpm/code.spec.template
elif [[ "${OS_NAME}" == "windows" ]]; then
  # code.iss
  sed -i 's|https://code.visualstudio.com|https://cortexide.com|' build/win32/code.iss
  sed -i 's|Microsoft Corporation|CortexIDE|' build/win32/code.iss
fi

cd ..
