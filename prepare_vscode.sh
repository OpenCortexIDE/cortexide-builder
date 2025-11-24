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

# Verify critical icons exist (icons should be handled by separate scripts)
if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  ICON_SRC_DIR="../src/insider"
else
  ICON_SRC_DIR="../src/stable"
fi

if [[ -d "${ICON_SRC_DIR}" ]]; then
  MISSING_ICONS=0
  # Check for critical platform icons
  if [[ "${OS_NAME}" == "osx" ]] && [[ ! -f "${ICON_SRC_DIR}/resources/darwin/code.icns" ]]; then
    echo "Warning: macOS icon (code.icns) not found in ${ICON_SRC_DIR}/resources/darwin/" >&2
    MISSING_ICONS=1
  elif [[ "${OS_NAME}" == "windows" ]] && [[ ! -f "${ICON_SRC_DIR}/resources/win32/code.ico" ]]; then
    echo "Warning: Windows icon (code.ico) not found in ${ICON_SRC_DIR}/resources/win32/" >&2
    MISSING_ICONS=1
  elif [[ "${OS_NAME}" == "linux" ]] && [[ ! -f "${ICON_SRC_DIR}/resources/linux/code.png" ]] && [[ ! -f "${ICON_SRC_DIR}/resources/linux/code.svg" ]]; then
    echo "Warning: Linux icon (code.png or code.svg) not found in ${ICON_SRC_DIR}/resources/linux/" >&2
    MISSING_ICONS=1
  fi
  
  if [[ "${MISSING_ICONS}" -eq 1 ]]; then
    echo "Warning: Some critical icons are missing. The app may have default/generic icons." >&2
    echo "  Icons should be handled by scripts/update-all-assets.sh or similar." >&2
  else
    echo "✓ Critical icons verified"
  fi
fi

cd vscode || { echo "'vscode' dir not found"; exit 1; }

echo "Updating settings..."
# update_settings.sh doesn't exit on errors, but we should check for critical failures
if ! ../update_settings.sh 2>&1 | tee /tmp/update_settings.log; then
  echo "Warning: update_settings.sh had some issues. Checking log..." >&2
  if grep -q "File to update setting in does not exist" /tmp/update_settings.log; then
    echo "Error: Critical settings files are missing. Build cannot continue." >&2
    exit 1
  else
    echo "Warning: Some settings updates may have failed, but continuing build..." >&2
  fi
fi
rm -f /tmp/update_settings.log

# apply patches
{ set +x; } 2>/dev/null

echo "APP_NAME=\"${APP_NAME}\""
echo "APP_NAME_LC=\"${APP_NAME_LC}\""
echo "BINARY_NAME=\"${BINARY_NAME}\""
echo "GH_REPO_PATH=\"${GH_REPO_PATH}\""
echo "ORG_NAME=\"${ORG_NAME}\""

echo "Applying patches at ../patches/*.patch..."
PATCH_COUNT=0
for file in ../patches/*.patch; do
  if [[ -f "${file}" ]]; then
    PATCH_COUNT=$((PATCH_COUNT + 1))
    # apply_patch handles non-critical patches internally and returns 0 for them
    # Only exit if it's a critical patch that failed
    if ! apply_patch "${file}"; then
      # Check if this was a non-critical patch (apply_patch should have handled it)
      # If we get here, it means a critical patch failed
      echo "Error: Critical patch ${file} failed to apply" >&2
      exit 1
    fi
  fi
done
echo "Successfully applied ${PATCH_COUNT} patches"

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
  # Temporarily disable set -e for OS patches since they're all non-critical
  set +e
  for file in "../patches/${OS_NAME}/"*.patch; do
    if [[ -f "${file}" ]]; then
      # OS patches are non-critical - apply_patch should handle them gracefully
      # but we disable set -e to be absolutely sure we don't exit
      apply_patch "${file}" || {
        echo "Warning: OS patch $(basename "${file}") failed, but continuing build..." >&2
        # For window visibility fix, ALWAYS try script-based approach as fallback
        # This ensures the fix is applied even if the patch fails
        if [[ "$(basename "${file}")" == "fix-window-visibility.patch" ]]; then
          echo "CRITICAL: Window visibility patch failed. Applying script-based fix..." >&2
          if [[ -f "../patches/${OS_NAME}/apply-window-visibility-fix.sh" ]]; then
            chmod +x "../patches/${OS_NAME}/apply-window-visibility-fix.sh"
            # Auto-detect which file exists (new or old structure)
            WINDOW_FILE_FALLBACK=""
            if [[ -f "src/vs/platform/windows/electron-main/windowImpl.ts" ]]; then
              WINDOW_FILE_FALLBACK="src/vs/platform/windows/electron-main/windowImpl.ts"
            elif [[ -f "src/vs/code/electron-main/window.ts" ]]; then
              WINDOW_FILE_FALLBACK="src/vs/code/electron-main/window.ts"
            fi
            if [[ -n "${WINDOW_FILE_FALLBACK}" ]]; then
              if "../patches/${OS_NAME}/apply-window-visibility-fix.sh" "${WINDOW_FILE_FALLBACK}"; then
                echo "✓ Window visibility fix applied via script fallback" >&2
              else
                echo "ERROR: Script-based window visibility fix also failed!" >&2
                echo "  This is a critical fix for macOS blank screen. Build may produce broken app." >&2
              fi
            else
              echo "ERROR: Could not find window file for script-based fix!" >&2
            fi
          else
            echo "ERROR: Window visibility fix script not found!" >&2
          fi
        fi
      }
    fi
  done
  
  # CRITICAL: For macOS, ALWAYS ensure window visibility fix is applied
  # This is a critical fix for blank screen - must be applied regardless of patch status
  if [[ "${OS_NAME}" == "osx" ]]; then
    # Try new file path first (current codebase structure)
    WINDOW_FILE_NEW="src/vs/platform/windows/electron-main/windowImpl.ts"
    # Fallback to old file path (legacy codebase structure)
    WINDOW_FILE_OLD="src/vs/code/electron-main/window.ts"
    
    WINDOW_FILE=""
    if [[ -f "${WINDOW_FILE_NEW}" ]]; then
      WINDOW_FILE="${WINDOW_FILE_NEW}"
    elif [[ -f "${WINDOW_FILE_OLD}" ]]; then
      WINDOW_FILE="${WINDOW_FILE_OLD}"
    fi
    
    if [[ -n "${WINDOW_FILE}" ]]; then
      # Check for any macOS fix marker (multiple possible formats)
      if ! grep -q "Fix for macOS blank screen" "${WINDOW_FILE}" && \
         ! grep -q "macOS: Comprehensive fix for blank screen" "${WINDOW_FILE}" && \
         ! grep -q "macOS.*blank screen" "${WINDOW_FILE}"; then
        echo "CRITICAL: Window visibility fix not found. Applying via script (this MUST succeed)..." >&2
        if [[ -f "../patches/${OS_NAME}/apply-window-visibility-fix.sh" ]]; then
          chmod +x "../patches/${OS_NAME}/apply-window-visibility-fix.sh"
          if "../patches/${OS_NAME}/apply-window-visibility-fix.sh" "${WINDOW_FILE}"; then
            echo "✓ Window visibility fix applied successfully via script"
          else
            echo "ERROR: CRITICAL FAILURE - Window visibility fix could not be applied!" >&2
            echo "  This will cause blank screen on macOS. Build should not continue." >&2
            echo "  File: ${WINDOW_FILE}" >&2
            echo "  Please check the file structure and fix manually." >&2
            # Don't exit - let build continue but warn loudly
          fi
        else
          echo "ERROR: Window visibility fix script not found at:" >&2
          echo "  ../patches/${OS_NAME}/apply-window-visibility-fix.sh" >&2
        fi
      else
        # Verify the fix is actually present (not just a comment)
        if grep -q "isMacintosh.*this\._win\|isMacintosh.*this\.win" "${WINDOW_FILE}"; then
          echo "✓ Window visibility fix verified in ${WINDOW_FILE}"
        else
          echo "WARNING: Window visibility fix marker found but actual fix code may be missing!" >&2
          if ! grep -q "showInactive\|isVisible\|getBounds" "${WINDOW_FILE}"; then
            echo "  ERROR: Window visibility fix code not found! This will cause blank screen." >&2
            echo "  File: ${WINDOW_FILE}" >&2
            echo "  Please check the file structure and fix manually." >&2
          fi
        fi
        # Double-check the fix is actually present (not just a comment)
        if ! grep -q "showInactive\|show\(\)" "${WINDOW_FILE}" 2>/dev/null; then
          echo "WARNING: Window visibility fix marker found but actual fix code may be missing!" >&2
          echo "  Checking for common fix patterns..." >&2
          if ! grep -qE "(window\.show\(\)|window\.showInactive\(\)|Fix for macOS blank screen)" "${WINDOW_FILE}" 2>/dev/null; then
            echo "  ERROR: Window visibility fix code not found! This will cause blank screen." >&2
            echo "  Please verify the fix was applied correctly." >&2
          fi
        fi
      fi
    else
      echo "WARNING: window.ts not found at either:" >&2
      echo "  ${WINDOW_FILE_NEW}" >&2
      echo "  ${WINDOW_FILE_OLD}" >&2
      echo "  Cannot apply window visibility fix. This may cause blank screen on macOS." >&2
    fi
  fi
  
  # Re-enable set -e after OS patches
  set -e
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

# Verify CSS path fixes were applied correctly
echo "Verifying CSS path fixes..."
CSS_FIX_VERIFICATION_FAILED=0
find src/vs/workbench/browser/parts -name "*.css" -type f 2>/dev/null | while read -r css_file; do
  if [[ -f "$css_file" ]] && grep -q "../../media/code-icon.svg" "$css_file" 2>/dev/null; then
    echo "Warning: $css_file still contains incorrect path ../../media/code-icon.svg" >&2
    CSS_FIX_VERIFICATION_FAILED=1
  fi
done

find src/vs/workbench/contrib -path "*/browser/media/*.css" -type f 2>/dev/null | while read -r css_file; do
  if [[ -f "$css_file" ]] && grep -q "../../browser/media/code-icon.svg" "$css_file" 2>/dev/null; then
    echo "Warning: $css_file still contains incorrect path ../../browser/media/code-icon.svg" >&2
    CSS_FIX_VERIFICATION_FAILED=1
  fi
done

if [[ "${CSS_FIX_VERIFICATION_FAILED}" -eq 1 ]]; then
  echo "Warning: Some CSS files may still have incorrect paths. Icons may not display correctly." >&2
else
  echo "✓ CSS path fixes verified"
fi

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

  if [[ $i == 5 ]]; then
    echo "Error: npm install failed after 5 attempts" >&2
    echo "Last error log:" >&2
    tail -50 /tmp/npm-install.log >&2 || true
    echo "" >&2
    echo "Common issues:" >&2
    echo "  - Network connectivity problems" >&2
    echo "  - npm registry issues" >&2
    echo "  - Disk space issues" >&2
    echo "  - Permission problems" >&2
    echo "  - Corrupted node_modules (try: rm -rf node_modules package-lock.json && npm install)" >&2
    exit 1
  fi
  echo "Npm install failed (attempt $i/5), trying again in $(( 15 * (i + 1))) seconds..."

  # Fix the script after failure (it may have been partially installed)
  fix_node_pty_postinstall

  sleep $(( 15 * (i + 1)))
done

rm -f /tmp/npm-install.log
mv .npmrc.bak .npmrc

# Ensure the script is fixed after successful install
fix_node_pty_postinstall

# Verify critical dependencies are installed (especially for buildreact)
echo "Verifying critical dependencies..."
MISSING_DEPS=0
for dep in cross-spawn; do
  if [[ ! -d "node_modules/${dep}" ]] && [[ ! -f "node_modules/${dep}/package.json" ]]; then
    echo "Warning: Critical dependency '${dep}' is missing from node_modules" >&2
    MISSING_DEPS=1
  fi
done

if [[ $MISSING_DEPS -eq 1 ]]; then
  echo "Attempting to install missing dependencies..." >&2
  npm install cross-spawn 2>&1 | tail -20 || {
    echo "Error: Failed to install missing dependencies. The build may fail." >&2
    echo "Try running: cd vscode && npm install cross-spawn" >&2
  }
fi

# Verify build directory dependencies are installed
echo "Verifying build directory dependencies..."
if [[ -f "build/package.json" ]]; then
  # Check if build dependencies need to be installed
  if [[ ! -d "build/node_modules" ]] || [[ ! -d "node_modules/ternary-stream" ]]; then
    echo "Installing build directory dependencies..." >&2
    # Try installing in build directory first
    if [[ -f "build/package-lock.json" ]] || [[ -f "build/package.json" ]]; then
      (cd build && npm install 2>&1 | tail -30) || {
        echo "Warning: Failed to install build dependencies in build/ directory" >&2
        # Try installing at root level (dependencies might be hoisted)
        echo "Attempting to install build dependencies at root level..." >&2
        npm install ternary-stream 2>&1 | tail -20 || {
          echo "Error: Failed to install ternary-stream. The build may fail." >&2
          echo "Try running: cd vscode && npm install ternary-stream" >&2
        }
      }
    fi
  fi
fi

# PERMANENT FIX: Convert all ESM-only modules to dynamic imports in @vscode/gulp-electron
# This handles @electron/get, @octokit/rest, got, and any future ESM-only modules
echo "Applying permanent ESM compatibility fix to @vscode/gulp-electron..."
if [[ -f "node_modules/@vscode/gulp-electron/src/download.js" ]]; then
  # Check if already patched (look for dynamic import pattern)
  if ! grep -q "async function ensureESMModules" "node_modules/@vscode/gulp-electron/src/download.js" 2>/dev/null; then
    # Check if it needs patching (has any ESM-only requires)
    if grep -qE 'require\("@electron/get"\)|require\("@octokit/rest"\)|require\("got"\)' "node_modules/@vscode/gulp-electron/src/download.js" 2>/dev/null; then
      echo "Patching @vscode/gulp-electron to use dynamic imports for ALL ESM modules..." >&2
      # Create a backup
      cp "node_modules/@vscode/gulp-electron/src/download.js" "node_modules/@vscode/gulp-electron/src/download.js.bak" 2>/dev/null || true

      # Comprehensive patch script that handles ALL ESM modules
      cat > /tmp/fix-esm-modules.js << 'EOF'
const fs = require('fs');

const filePath = process.argv[2];
let content = fs.readFileSync(filePath, 'utf8');

// List of ESM-only modules that need dynamic import
const esmModules = {
  '@electron/get': { exports: ['downloadArtifact'], varName: 'downloadArtifact' },
  '@octokit/rest': { exports: ['Octokit'], varName: 'Octokit' },
  'got': { exports: ['got'], varName: 'got' }
};

// Step 1: Replace all require() statements for ESM modules with let declarations
Object.keys(esmModules).forEach(moduleName => {
  const moduleInfo = esmModules[moduleName];
  const exportsList = moduleInfo.exports.join(', ');
  const pattern = new RegExp(`const \\{ ${exportsList} \\} = require\\(\"${moduleName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\"\\);`, 'g');
  const replacement = `let ${exportsList.split(', ').map(e => e.trim()).join(', ')};`;
  content = content.replace(pattern, replacement);
});

// Step 2: Create a helper function to ensure all ESM modules are loaded
const ensureFunction = `
// Helper function to dynamically import ESM-only modules
async function ensureESMModules() {
  if (!downloadArtifact) {
    const electronGet = await import("@electron/get");
    downloadArtifact = electronGet.downloadArtifact;
  }
  if (!Octokit) {
    const octokitRest = await import("@octokit/rest");
    Octokit = octokitRest.Octokit;
  }
  if (!got) {
    const gotModule = await import("got");
    got = gotModule.got;
  }
}
`;

// Insert the helper function after the last require statement (before first function)
const lastRequireMatch = content.match(/require\([^)]+\);/g);
if (lastRequireMatch) {
  const lastRequireIndex = content.lastIndexOf(lastRequireMatch[lastRequireMatch.length - 1]);
  const insertIndex = content.indexOf('\n', lastRequireIndex) + 1;
  content = content.slice(0, insertIndex) + ensureFunction + content.slice(insertIndex);
}

// Step 3: Add ensureESMModules() call at the start of async functions that use ESM modules
const asyncFunctions = [
  { name: 'async function getDownloadUrl', pattern: /(async function getDownloadUrl\([^)]+\) \{)/ },
  { name: 'async function download', pattern: /(async function download\(opts\) \{)/ }
];

asyncFunctions.forEach(funcInfo => {
  if (funcInfo.pattern.test(content)) {
    const callCode = `  await ensureESMModules();\n`;

    // Check if this specific function already has the call
    const funcMatch = content.match(funcInfo.pattern);
    if (funcMatch) {
      const funcStart = funcMatch.index;
      const funcBodyStart = funcStart + funcMatch[0].length;
      const next50Chars = content.substring(funcBodyStart, funcBodyStart + 50);

      // Only add if not already present in this function
      if (!next50Chars.includes('ensureESMModules()')) {
        content = content.replace(
          funcInfo.pattern,
          `$1\n${callCode}`
        );
      }
    }
  }
});

fs.writeFileSync(filePath, content, 'utf8');
console.log('Successfully patched @vscode/gulp-electron for ESM compatibility');
EOF

      # Run the comprehensive patch script
      node /tmp/fix-esm-modules.js "node_modules/@vscode/gulp-electron/src/download.js" 2>&1 || {
        echo "Error: Failed to patch @vscode/gulp-electron. Restoring backup..." >&2
        # Restore backup if patch failed
        if [[ -f "node_modules/@vscode/gulp-electron/src/download.js.bak" ]]; then
          mv "node_modules/@vscode/gulp-electron/src/download.js.bak" "node_modules/@vscode/gulp-electron/src/download.js" 2>/dev/null || true
          echo "Backup restored. Build may fail with ERR_REQUIRE_ESM." >&2
        fi
      }
      rm -f /tmp/fix-esm-modules.js
    else
      echo "No ESM modules detected in @vscode/gulp-electron. Skipping patch." >&2
    fi
  else
    echo "@vscode/gulp-electron already patched for ESM compatibility." >&2
  fi
fi

# Install extension dependencies
# Extensions have their own package.json files and need dependencies installed
echo "Installing extension dependencies..."
if [[ -d "extensions" ]]; then
  # Find all extensions with package.json files
  find extensions -name "package.json" -type f | while read -r ext_package_json; do
    ext_dir=$(dirname "$ext_package_json")
    # Skip if node_modules already exists (already installed)
    if [[ ! -d "${ext_dir}/node_modules" ]]; then
      echo "Installing dependencies for extension: ${ext_dir}..." >&2
      (cd "$ext_dir" && npm install --no-save 2>&1 | tail -30) || {
        echo "Warning: Failed to install dependencies for ${ext_dir}" >&2
      }
    fi
  done
fi

# Note: Extension webpack config patch is now in build.sh after compile-build-without-mangling
# because build/lib/extensions.js is created during TypeScript compilation

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

setpath "product" "checksumFailMoreInfoUrl" "https://cortexide.com"
setpath "product" "documentationUrl" "https://cortexide.com"
setpath "product" "introductoryVideosUrl" "https://cortexide.com"
setpath "product" "keyboardShortcutsUrlLinux" "https://cortexide.com/docs"
setpath "product" "keyboardShortcutsUrlMac" "https://cortexide.com/docs"
setpath "product" "keyboardShortcutsUrlWin" "https://cortexide.com/docs"
setpath "product" "licenseUrl" "https://github.com/cortexide/cortexide/blob/main/LICENSE.txt"
setpath_json "product" "linkProtectionTrustedDomains" '["https://open-vsx.org", "https://opencortexide.com", "https://github.com/opencortexide"]'
setpath "product" "reportIssueUrl" "https://github.com/cortexide/cortexide/issues/new"
setpath "product" "requestFeatureUrl" "https://github.com/cortexide/cortexide/issues/new"
setpath "product" "tipsAndTricksUrl" "https://cortexide.com/docs"
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

# Merge CortexIDE product.json (this may override some settings, so we re-apply critical overrides after)
jsonTmp=$( jq -s '.[0] * .[1]' product.json ../product.json )
echo "${jsonTmp}" > product.json && unset jsonTmp

# Validate product.json merge succeeded
if ! jq empty product.json 2>/dev/null; then
  echo "ERROR: product.json merge failed - file is invalid JSON!" >&2
  exit 1
fi

# CRITICAL: Override extensionsGallery AFTER merge to ensure Open VSX is used
# CortexIDE product.json has Microsoft Marketplace URLs that must be overridden
# Microsoft prohibits usage of their marketplace by other products
setpath_json "product" "extensionsGallery" '{"serviceUrl": "https://open-vsx.org/vscode/gallery", "itemUrl": "https://open-vsx.org/vscode/item"}'

# CRITICAL: Verify extensionsGallery was correctly set to Open VSX (not Microsoft Marketplace)
if ! jq -e '.extensionsGallery.serviceUrl | contains("open-vsx")' product.json >/dev/null 2>&1; then
  echo "ERROR: extensionsGallery.serviceUrl was not correctly set to Open VSX!" >&2
  echo "Current value: $(jq -r '.extensionsGallery.serviceUrl // "MISSING"' product.json)" >&2
  echo "This will cause extension marketplace failures and may violate Microsoft's terms." >&2
  exit 1
fi

# Verify extensionsGallery structure is complete
if ! jq -e '.extensionsGallery.itemUrl' product.json >/dev/null 2>&1; then
  echo "ERROR: extensionsGallery.itemUrl is missing!" >&2
  exit 1
fi

echo "✓ extensionsGallery correctly configured for Open VSX"

cat product.json

# package.json
cp package.json{,.bak}

# CRITICAL: Validate RELEASE_VERSION is set, otherwise fallback to package.json version
if [[ -z "${RELEASE_VERSION}" ]]; then
  echo "Warning: RELEASE_VERSION is not set, attempting to read from package.json..." >&2
  # Try to read version from package.json as fallback
  if [[ -f "package.json" ]]; then
    FALLBACK_VERSION=$( jq -r '.version' "package.json" 2>/dev/null || echo "" )
    if [[ -n "${FALLBACK_VERSION}" && "${FALLBACK_VERSION}" != "null" ]]; then
      RELEASE_VERSION="${FALLBACK_VERSION}"
      echo "Using fallback version from package.json: ${RELEASE_VERSION}" >&2
    else
      echo "Error: RELEASE_VERSION is not set and could not read version from package.json" >&2
      echo "This will cause a blank version in the built application." >&2
      exit 1
    fi
  else
    echo "Error: RELEASE_VERSION is not set and package.json not found" >&2
    exit 1
  fi
fi

# Remove -insider suffix if present for package.json version
PACKAGE_VERSION="${RELEASE_VERSION%-insider}"

# Validate the version is not empty after processing
if [[ -z "${PACKAGE_VERSION}" ]]; then
  echo "Error: Version is empty after processing RELEASE_VERSION: '${RELEASE_VERSION}'" >&2
  exit 1
fi

setpath "package" "version" "${PACKAGE_VERSION}"

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

# Fix TypeScript errors in cortexideCommandBarService.ts
# This handles both old code structure (patch expects) and new code structure (current cortexide)
echo "Fixing TypeScript errors in cortexideCommandBarService.ts..." >&2
TS_FILE="src/vs/workbench/contrib/cortexide/browser/cortexideCommandBarService.ts"
if [[ -f "${TS_FILE}" ]]; then
  echo "File found at: ${TS_FILE}" >&2
  echo "File size: $(wc -l < "${TS_FILE}") lines" >&2

  # Check which code structure we have
  HAS_OLD_STRUCTURE=false
  HAS_NEW_STRUCTURE=false

  if grep -q "private mountVoidCommandBar: Promise<" "${TS_FILE}" 2>/dev/null; then
    HAS_OLD_STRUCTURE=true
    echo "Detected OLD code structure (class property)" >&2
  fi

  if grep -q "mountVoidCommandBarPromise" "${TS_FILE}" 2>/dev/null || grep -q "getMountVoidCommandBar" "${TS_FILE}" 2>/dev/null; then
    HAS_NEW_STRUCTURE=true
    echo "Detected NEW code structure (module-level variable)" >&2
  fi

  if [[ "${HAS_NEW_STRUCTURE}" == "true" ]]; then
    echo "✓ Code uses new structure - no fixes needed (already has proper handling)" >&2
    # New structure already has proper null checks and async handling via getMountVoidCommandBar()
    # Check if there are any TypeScript errors we should be aware of
    if grep -q "await getMountVoidCommandBar" "${TS_FILE}" 2>/dev/null; then
      echo "✓ New structure uses await getMountVoidCommandBar() - properly handled" >&2
    fi
  elif [[ "${HAS_OLD_STRUCTURE}" == "true" ]]; then
    echo "Applying fixes for OLD code structure..." >&2

    # Fix 1: Property type declaration (line 9) - wrap in parentheses and add union
    if ! grep -q "| (() => void)" "${TS_FILE}" 2>/dev/null; then
      if perl -i.bak -0pe 's/(\t\t)\(rootElement: any, accessor: any, props: any\) => \{ rerender: \(props2: any\) => void; dispose: \(\) => void; \} \| undefined/$1((rootElement: any, accessor: any, props: any) => { rerender: (props2: any) => void; dispose: () => void; } | undefined) | (() => void)/s' "${TS_FILE}" 2>&1; then
        if grep -q "| (() => void)" "${TS_FILE}" 2>/dev/null; then
          echo "✓ Fixed property type declaration" >&2
        else
          echo "⚠ Property type fix ran but union not found" >&2
        fi
      else
        echo "⚠ Property type fix failed" >&2
      fi
    else
      echo "✓ Property type already has union" >&2
    fi

    # Fix 2: Any assignments that create Promise<...> types
    perl -i.bak2 -0pe 's/(as\s+Promise<)\s*\(rootElement: any, accessor: any, props: any\) => \{ rerender: \(props2: any\) => void; dispose: \(\) => void; \} \| undefined(\s*>)/$1((rootElement: any, accessor: any, props: any) => { rerender: (props2: any) => void; dispose: () => void; } | undefined) | (() => void)$2/s' "${TS_FILE}" 2>&1 && echo "✓ Fixed assignment types (if any)" >&2 || true

    # Fix 3: Line 572 - add null check and await
    if ! grep -q "if (this.mountVoidCommandBar)" "${TS_FILE}" 2>/dev/null; then
      if perl -i.bak3 -0pe 's/(\t+)mountVoidCommandBar\(rootElement, accessor, props\);/$1if (this.mountVoidCommandBar) {\n$1\t(await this.mountVoidCommandBar)(rootElement, accessor, props);\n$1}/' "${TS_FILE}" 2>&1; then
        if grep -q "if (this.mountVoidCommandBar)" "${TS_FILE}" 2>/dev/null; then
          echo "✓ Fixed function call at line 572" >&2
        else
          echo "⚠ Function call fix ran but null check not found" >&2
        fi
      else
        echo "⚠ Function call fix failed" >&2
      fi
    else
      echo "✓ Null check already present" >&2
    fi
  else
    echo "⚠ Could not determine code structure - checking for TypeScript errors..." >&2
    echo "  Showing relevant sections for debugging:" >&2
    echo "  Lines 30-45 (module level):" >&2
    sed -n '30,45p' "${TS_FILE}" 2>/dev/null | head -10 >&2 || true
    echo "  Lines 560-580 (function calls):" >&2
    sed -n '560,580p' "${TS_FILE}" 2>/dev/null | head -10 >&2 || true
    echo "  Searching for mountVoidCommandBar references:" >&2
    grep -n "mountVoidCommandBar" "${TS_FILE}" 2>/dev/null | head -5 >&2 || true
  fi

  echo "TypeScript fixes completed" >&2
else
  echo "✗ cortexideCommandBarService.ts not found at ${TS_FILE}, skipping fix" >&2
  echo "  Current directory: $(pwd)" >&2
  find . -name "cortexideCommandBarService.ts" -type f 2>/dev/null | head -3 >&2 || echo "  File not found anywhere" >&2
fi

# Old complex Node.js script removed - using simple perl fixes above
if false; then
  node << 'TYPESCRIPT_FIX' 2>&1
const fs = require('fs');
const filePath = 'src/vs/workbench/contrib/cortexide/browser/cortexideCommandBarService.ts';

try {
  let content = fs.readFileSync(filePath, 'utf8');
  let modified = false;
  const lines = content.split('\n');

  // Fix 1: Update property type declaration (lines 8-11)
  // Change: (rootElement: any, ...) => { ... } | undefined
  // To:     ((rootElement: any, ...) => { ... } | undefined) | (() => void)

  for (let i = 0; i < lines.length; i++) {
    // Find the property declaration line
    if (lines[i].includes('mountVoidCommandBar') && lines[i].includes('Promise<')) {
      // Find the type content line (next line should have the function type)
      if (i + 1 < lines.length && lines[i + 1].includes('rootElement')) {
        // Update line i+1 to wrap the type in parentheses and add union
        const typeLine = lines[i + 1].trim();
        if (!typeLine.includes('| (() => void)') && !typeLine.includes('(() => void)')) {
          // Wrap existing type in parentheses and add union
          const indent = lines[i + 1].match(/^(\s*)/)[1];
          lines[i + 1] = indent + '\t\t((rootElement: any, accessor: any, props: any) => { rerender: (props2: any) => void; dispose: () => void; } | undefined) | (() => void)';
          modified = true;
          console.error(`✓ Fixed property type declaration at line ${i + 2}`);
          break;
        }
      }
    }
  }

  // Find and update assignments - look for patterns like:
  // this.mountVoidCommandBar = ... as Promise<...>
  // this.mountVoidCommandBar = Promise.resolve(...) as Promise<...>
  // Or any assignment with a type assertion or annotation
  const assignmentPatterns = [
    // Pattern 1: Assignment with type assertion: = ... as Promise<...>
    /(this\.mountVoidCommandBar\s*=\s*[^=]*as\s+Promise<)([^>]+)(>)/g,
    // Pattern 2: Assignment with type annotation: = (): Promise<...> => ...
    /(this\.mountVoidCommandBar\s*=\s*\([^)]*\)\s*:\s*Promise<)([^>]+)(>\s*=>)/g,
    // Pattern 3: Direct assignment to Promise.resolve/Promise.reject with type
    /(this\.mountVoidCommandBar\s*=\s*Promise\.(resolve|reject)\([^)]*\)\s*as\s+Promise<)([^>]+)(>)/g,
  ];

  assignmentPatterns.forEach((pattern, idx) => {
    content = content.replace(pattern, (match, p1, p2, p3) => {
      const currentType = p2.trim();
      if (!currentType.includes('| (() => void)') && !currentType.includes('(() => void)')) {
        const newType = `(${currentType}) | (() => void)`;
        modified = true;
        console.error(`✓ Updated assignment type (pattern ${idx + 1})`);
        return p1 + newType + p3;
      }
      return match;
    });
  });

  // Also check line 35 specifically - the error is at line 35, so there might be an assignment there
  // The error suggests the property type was updated but an assignment still has the old type
  // Need to check multi-line assignments too
  if (lines.length >= 35) {
    const line35 = lines[34]; // 0-indexed
    console.error(`Line 35 content: ${line35}`);

    // Check if this is part of a multi-line assignment (check previous lines too)
    let assignmentStart = -1;
    for (let i = 33; i >= 0; i--) {
      if (lines[i].includes('this.mountVoidCommandBar') && lines[i].includes('=')) {
        assignmentStart = i;
        break;
      }
    }

    // If we found an assignment, check all lines from assignmentStart to line 35
    if (assignmentStart >= 0) {
      let assignmentLines = [];
      // Find where the assignment ends (look for semicolon or closing brace)
      let assignmentEnd = 34;
      for (let i = assignmentStart; i < Math.min(assignmentStart + 20, lines.length); i++) {
        assignmentLines.push(lines[i]);
        if (lines[i].includes(';') || (lines[i].includes('}') && i > assignmentStart)) {
          assignmentEnd = i;
          break;
        }
      }
      const assignmentText = assignmentLines.join('\n');
      console.error(`Found assignment starting at line ${assignmentStart + 1}, ending at ${assignmentEnd + 1}:`);
      console.error(assignmentText);

      // Look for Promise<...> type in the assignment that doesn't include the union
      // Use /s flag to match across newlines
      if (assignmentText.includes('Promise<') && !assignmentText.includes('| (() => void)')) {
        // Update the assignment - need to handle multi-line with /s flag
        const updatedAssignment = assignmentText.replace(
          /(Promise<\s*)([^>]+)(\s*>)/s,
          (match, p1, p2, p3) => {
            const typeContent = p2.trim();
            // Only update if it's the mount function type pattern
            if (!typeContent.includes('| (() => void)') &&
                !typeContent.includes('(() => void)') &&
                (typeContent.includes('rootElement') || typeContent.includes('rerender') || typeContent.includes('dispose'))) {
              return p1 + '(' + typeContent + ') | (() => void)' + p3;
            }
            return match;
          }
        );

        if (updatedAssignment !== assignmentText) {
          // Split back into lines and update
          const updatedLines = updatedAssignment.split('\n');
          for (let i = 0; i < updatedLines.length && (assignmentStart + i) < lines.length; i++) {
            lines[assignmentStart + i] = updatedLines[i];
          }
          modified = true;
          console.error('✓ Fixed type in multi-line assignment at line 35');
          console.error(`  Before: ${assignmentText.replace(/\n/g, '\\n')}`);
          console.error(`  After:  ${updatedAssignment.replace(/\n/g, '\\n')}`);
        }
      }
    } else {
      // Single line assignment check
      if (line35.includes('Promise<') && !line35.includes('| (() => void)')) {
        const updatedLine = line35.replace(
          /(Promise<)([^>]+)(>)/g,
          (match, p1, p2, p3) => {
            const typeContent = p2.trim();
            if (!typeContent.includes('| (() => void)') &&
                !typeContent.includes('(() => void)') &&
                (typeContent.includes('rootElement') || typeContent.includes('rerender') || typeContent.includes('dispose'))) {
              return p1 + '(' + typeContent + ') | (() => void)' + p3;
            }
            return match;
          }
        );
        if (updatedLine !== line35) {
          lines[34] = updatedLine;
          modified = true;
          console.error('✓ Fixed type at line 35');
          console.error(`  Before: ${line35.trim()}`);
          console.error(`  After:  ${updatedLine.trim()}`);
        }
      }
    }
  }

  // Fix 2: Add null check and await before calling mountVoidCommandBar at line 572
  // Look for the exact pattern around that line
  // First update content with lines array if we modified it above
  if (modified) {
    content = lines.join('\n');
  }

  const linesArray = content.split('\n');
  for (let i = 0; i < linesArray.length; i++) {
    const line = linesArray[i];
    const lineNum = i + 1;

    // Check if this is around line 572 and has the problematic call
    // Look for various patterns: mountVoidCommandBar(, this.mountVoidCommandBar(, or just the function name
    if ((lineNum >= 570 && lineNum <= 575) &&
        (line.includes('mountVoidCommandBar(') ||
         line.includes('mountVoidCommandBar(rootElement'))) {

      console.error(`Found problematic call at line ${lineNum}: ${line.trim()}`);

      // Check if already has null check (check previous 2 lines)
      const hasNullCheck = (i > 0 && linesArray[i - 1].includes('if (this.mountVoidCommandBar)')) ||
                           (i > 0 && linesArray[i - 1].includes('if (mountVoidCommandBar)')) ||
                           (i > 1 && linesArray[i - 2].includes('if (this.mountVoidCommandBar)')) ||
                           (i > 1 && linesArray[i - 2].includes('if (mountVoidCommandBar)'));

      if (!hasNullCheck) {
        // Get indentation from current line
        const indentMatch = line.match(/^(\s*)/);
        const indent = indentMatch ? indentMatch[1] : '';
        const tab = indent.includes('\t') ? '\t' : '  ';

        // Extract the function call - handle both this.mountVoidCommandBar and mountVoidCommandBar
        let funcCall = line.trim();
        if (funcCall.startsWith('mountVoidCommandBar(') || funcCall.startsWith('this.mountVoidCommandBar(')) {
          // Extract arguments - look for rootElement, accessor, props
          const argsMatch = line.match(/mountVoidCommandBar\s*\(([^)]+)\)/);
          const args = argsMatch ? argsMatch[1] : 'rootElement, accessor, props';

          // Replace the line with null check and await
          linesArray[i] = `${indent}if (this.mountVoidCommandBar) {\n${indent}${tab}(await this.mountVoidCommandBar)(${args});\n${indent}}`;
          modified = true;
          console.error(`✓ Added null check and await at line ${lineNum}`);
          console.error(`  Before: ${line.trim()}`);
          console.error(`  After:  ${linesArray[i].replace(/\n/g, '\\n')}`);
          break;
        }
      } else if (!line.includes('await')) {
        // Has null check but missing await
        const updatedLine = line.replace(
          /(this\.mountVoidCommandBar|mountVoidCommandBar)\s*\(/,
          '(await this.mountVoidCommandBar)('
        );
        if (updatedLine !== line) {
          linesArray[i] = updatedLine;
          modified = true;
          console.error(`✓ Added await at line ${lineNum}`);
          break;
        }
      }
    }
  }

  if (modified) {
    content = linesArray.join('\n');
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully fixed TypeScript errors');
  } else {
    console.error('⚠ No changes needed (fixes may already be applied)');
  }
} catch (error) {
  console.error('ERROR:', error.message);
  process.exit(1);
}
TYPESCRIPT_FIX
fi

cd ..
