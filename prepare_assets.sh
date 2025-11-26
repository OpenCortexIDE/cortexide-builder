#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"

mkdir -p assets

# Generate build identifier: short commit hash + timestamp
# This helps identify which build includes which fixes
BUILD_COMMIT_HASH=""
if [[ -d ".git" ]]; then
  BUILD_COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "")
fi
if [[ -z "${BUILD_COMMIT_HASH}" && -n "${GITHUB_SHA}" ]]; then
  BUILD_COMMIT_HASH=$(echo "${GITHUB_SHA}" | cut -c1-7)
fi
BUILD_TIMESTAMP=$(date +"%Y%m%d-%H%M%S" 2>/dev/null || echo "")
BUILD_ID=""
if [[ -n "${BUILD_COMMIT_HASH}" ]]; then
  BUILD_ID="-${BUILD_COMMIT_HASH}"
fi
if [[ -n "${BUILD_TIMESTAMP}" ]]; then
  BUILD_ID="${BUILD_ID}-${BUILD_TIMESTAMP}"
fi
export BUILD_ID

# Save BUILD_ID to a file for other scripts to use
echo "${BUILD_ID}" > assets/.build_id
echo "${BUILD_COMMIT_HASH}" > assets/.build_commit_hash
echo "${BUILD_TIMESTAMP}" > assets/.build_timestamp

if [[ "${OS_NAME}" == "osx" ]]; then
  if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
    if [[ "${CI_BUILD}" == "no" ]]; then
      RUNNER_TEMP="${TMPDIR}"
    fi

    CERTIFICATE_P12="${APP_NAME}.p12"
    KEYCHAIN="${RUNNER_TEMP}/buildagent.keychain"
    AGENT_TEMPDIRECTORY="${RUNNER_TEMP}"
    # shellcheck disable=SC2006
    KEYCHAINS=`security list-keychains | xargs`

    rm -f "${KEYCHAIN}"

    echo "${CERTIFICATE_OSX_P12_DATA}" | base64 --decode > "${CERTIFICATE_P12}"

    echo "+ create temporary keychain"
    security create-keychain -p pwd "${KEYCHAIN}"
    security set-keychain-settings -lut 21600 "${KEYCHAIN}"
    security unlock-keychain -p pwd "${KEYCHAIN}"
    # shellcheck disable=SC2086
    security list-keychains -s $KEYCHAINS "${KEYCHAIN}"
    # security show-keychain-info "${KEYCHAIN}"

    echo "+ import certificate to keychain"
    security import "${CERTIFICATE_P12}" -k "${KEYCHAIN}" -P "${CERTIFICATE_OSX_P12_PASSWORD}" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pwd "${KEYCHAIN}" > /dev/null
    # security find-identity "${KEYCHAIN}"

    CODESIGN_IDENTITY="$( security find-identity -v -p codesigning "${KEYCHAIN}" | grep -oEi "([0-9A-F]{40})" | head -n 1 )"

    echo "+ signing"
    export CODESIGN_IDENTITY AGENT_TEMPDIRECTORY

    # Increase file descriptor limit to prevent EMFILE errors during signing
    # The app bundle contains many files (especially in node_modules within extensions)
    # and electron-osx-sign needs to open many files simultaneously
    echo "+ increasing file descriptor limit for signing..."
    CURRENT_LIMIT=$(ulimit -n)
    echo "  Current limit: ${CURRENT_LIMIT}"
    TARGET_LIMITS=(65536 32768 20480 10240)
    LIMIT_SET="false"
    for TARGET_LIMIT in "${TARGET_LIMITS[@]}"; do
      if [[ "${TARGET_LIMIT}" -le "${CURRENT_LIMIT}" ]]; then
        continue
      fi
      if ulimit -n "${TARGET_LIMIT}" 2>/dev/null; then
        NEW_LIMIT=$(ulimit -n)
        echo "  ✓ Increased limit to: ${NEW_LIMIT}"
        LIMIT_SET="true"
        break
      fi
    done
    if [[ "${LIMIT_SET}" != "true" ]]; then
      echo "  ⚠ Warning: Could not increase file descriptor limit (may need sudo or system config)"
      echo "  Continuing with limit: $(ulimit -n)"
    fi

    # Fix sign.js to use dynamic import for @electron/osx-sign (ESM-only module)
    if [[ -f "vscode/build/darwin/sign.js" ]]; then
      echo "Fixing sign.js to use dynamic import for @electron/osx-sign..." >&2
      node << 'SIGNFIX' || {
const fs = require('fs');
const filePath = 'vscode/build/darwin/sign.js';
let content = fs.readFileSync(filePath, 'utf8');

let modified = false;

// Ensure sign.js installs graceful-fs globally to prevent EMFILE bursts
if (!content.includes('graceful_fs_1')) {
  const gracefulInsert = `const path_1 = __importDefault(require("path"));
const graceful_fs_1 = __importDefault(require("graceful-fs"));
graceful_fs_1.default.gracefulify(require("fs"));`;
  const originalPathImport = 'const path_1 = __importDefault(require("path"));';
  if (content.includes(originalPathImport)) {
    content = content.replace(originalPathImport, gracefulInsert);
    modified = true;
    console.error('✓ Added graceful-fs global patch to sign.js');
  } else {
    console.error('⚠ Warning: Could not find path import to insert graceful-fs patch');
  }
} else {
  console.error('sign.js already includes graceful-fs patch');
}

// Check if already fixed
if (content.includes('import("@electron/osx-sign")') || content.includes('const osx_sign_1 = await import')) {
  console.error('sign.js already uses dynamic import');
} else if (content.includes('require("@electron/osx-sign")')) {
  // Replace: const osx_sign_1 = require("@electron/osx-sign");
  // With: let osx_sign_1; (will be loaded dynamically)
  content = content.replace(
    /const osx_sign_1 = require\("@electron\/osx-sign"\);?/g,
    'let osx_sign_1;'
  );
  modified = true;

  // Find the main function and add dynamic import at the start
  // The main function is async, so we can use await
  if (content.includes('async function main(')) {
    // Add dynamic import at the start of main function
    // The import returns { sign, SignOptions }, so we need to extract sign
    content = content.replace(
      /(async function main\([^)]*\) \{)/,
      `$1\n    if (!osx_sign_1) {\n        const osxSignModule = await import("@electron/osx-sign");\n        osx_sign_1 = osxSignModule;\n    }`
    );
  }

  // The usage (0, osx_sign_1.sign) is fine - it's just calling the function
  // No need to change it since osx_sign_1 will have the sign property

  modified = true;
} else {
  console.error('Could not find require("@electron/osx-sign") in sign.js');
}

if (modified) {
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Fixed sign.js (graceful-fs + dynamic import)');
}
SIGNFIX
        echo "Warning: Failed to patch sign.js, trying to continue anyway..." >&2
      }
    fi

    DEBUG="electron-osx-sign*" node vscode/build/darwin/sign.js "$( pwd )"

    # Verify code signing succeeded
    echo "+ verifying code signature"
    cd "VSCode-darwin-${VSCODE_ARCH}"

    # Find the app bundle (should be only one)
    APP_BUNDLE=$( find . -maxdepth 1 -name "*.app" -type d | head -n 1 )
    if [[ -z "${APP_BUNDLE}" ]]; then
      echo "Error: No .app bundle found in VSCode-darwin-${VSCODE_ARCH}"
      ls -la
      exit 1
    fi

    # Normalize path (remove leading ./ if present)
    APP_BUNDLE="${APP_BUNDLE#./}"

    # Verify the app is properly signed
    echo "+ checking code signature validity..."
    if ! codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>&1; then
      echo "Error: Code signing verification failed - app is not properly signed"
      echo "Full codesign output:"
      codesign -dv --verbose=4 "${APP_BUNDLE}" 2>&1
      exit 1
    fi
    echo "✓ Code signature is valid"

    # Check signature details
    echo "+ checking signature details..."
    codesign -dv --verbose=4 "${APP_BUNDLE}" 2>&1 | head -n 5

    # Check for entitlements (non-fatal if missing)
    if codesign -d --entitlements :- "${APP_BUNDLE}" > /dev/null 2>&1; then
      echo "+ entitlements found"
    else
      echo "Warning: Could not extract entitlements (this may be normal)"
    fi

    # Verify architecture of key binaries
    echo "+ verifying binary architectures..."
    MAIN_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    if [[ -f "${MAIN_EXECUTABLE}" ]]; then
      EXEC_ARCH=$( file "${MAIN_EXECUTABLE}" | grep -oE "(x86_64|arm64)" | head -n 1 )
      if [[ "${VSCODE_ARCH}" == "x64" && "${EXEC_ARCH}" != "x86_64" ]]; then
        echo "Error: Main executable architecture mismatch. Expected x86_64, got ${EXEC_ARCH}"
        file "${MAIN_EXECUTABLE}"
        exit 1
      elif [[ "${VSCODE_ARCH}" == "arm64" && "${EXEC_ARCH}" != "arm64" ]]; then
        echo "Error: Main executable architecture mismatch. Expected arm64, got ${EXEC_ARCH}"
        file "${MAIN_EXECUTABLE}"
        exit 1
      fi
      echo "+ main executable architecture: ${EXEC_ARCH} ✓"
    else
      echo "Warning: Main executable not found at ${MAIN_EXECUTABLE}"
    fi

    # Check CLI binary architecture if it exists
    TUNNEL_APP_NAME=$( node -p "require('../../product.json').tunnelApplicationName" 2>/dev/null || echo "" )
    if [[ -n "${TUNNEL_APP_NAME}" ]]; then
      CLI_BINARY="${APP_BUNDLE}/Contents/Resources/app/bin/${TUNNEL_APP_NAME}"
      if [[ -f "${CLI_BINARY}" ]]; then
        CLI_ARCH=$( file "${CLI_BINARY}" | grep -oE "(x86_64|arm64)" | head -n 1 )
        if [[ "${VSCODE_ARCH}" == "x64" && "${CLI_ARCH}" != "x86_64" ]]; then
          echo "Error: CLI binary architecture mismatch. Expected x86_64, got ${CLI_ARCH}"
          file "${CLI_BINARY}"
          exit 1
        elif [[ "${VSCODE_ARCH}" == "arm64" && "${CLI_ARCH}" != "arm64" ]]; then
          echo "Error: CLI binary architecture mismatch. Expected arm64, got ${CLI_ARCH}"
          file "${CLI_BINARY}"
          exit 1
        fi
        echo "+ CLI binary architecture: ${CLI_ARCH} ✓"
      else
        echo "Warning: CLI binary not found at ${CLI_BINARY}"
      fi
    fi

    echo "✓ Code signing verified successfully"

    # Notarization is optional - only attempt if credentials are provided
    if [[ -n "${CERTIFICATE_OSX_ID}" ]] && [[ -n "${CERTIFICATE_OSX_TEAM_ID}" ]] && [[ -n "${CERTIFICATE_OSX_APP_PASSWORD}" ]]; then
    echo "+ notarize"

    ZIP_FILE="./${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip"

    # Create ZIP for notarization
    echo "+ creating ZIP archive for notarization..."
    if ! zip -r -X -y "${ZIP_FILE}" ./*.app; then
      echo "Error: Failed to create ZIP archive for notarization"
      exit 1
    fi

    # Store notarization credentials
      if ! xcrun notarytool store-credentials "${APP_NAME}" --apple-id "${CERTIFICATE_OSX_ID}" --team-id "${CERTIFICATE_OSX_TEAM_ID}" --password "${CERTIFICATE_OSX_APP_PASSWORD}" --keychain "${KEYCHAIN}" 2>&1; then
        echo "Warning: Failed to store notarization credentials - skipping notarization" >&2
        echo "App will be signed but not notarized. Users may need to right-click > Open on first launch." >&2
        rm -f "${ZIP_FILE}"
      else
    # Submit for notarization
    echo "+ submitting for notarization (this may take several minutes)..."
    NOTARIZATION_OUTPUT=$( xcrun notarytool submit "${ZIP_FILE}" --keychain-profile "${APP_NAME}" --wait --keychain "${KEYCHAIN}" 2>&1 )
    NOTARIZATION_EXIT_CODE=$?

    if [[ ${NOTARIZATION_EXIT_CODE} -ne 0 ]]; then
          echo "Warning: Notarization submission failed - app will be signed but not notarized" >&2
          echo "Users may need to right-click > Open on first launch." >&2
          echo "Notarization output: ${NOTARIZATION_OUTPUT}" >&2
          rm -f "${ZIP_FILE}"
        else
    # Check notarization status
    if echo "${NOTARIZATION_OUTPUT}" | grep -qi "status:.*Accepted"; then
      echo "✓ Notarization accepted"

    echo "+ attach staple"
    STAPLE_ATTEMPTS=0
    MAX_STAPLE_ATTEMPTS=3
    STAPLE_SUCCESS=false

    while [[ ${STAPLE_ATTEMPTS} -lt ${MAX_STAPLE_ATTEMPTS} ]]; do
      if xcrun stapler staple "${APP_BUNDLE}" 2>&1; then
        STAPLE_SUCCESS=true
        break
      else
        STAPLE_ATTEMPTS=$((STAPLE_ATTEMPTS + 1))
        if [[ ${STAPLE_ATTEMPTS} -lt ${MAX_STAPLE_ATTEMPTS} ]]; then
          echo "Warning: Stapling attempt ${STAPLE_ATTEMPTS} failed, retrying in 5 seconds..." >&2
          sleep 5
        fi
      fi
    done

    if [[ "${STAPLE_SUCCESS}" != "true" ]]; then
              echo "Warning: Failed to staple notarization ticket after ${MAX_STAPLE_ATTEMPTS} attempts" >&2
              echo "App is notarized but not stapled. Users may need to right-click > Open on first launch." >&2
            else
    # Verify stapling succeeded - retry on network errors
    echo "+ validating staple"
    VALIDATE_ATTEMPTS=0
    MAX_VALIDATE_ATTEMPTS=3
    VALIDATE_SUCCESS=false

    while [[ ${VALIDATE_ATTEMPTS} -lt ${MAX_VALIDATE_ATTEMPTS} ]]; do
      VALIDATE_OUTPUT=$(xcrun stapler validate "${APP_BUNDLE}" 2>&1)
      VALIDATE_EXIT_CODE=$?

      if [[ ${VALIDATE_EXIT_CODE} -eq 0 ]]; then
        VALIDATE_SUCCESS=true
        break
      else
        # Check if it's a network error (Error 68 or network-related errors)
        if echo "${VALIDATE_OUTPUT}" | grep -qiE "network connection|NSURLErrorDomain|Error 68|CloudKit|kCFErrorDomainCFNetwork"; then
          VALIDATE_ATTEMPTS=$((VALIDATE_ATTEMPTS + 1))
          if [[ ${VALIDATE_ATTEMPTS} -lt ${MAX_VALIDATE_ATTEMPTS} ]]; then
            echo "Warning: Validation failed due to network error (attempt ${VALIDATE_ATTEMPTS}/${MAX_VALIDATE_ATTEMPTS}), retrying in 10 seconds..." >&2
            echo "Error details: ${VALIDATE_OUTPUT}" >&2
            sleep 10
          else
            echo "Warning: Validation failed after ${MAX_VALIDATE_ATTEMPTS} attempts due to network errors" >&2
            echo "Notarization was successful, but validation could not complete due to network issues" >&2
            echo "This is often a transient Apple CloudKit service issue" >&2
            echo "The app should still work correctly since notarization succeeded" >&2
            VALIDATE_SUCCESS="network_error"
            break
          fi
        else
                    # Non-network error - warn but don't fail
                    echo "Warning: Stapling validation failed with non-network error" >&2
          echo "Output: ${VALIDATE_OUTPUT}" >&2
                    VALIDATE_SUCCESS="error"
                    break
        fi
      fi
    done

    if [[ "${VALIDATE_SUCCESS}" == "true" ]]; then
      echo "✓ Stapling verified successfully"
    elif [[ "${VALIDATE_SUCCESS}" == "network_error" ]]; then
      echo "⚠ Stapling validation skipped due to network errors (notarization succeeded)" >&2
    else
                echo "⚠ Stapling validation failed (notarization succeeded)" >&2
              fi
            fi
          elif echo "${NOTARIZATION_OUTPUT}" | grep -qi "status:.*Invalid"; then
            echo "Warning: Notarization was rejected - app will be signed but not notarized" >&2
            echo "Users may need to right-click > Open on first launch." >&2
            echo "Notarization output: ${NOTARIZATION_OUTPUT}" >&2
            rm -f "${ZIP_FILE}"
          else
            echo "Warning: Could not determine notarization status from output" >&2
            echo "App will be signed but notarization status is unknown." >&2
            echo "Notarization output: ${NOTARIZATION_OUTPUT}" >&2
            rm -f "${ZIP_FILE}"
          fi
        fi
      fi
    else
      echo "⚠ Notarization credentials not provided - skipping notarization" >&2
      echo "App will be signed but not notarized. Users may need to right-click > Open on first launch." >&2
    fi

    # Final verification: check Gatekeeper assessment (even without notarization)
    echo "+ final Gatekeeper verification"
    SPCTL_OUTPUT=$( spctl --assess --verbose "${APP_BUNDLE}" 2>&1 )
    SPCTL_EXIT_CODE=$?

    if [[ ${SPCTL_EXIT_CODE} -eq 0 ]]; then
      echo "✓ Gatekeeper assessment passed"
    else
      echo "⚠ Gatekeeper assessment failed or returned non-zero exit code" >&2
      echo "This is expected for non-notarized apps or self-signed certificates" >&2
      echo "Users will need to right-click > Open on first launch, or remove quarantine attribute" >&2
      echo "Output: ${SPCTL_OUTPUT}" >&2
    fi

    cd ..
  fi

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    echo "Building and moving ZIP"
    cd "VSCode-darwin-${VSCODE_ARCH}"
    ZIP_NAME="${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}${BUILD_ID}.zip"
    echo "Creating ZIP: ${ZIP_NAME} (includes fixes from commit ${BUILD_COMMIT_HASH:-unknown})"
    if ! zip -r -X -y "../assets/${ZIP_NAME}" ./*.app; then
      echo "Error: Failed to create ZIP archive: ${ZIP_NAME}" >&2
      echo "  This may be due to:" >&2
      echo "  - Disk space issues" >&2
      echo "  - File permission issues" >&2
      echo "  - App bundle too large" >&2
      cd ..
      exit 1
    fi
    echo "✓ ZIP archive created successfully: ${ZIP_NAME}"
    cd ..
  fi

  if [[ "${SHOULD_BUILD_DMG}" != "no" ]]; then
    echo "Building and moving DMG"
    pushd "VSCode-darwin-${VSCODE_ARCH}"
    
    # Create a Gatekeeper fix script that users can run if they see "damaged" error
    cat > "Fix Gatekeeper Issue.command" << 'GATEKEEPER_FIX'
#!/bin/bash
# Quick fix for "CortexIDE is damaged" error
# This removes the macOS Gatekeeper quarantine attribute

echo "Fixing Gatekeeper issue..."
APP_NAME=$(find . -maxdepth 1 -name "*.app" -type d | head -1 | xargs basename)

if [[ -z "${APP_NAME}" ]]; then
    echo "Error: App bundle not found in this directory"
    exit 1
fi

APP_PATH="./${APP_NAME}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Error: App bundle not found: ${APP_PATH}"
    exit 1
fi

echo "Removing quarantine attribute from ${APP_NAME}..."
if xattr -l "${APP_PATH}" 2>/dev/null | grep -q "com.apple.quarantine"; then
    xattr -rd com.apple.quarantine "${APP_PATH}" 2>/dev/null || {
        echo "Note: You may need to enter your password"
        sudo xattr -rd com.apple.quarantine "${APP_PATH}" || {
            echo "Error: Failed to remove quarantine attribute"
            echo ""
            echo "Alternative: Right-click the app and select 'Open'"
            exit 1
        }
    }
    echo "✓ Quarantine attribute removed"
else
    echo "No quarantine attribute found (app may already be allowed)"
fi

echo ""
echo "✓ Done! You can now open ${APP_NAME}"
echo ""
echo "If you still see 'damaged' error:"
echo "  1. Right-click the app > Open"
echo "  2. Or go to System Settings > Privacy & Security > Allow app"
GATEKEEPER_FIX
    chmod +x "Fix Gatekeeper Issue.command"
    
    # Create a README with instructions
    cat > "README.txt" << 'README'
CortexIDE Installation Instructions
====================================

1. Drag CortexIDE.app to your Applications folder

2. If you see "CortexIDE is damaged and can't be opened":
   - Double-click "Fix Gatekeeper Issue.command" in this window, OR
   - Right-click CortexIDE.app > Open, OR
   - Run: xattr -rd com.apple.quarantine /Applications/CortexIDE.app

3. Launch CortexIDE from Applications

For more help, visit: https://opencortexide.com
README
    
    # Remove any existing quarantine attributes before creating DMG
    # This prevents the DMG from inheriting quarantine
    echo "+ removing quarantine attributes before DMG creation..."
    if xattr -l ./*.app 2>/dev/null | grep -q "com.apple.quarantine"; then
      if xattr -rd com.apple.quarantine ./*.app 2>/dev/null; then
        # Verify removal succeeded
        if xattr -l ./*.app 2>/dev/null | grep -q "com.apple.quarantine"; then
          echo "  ⚠ Warning: Failed to remove all quarantine attributes (some files may be read-only)" >&2
        else
          echo "  ✓ Removed quarantine attributes from app bundle"
        fi
      else
        echo "  ⚠ Warning: Failed to remove quarantine attributes (files may be read-only)" >&2
      fi
    else
      echo "  ✓ No quarantine attributes found on app bundle"
    fi
    
    if [[ -n "${CODESIGN_IDENTITY}" ]]; then
      npx create-dmg ./*.app .
    else
      npx create-dmg --no-code-sign ./*.app .
    fi
    
    # After DMG creation, remove quarantine from DMG itself if it was added
    DMG_FILE=$(find . -maxdepth 1 -name "*.dmg" -type f | head -1)
    if [[ -n "${DMG_FILE}" ]]; then
      if xattr -l "${DMG_FILE}" 2>/dev/null | grep -q "com.apple.quarantine"; then
        echo "+ removing quarantine from DMG file..."
        if xattr -d com.apple.quarantine "${DMG_FILE}" 2>/dev/null; then
          # Verify removal succeeded
          if xattr -l "${DMG_FILE}" 2>/dev/null | grep -q "com.apple.quarantine"; then
            echo "  ⚠ Warning: Failed to remove quarantine from DMG file" >&2
            echo "  Users may need to run: xattr -d com.apple.quarantine ${DMG_FILE}" >&2
          else
            echo "  ✓ DMG quarantine removed"
          fi
        else
          echo "  ⚠ Warning: Failed to remove quarantine from DMG file" >&2
          echo "  Users may need to run: xattr -d com.apple.quarantine ${DMG_FILE}" >&2
        fi
      else
        echo "  ✓ No quarantine found on DMG file"
      fi
    else
      echo "  ⚠ Warning: DMG file not found after creation" >&2
    fi
    
    DMG_NAME="${APP_NAME}.${VSCODE_ARCH}.${RELEASE_VERSION}${BUILD_ID}.dmg"
    echo "Renaming DMG: ${DMG_NAME} (includes fixes from commit ${BUILD_COMMIT_HASH:-unknown})"
    mv ./*.dmg "../assets/${DMG_NAME}"
    popd
  fi

  if [[ "${SHOULD_BUILD_SRC}" == "yes" ]]; then
    git archive --format tar.gz --output="./assets/${APP_NAME}-${RELEASE_VERSION}-src.tar.gz" HEAD
    git archive --format zip --output="./assets/${APP_NAME}-${RELEASE_VERSION}-src.zip" HEAD
  fi

  if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
    echo "+ clean"
    security delete-keychain "${KEYCHAIN}"
    # shellcheck disable=SC2086
    security list-keychains -s $KEYCHAINS
  fi

  VSCODE_PLATFORM="darwin"
elif [[ "${OS_NAME}" == "windows" ]]; then
  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  # CRITICAL FIX: Patch InnoSetup code.iss to escape PowerShell curly braces
  # Inno Setup interprets { and } as its own constants, so PowerShell code blocks need escaping
  if [[ -f "build/win32/code.iss" ]]; then
    echo "Patching InnoSetup code.iss to escape PowerShell curly braces..." >&2
    node << 'POWERSHELLESCAPEFIX' || {
const fs = require('fs');
const filePath = 'build/win32/code.iss';

try {
  let content = fs.readFileSync(filePath, 'utf8');
  const originalContent = content;
  let modified = false;

  // Find [Run] section
  const runSectionMatch = content.match(/\[Run\][\s\S]*?(?=\[|$)/m);
  if (runSectionMatch) {
    const runSection = runSectionMatch[0];
    let newRunSection = runSection;
    const originalRunSection = runSection;

    // CRITICAL FIX: First, normalize any already-escaped braces to prevent double-escaping
    // Un-escape any existing {{ and }} to { and } so we can start fresh
    newRunSection = newRunSection.replace(/\{\{/g, '{').replace(/\}\}/g, '}');
    
    // Step 1: Build comprehensive list of Inno Setup constants and functions
    // Extract all Inno Setup function calls (pattern: {identifier:...})
    const innoFunctionPattern = /\{[a-zA-Z_][a-zA-Z0-9_]*:[^}]*\}/g;
    const innoFunctions = [];
    let match;
    while ((match = innoFunctionPattern.exec(newRunSection)) !== null) {
      if (!innoFunctions.includes(match[0])) {
        innoFunctions.push(match[0]);
      }
    }
    
    // Build complete list of constants (order matters - longer ones first)
    const constants = [
      // Function calls (longer patterns first)
      ...innoFunctions,
      // Standard constants
      '{code:GetShellFolderPath|0}',
      '{code:GetShellFolderPath}',
      '{uninst:GetUninstallString}',
      '{uninst:GetUninstallString|0}',
      // Standard directory constants
      '{tmp}', '{app}', '{sys}', '{pf}', '{cf}', '{cf32}', '{cf64}',
      '{userdocs}', '{commondocs}', '{userappdata}', '{commonappdata}', 
      '{localappdata}', '{sendto}', '{startmenu}', '{startup}', 
      '{desktop}', '{fonts}', '{group}', '{reg}', '{autopf}', '{autoappdata}',
      // Special constants
      '{src}', '{sd}', '{drive}', '{computername}', '{username}', '{winsysdir}',
      '{syswow64}', '{sysnative}', '{sysuserinfopath}', '{commonfiles}',
      '{commonfiles32}', '{commonfiles64}', '{#VERSION}', '{#VERSION_MAJOR}',
      '{#VERSION_MINOR}', '{#VERSION_BUILD}'
    ];
    
    // Remove duplicates while preserving order
    const uniqueConstants = [];
    const seen = new Set();
    for (const constant of constants) {
      if (!seen.has(constant)) {
        seen.add(constant);
        uniqueConstants.push(constant);
      }
    }
    
    // Step 2: Replace Inno Setup constants with placeholders
    const placeholders = {};
    uniqueConstants.forEach((constant, idx) => {
      const placeholder = `__INNO_CONST_${idx}__`;
      placeholders[placeholder] = constant;
      // Escape special regex characters
      const escaped = constant.replace(/[{}()\[\]\\^$.*+?|]/g, '\\$&');
      const regex = new RegExp(escaped, 'g');
      const beforeReplace = newRunSection;
      newRunSection = newRunSection.replace(regex, placeholder);
      if (beforeReplace !== newRunSection) {
        console.error(`  Protected Inno Setup constant: ${constant}`);
      }
    });

    // Step 3: Escape all remaining { and } (these belong to PowerShell)
    const beforeEscape = newRunSection;
    newRunSection = newRunSection.replace(/\{/g, '{{').replace(/\}/g, '}}');
    if (beforeEscape !== newRunSection) {
      console.error('  Escaped PowerShell curly braces');
    }

    // Step 4: Restore Inno Setup constants from placeholders
    // Process in reverse order to avoid conflicts with shorter patterns
    Object.keys(placeholders).reverse().forEach(placeholder => {
      const constant = placeholders[placeholder];
      const escapedPlaceholder = placeholder.replace(/[()\[\]\\^$.*+?|]/g, '\\$&');
      const regex = new RegExp(escapedPlaceholder, 'g');
      newRunSection = newRunSection.replace(regex, constant);
    });

    if (newRunSection !== originalRunSection) {
      content = content.replace(originalRunSection, newRunSection);
      modified = true;
      console.error('✓ Successfully escaped PowerShell curly braces in [Run] section');
      
      // Debug: Show line 114 if it exists
      const lines = content.split(/\r?\n/);
      if (lines.length >= 114) {
        console.error(`  Line 114: ${lines[113].substring(0, 100)}...`);
      }
    } else {
      console.error('⚠ No changes made to [Run] section');
    }
  } else {
    console.error('⚠ [Run] section not found in code.iss');
  }

  if (modified) {
    // Preserve original line endings (CRLF for Windows files)
    const hasCRLF = originalContent.includes('\r\n');
    const lineEnding = hasCRLF ? '\r\n' : '\n';
    
    // Ensure file ends with newline
    if (!content.endsWith(lineEnding)) {
      content += lineEnding;
    }
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Saved patched code.iss file');
  } else {
    console.error('⚠ No PowerShell escaping needed or [Run] section not found');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
}
POWERSHELLESCAPEFIX
      echo "Warning: Failed to patch code.iss for PowerShell escaping, continuing anyway..." >&2
    }
  fi

  # CRITICAL FIX: Patch InnoSetup code.iss to conditionally include AppX file
  # If AppX building was skipped (win32ContextMenu missing), the AppX file won't exist
  # and InnoSetup will fail. Make the AppX file reference conditional.
  if [[ -f "build/win32/code.iss" ]]; then
    echo "Patching InnoSetup code.iss to conditionally include AppX file..." >&2
    node << 'INNOSETUPFIX' || {
const fs = require('fs');
const path = require('path');
const filePath = 'build/win32/code.iss';

try {
  let content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  let modified = false;

  // Check if AppX file exists
  const arch = process.env.VSCODE_ARCH || 'x64';
  const appxDir = path.join('..', 'VSCode-win32-' + arch, 'appx');
  const appxFile = path.join(appxDir, `code_${arch}.appx`);
  const appxExists = fs.existsSync(appxFile);

  console.error(`Checking for AppX file: ${appxFile}`);
  console.error(`AppX file exists: ${appxExists}`);

  if (!appxExists) {
    console.error(`AppX file not found: ${appxFile}, making AppX reference conditional...`);
    console.error(`Searching for AppX references in code.iss (total lines: ${lines.length})...`);

    // Find lines that reference the AppX file (around line 99 based on error)
    // Be VERY aggressive - comment out ANY line in [Files] section that mentions appx
    // But be careful with #ifdef blocks - comment out the entire block
    let inFilesSection = false;
    let inAppxIfdef = false;
    let ifdefStartLine = -1;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Track if we're in the [Files] section
      if (trimmed.startsWith('[Files]')) {
        inFilesSection = true;
        console.error(`Found [Files] section at line ${i + 1}`);
        continue;
      }
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inFilesSection = false;
        continue;
      }

      // Track #ifdef blocks related to AppX
      // We need to handle these specially - don't comment out the #ifdef/#endif themselves
      // Instead, we'll set a flag to comment out the content inside
      if (trimmed.startsWith('#ifdef') && trimmed.toLowerCase().includes('appx')) {
        inAppxIfdef = true;
        ifdefStartLine = i;
        console.error(`Found AppX #ifdef block starting at line ${i + 1}`);
        // Don't comment out the #ifdef line itself - keep it but make it always false
        // Change #ifdef AppxPackageName to #if 0 (always false)
        if (trimmed.includes('AppxPackageName') || trimmed.includes('AppxPackage')) {
          const indent = line.match(/^\s*/)[0];
          // Split into two lines properly
          lines[i] = `${indent}#if 0 ; PATCHED: AppX not available, disabled`;
          lines.splice(i + 1, 0, `${indent}; Original: ${trimmed}`);
          i++; // Adjust index since we inserted a line
          modified = true;
        }
        continue;
      }

      // Track #endif for AppX blocks
      if (inAppxIfdef && trimmed.startsWith('#endif')) {
        // Comment out the content inside the block (but keep #endif)
        for (let j = ifdefStartLine + 1; j < i; j++) {
          if (!lines[j].trim().startsWith(';') && !lines[j].trim().startsWith('#')) {
            const indent = lines[j].match(/^\s*/)[0];
            // Split into two lines properly - add comment line, then commented original
            const originalLine = lines[j].substring(indent.length);
            lines[j] = `${indent}; PATCHED: AppX block content commented out`;
            lines.splice(j + 1, 0, `${indent};${originalLine}`);
            i++; // Adjust index since we inserted a line
          }
        }
        modified = true;
        console.error(`✓ Commented out AppX #ifdef block content from line ${ifdefStartLine + 2} to ${i}`);
        inAppxIfdef = false;
        ifdefStartLine = -1;
        continue;
      }

      // Skip already commented lines
      if (trimmed.startsWith(';')) {
        continue;
      }

      // In [Files] section, comment out ANY line that mentions appx (case insensitive)
      // But skip if we're inside an #ifdef block (we'll handle the whole block)
      // Also skip Excludes lines - they're just patterns, not actual file references
      if (inFilesSection && !inAppxIfdef) {
        const lowerLine = line.toLowerCase();
        // Skip Excludes lines - they contain "appx" as a pattern but aren't file references
        if (lowerLine.includes('appx') && !lowerLine.includes('excludes')) {
          const indent = line.match(/^\s*/)[0];
          const originalLine = line.substring(indent.length);
          // Split into two lines properly - add comment line, then commented original
          lines[i] = `${indent}; PATCHED: AppX file not found, commented out`;
          lines.splice(i + 1, 0, `${indent};${originalLine}`);
          i++; // Adjust index since we inserted a line
          modified = true;
          console.error(`✓ Commented out AppX reference at line ${i}: ${trimmed.substring(0, 80)}`);
        }
      }

      // Also check outside [Files] section for any .appx references (but not in #ifdef blocks)
      if (!inAppxIfdef) {
        const lowerLine = line.toLowerCase();
        if (lowerLine.includes('.appx') && !trimmed.startsWith(';')) {
          const indent = line.match(/^\s*/)[0];
          const originalLine = line.substring(indent.length);
          // Split into two lines properly - add comment line, then commented original
          lines[i] = `${indent}; PATCHED: AppX file not found, commented out`;
          lines.splice(i + 1, 0, `${indent};${originalLine}`);
          i++; // Adjust index since we inserted a line
          modified = true;
          console.error(`✓ Commented out .appx reference at line ${i}: ${trimmed.substring(0, 80)}`);
        }
      }
    }

    if (!modified) {
      console.error('⚠ WARNING: No AppX references found to patch!');
      console.error('Showing lines around line 99 for debugging:');
      for (let i = Math.max(0, 94); i < Math.min(lines.length, 104); i++) {
        console.error(`Line ${i + 1}: ${lines[i]}`);
      }
    }
  } else {
    console.error(`✓ AppX file found: ${appxFile}, no patching needed`);
  }

  if (modified) {
    // Preserve original line endings (CRLF for Windows files)
    const originalContent = fs.readFileSync(filePath, 'utf8');
    const hasCRLF = originalContent.includes('\r\n');
    const lineEnding = hasCRLF ? '\r\n' : '\n';

    content = lines.join(lineEnding);
    // Ensure file ends with newline (Inno Setup can be sensitive to this)
    if (!content.endsWith(lineEnding)) {
      content += lineEnding;
    }
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully patched code.iss to handle missing AppX file');

    // Validate the file has proper structure - check for common issues
    const runSectionMatch = content.match(/\[Run\][\s\S]*?(?=\[|$)/m);
    if (runSectionMatch) {
      const runSection = runSectionMatch[0];
      // Check for unclosed quotes in [Run] section
      const quoteCount = (runSection.match(/"/g) || []).length;
      if (quoteCount % 2 !== 0) {
        console.error('⚠ WARNING: Odd number of quotes in [Run] section - this may cause parsing errors!');
        console.error('  This could indicate a quote escaping issue in the PowerShell commands.');
      }
      // Check for very long lines (Inno Setup has limits)
      const longLines = runSection.split(/\r?\n/).filter(line => line.length > 1000);
      if (longLines.length > 0) {
        console.error(`⚠ WARNING: Found ${longLines.length} very long lines in [Run] section (may cause issues)`);
        longLines.forEach((line, idx) => {
          console.error(`  Line ${idx + 1}: ${line.substring(0, 100)}... (${line.length} chars)`);
        });
      }
    }
  } else if (!appxExists) {
    console.error('⚠ Warning: AppX file not found but no references were patched. The build may fail.');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
}
INNOSETUPFIX
      echo "Warning: Failed to patch code.iss, InnoSetup may fail if AppX file is missing" >&2
    }
  fi

  npm run gulp "vscode-win32-${VSCODE_ARCH}-inno-updater"

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    7z.exe a -tzip "../assets/${APP_NAME}-win32-${VSCODE_ARCH}-${RELEASE_VERSION}${BUILD_ID}.zip" -x!CodeSignSummary*.md -x!tools "../VSCode-win32-${VSCODE_ARCH}/*" -r
  fi

  # CRITICAL FIX: Patch code.iss again before system-setup/user-setup tasks
  # The inno-updater task may have regenerated or modified code.iss, so we need to patch it again
  # This is CRITICAL - without this patch, system-setup will fail with InnoSetup parsing errors
  echo "Checking for code.iss before system-setup/user-setup tasks..." >&2
  if [[ -f "build/win32/code.iss" ]]; then
    echo "Found code.iss, patching PowerShell curly braces..." >&2

    patch_code_iss_again() {
node <<'POWERSHELLESCAPEFIX2'
const fs = require('fs');
const path = require('path');
const filePath = 'build/win32/code.iss';

try {
  if (!fs.existsSync(filePath)) {
    console.error(`✗ ERROR: code.iss not found at ${filePath}`);
    process.exit(1);
  }

  let content = fs.readFileSync(filePath, 'utf8');
  const originalContent = content;
  let modified = false;

  // Find [Run] section
  const runSectionMatch = content.match(/\[Run\][\s\S]*?(?=\[|$)/m);
  if (!runSectionMatch) {
    console.error('✗ ERROR: [Run] section not found in code.iss');
    process.exit(1);
  }

  const runSection = runSectionMatch[0];
  let newRunSection = runSection;
  const originalRunSection = runSection;

  // CRITICAL FIX: First, normalize any already-escaped braces to prevent double-escaping
  // Un-escape any existing {{ and }} to { and } so we can start fresh
  newRunSection = newRunSection.replace(/\{\{/g, '{').replace(/\}\}/g, '}');
  
  // Step 1: Build comprehensive list of Inno Setup constants and functions
  // This includes all standard constants plus function calls like {code:...}
  // We need to match these patterns:
  // - Simple constants: {app}, {tmp}, etc.
  // - Function calls: {code:FunctionName|param}, {uninst:FunctionName|param}
  // - Constants with parameters: {code:GetShellFolderPath|0}
  
  // First, extract all Inno Setup function calls (pattern: {identifier:...})
  const innoFunctionPattern = /\{[a-zA-Z_][a-zA-Z0-9_]*:[^}]*\}/g;
  const innoFunctions = [];
  let match;
  while ((match = innoFunctionPattern.exec(newRunSection)) !== null) {
    if (!innoFunctions.includes(match[0])) {
      innoFunctions.push(match[0]);
    }
  }
  
  // Build complete list of constants (order matters - longer ones first)
  const constants = [
    // Function calls (longer patterns first)
    ...innoFunctions,
    // Standard constants
    '{code:GetShellFolderPath|0}',
    '{code:GetShellFolderPath}',
    '{uninst:GetUninstallString}',
    '{uninst:GetUninstallString|0}',
    // Standard directory constants
    '{tmp}', '{app}', '{sys}', '{pf}', '{cf}', '{cf32}', '{cf64}',
    '{userdocs}', '{commondocs}', '{userappdata}', '{commonappdata}', 
    '{localappdata}', '{sendto}', '{startmenu}', '{startup}', 
    '{desktop}', '{fonts}', '{group}', '{reg}', '{autopf}', '{autoappdata}',
    // Special constants
    '{src}', '{sd}', '{drive}', '{computername}', '{username}', '{winsysdir}',
    '{syswow64}', '{sysnative}', '{sysuserinfopath}', '{commonfiles}',
    '{commonfiles32}', '{commonfiles64}', '{#VERSION}', '{#VERSION_MAJOR}',
    '{#VERSION_MINOR}', '{#VERSION_BUILD}'
  ];
  
  // Remove duplicates while preserving order
  const uniqueConstants = [];
  const seen = new Set();
  for (const constant of constants) {
    if (!seen.has(constant)) {
      seen.add(constant);
      uniqueConstants.push(constant);
    }
  }
  
  // Step 2: Replace Inno Setup constants with placeholders
  const placeholders = {};
  uniqueConstants.forEach((constant, idx) => {
    const placeholder = `__INNO_CONST_${idx}__`;
    placeholders[placeholder] = constant;
    // Escape special regex characters
    const escaped = constant.replace(/[{}()\[\]\\^$.*+?|]/g, '\\$&');
    const regex = new RegExp(escaped, 'g');
    const beforeReplace = newRunSection;
    newRunSection = newRunSection.replace(regex, placeholder);
    if (beforeReplace !== newRunSection) {
      console.error(`  Protected Inno Setup constant: ${constant}`);
    }
  });

  // Step 3: Escape all remaining { and } (these belong to PowerShell)
  const beforeEscape = newRunSection;
  newRunSection = newRunSection.replace(/\{/g, '{{').replace(/\}/g, '}}');
  if (beforeEscape !== newRunSection) {
    console.error('  Escaped PowerShell curly braces');
  }

  // Step 4: Restore Inno Setup constants from placeholders
  // Process in reverse order to avoid conflicts with shorter patterns
  Object.keys(placeholders).reverse().forEach(placeholder => {
    const constant = placeholders[placeholder];
    const escapedPlaceholder = placeholder.replace(/[()\[\]\\^$.*+?|]/g, '\\$&');
    const regex = new RegExp(escapedPlaceholder, 'g');
    newRunSection = newRunSection.replace(regex, constant);
  });

  // CRITICAL FIX: After restoring constants, check for PowerShell code blocks that still need escaping
  // The issue is that PowerShell code in Parameters fields has { } that need to be {{ }}
  // but they might not have been caught if they're in complex quoted strings with Inno Setup constants
  // We need to find PowerShell commands and ensure all braces in the PowerShell code are escaped
  
  // Find all PowerShell Parameters fields - handle escaped quotes ("" inside the string)
  // Pattern: Parameters: "..." where ... can contain "" for escaped quotes
  // The field ends with """; (triple quotes - escaped quote followed by semicolon)
  const powershellParamsPattern = /(Parameters:\s*")((?:[^"]|"")*?)("";)/g;
  let paramMatch;
  let powershellFixed = false;
  const fixedParams = [];
  
  while ((paramMatch = powershellParamsPattern.exec(newRunSection)) !== null) {
    const fullMatch = paramMatch[0];
    const prefix = paramMatch[1]; // "Parameters: \""
    let paramContent = paramMatch[2]; // The actual PowerShell command (may contain "")
    const suffix = paramMatch[3]; // "\";"
    
    // Check if this PowerShell command contains [Net.ServicePointManager] or [Net.SecurityProtocolType]
    if (/\[Net\.(ServicePointManager|SecurityProtocolType)\]/.test(paramContent)) {
      // This is a PowerShell command that needs special handling
      // We need to escape braces in the PowerShell code, but NOT Inno Setup constants
      
      // First, protect Inno Setup constants in this parameter
      const paramPlaceholders = {};
      let paramContentProtected = paramContent;
      uniqueConstants.forEach((constant, idx) => {
        const placeholder = `__PARAM_INNO_${idx}__`;
        paramPlaceholders[placeholder] = constant;
        const escaped = constant.replace(/[{}()\[\]\\^$.*+?|]/g, '\\$&');
        const regex = new RegExp(escaped, 'g');
        paramContentProtected = paramContentProtected.replace(regex, placeholder);
      });
      
      // Now escape all remaining braces in the PowerShell code
      // Since we've already protected Inno Setup constants, all remaining braces are PowerShell
      // Just double them: { -> {{ and } -> }}
      // But first check if they're already escaped (avoid quadrupling)
      const originalProtected = paramContentProtected;
      // Replace single braces, but be smart about it
      // Use a regex that matches { not followed by {, and } not followed by }
      paramContentProtected = paramContentProtected.replace(/\{(?!\{)/g, '{{').replace(/\}(?!\})/g, '}}');
      
      // Restore Inno Setup constants
      Object.keys(paramPlaceholders).reverse().forEach(placeholder => {
        const constant = paramPlaceholders[placeholder];
        const escapedPlaceholder = placeholder.replace(/[()\[\]\\^$.*+?|]/g, '\\$&');
        const regex = new RegExp(escapedPlaceholder, 'g');
        paramContentProtected = paramContentProtected.replace(regex, constant);
      });
      
      // Check if we made changes
      if (paramContentProtected !== paramContent) {
        fixedParams.push({
          original: fullMatch,
          fixed: prefix + paramContentProtected + suffix
        });
        powershellFixed = true;
        console.error(`  Fixed PowerShell escaping in Parameters field (contains [Net.ServicePointManager])`);
      }
    }
  }
  
  // Apply all fixes
  if (powershellFixed) {
    fixedParams.forEach(({ original, fixed }) => {
      newRunSection = newRunSection.replace(original, fixed);
    });
    modified = true;
  }

  // Check if we made changes
  if (newRunSection !== originalRunSection || powershellFixed) {
    content = content.replace(originalRunSection, newRunSection);
    modified = true;
    console.error('✓ Successfully escaped PowerShell curly braces in [Run] section (before system-setup)');
  } else {
    console.error('⚠ No changes detected - file may already be correctly patched');
  }
  
  // Debug: Show line 114 if it exists (where the error occurs)
  const lines = content.split(/\r?\n/);
  if (lines.length >= 114) {
    const line114 = lines[113];
    console.error(`  Line 114: ${line114.substring(0, 150)}...`);
    // Check if line 114 has proper escaping
    if (line114.includes('{{') && line114.includes('}}')) {
      console.error('  ✓ Line 114 has proper PowerShell escaping');
    } else if (line114.includes('{') || line114.includes('}')) {
      // Check if it's an Inno Setup constant (which should have single braces)
      const hasInnoConstant = /\{[a-zA-Z_][a-zA-Z0-9_]*(:[^}]*)?\}/.test(line114);
      if (hasInnoConstant) {
        console.error('  ✓ Line 114 has Inno Setup constants (single braces are correct)');
      } else {
      console.error('  ⚠ Line 114 has single braces - may need escaping');
        console.error(`    Full line: ${line114}`);
      }
    }
  }
  
  // Validate PowerShell lines have proper escaping
  const powershellLines = lines
    .map((line, idx) => ({ line, idx: idx + 1 }))
    .filter(({ line }) => 
    line.includes('powershell.exe') && line.includes('Parameters')
  );
  
  powershellLines.forEach(({ line, idx }) => {
    // Check for PowerShell array syntax that needs escaping
    const needsEscaping = /\[Net\.(ServicePointManager|SecurityProtocolType)\]/.test(line);
    if (needsEscaping) {
      // Check if the brace before [Net. is properly escaped
      const braceBeforeNet = /(\{+)\s*\[Net\.(ServicePointManager|SecurityProtocolType)\]/;
      const match = line.match(braceBeforeNet);
      if (match && match[1].length >= 2) {
        console.error(`  ✓ PowerShell line ${idx} has proper escaping (${match[1].length} braces)`);
      } else if (match && match[1].length === 1) {
        console.error(`  ✗ ERROR: PowerShell line ${idx} has only single brace before [Net.`);
      console.error(`    Line content: ${line.substring(0, 200)}...`);
      } else {
        // Check if it's inside a quoted string - might need different handling
        const inQuotes = /Parameters:\s*"[^"]*\{[^}]*\[Net\./.test(line);
        if (inQuotes) {
          console.error(`  ⚠ PowerShell line ${idx} has [Net. inside quoted Parameters - checking...`);
        }
      }
    }
  });

  if (modified) {
    const hasCRLF = originalContent.includes('\r\n');
    const lineEnding = hasCRLF ? '\r\n' : '\n';
    if (!content.endsWith(lineEnding)) {
      content += lineEnding;
    }
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Saved patched code.iss file (before system-setup)');
    
    // Final validation: check for syntax errors
    const finalLines = content.split(/\r?\n/);
    const runSectionFinal = content.match(/\[Run\][\s\S]*?(?=\[|$)/m);
    if (runSectionFinal) {
      // Check for unmatched braces (excluding Inno Setup constants)
      const runContent = runSectionFinal[0];
      const innoBraces = (runContent.match(/\{[a-zA-Z_][a-zA-Z0-9_]*(:[^}]*)?\}/g) || []).length;
      const allBraces = (runContent.match(/\{/g) || []).length;
      const allCloseBraces = (runContent.match(/\}/g) || []).length;
      const escapedBraces = (runContent.match(/\{\{/g) || []).length;
      const escapedCloseBraces = (runContent.match(/\}\}/g) || []).length;
      
      console.error(`  Validation: Found ${innoBraces} Inno Setup constants, ${escapedBraces} escaped PowerShell braces`);
      if (allBraces !== allCloseBraces) {
        console.error(`  ⚠ WARNING: Unmatched braces detected (${allBraces} open, ${allCloseBraces} close)`);
      } else {
        console.error('  ✓ Braces are balanced');
      }
    }
  } else {
    console.error('⚠ No modifications made - file may already be correctly patched');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
}
POWERSHELLESCAPEFIX2
    }

    if ! patch_code_iss_again; then
      echo "ERROR: Failed to patch code.iss before system-setup. This will cause InnoSetup to fail!" >&2
      echo "Please check the error messages above." >&2
      exit 1
    fi
    
    # Final validation: Check that the file is readable and has valid structure
    echo "Validating patched code.iss file..." >&2
    if ! node << 'VALIDATEFIX' 2>&1; then
const fs = require('fs');
const filePath = 'build/win32/code.iss';

try {
  if (!fs.existsSync(filePath)) {
    console.error('✗ ERROR: code.iss not found after patching');
    process.exit(1);
  }
  
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split(/\r?\n/);
  
  // Check for [Run] section
  const hasRunSection = /\[Run\]/.test(content);
  if (!hasRunSection) {
    console.error('✗ ERROR: [Run] section not found in code.iss');
    process.exit(1);
  }
  
  // Check line 114 specifically (where the error occurs)
  if (lines.length >= 114) {
    const line114 = lines[113];
    console.error(`Line 114 content: ${line114.substring(0, 200)}`);
    
    // Check for obvious syntax errors
    if (line114.includes('{{{{') || line114.includes('}}}}')) {
      console.error('✗ ERROR: Double-escaped braces detected (quadruple braces) - this indicates a bug in the patching logic');
      process.exit(1);
    }
    
    // Check for unescaped PowerShell array syntax
    if (line114.includes('powershell') && /\[Net\.(ServicePointManager|SecurityProtocolType)\]/.test(line114)) {
      if (!line114.includes('{{ [Net.')) {
        console.error('✗ ERROR: PowerShell array syntax not properly escaped on line 114');
        console.error(`  Line: ${line114}`);
        process.exit(1);
      }
    }
  }
  
  // Check for balanced braces in [Run] section
  const runSectionMatch = content.match(/\[Run\][\s\S]*?(?=\[|$)/m);
  if (runSectionMatch) {
    const runSection = runSectionMatch[0];
    // Count Inno Setup constants (single braces)
    const innoConstants = (runSection.match(/\{[a-zA-Z_][a-zA-Z0-9_]*(:[^}]*)?\}/g) || []).length;
    // Count escaped PowerShell braces (double braces)
    const escapedBraces = (runSection.match(/\{\{/g) || []).length;
    const escapedCloseBraces = (runSection.match(/\}\}/g) || []).length;
    
    console.error(`Validation: Found ${innoConstants} Inno Setup constants, ${escapedBraces} escaped PowerShell braces`);
    
    if (escapedBraces !== escapedCloseBraces) {
      console.error(`✗ ERROR: Unmatched escaped braces in [Run] section (${escapedBraces} open, ${escapedCloseBraces} close)`);
      process.exit(1);
    }
  }
  
  console.error('✓ code.iss validation passed');
  process.exit(0);
} catch (error) {
  console.error(`✗ ERROR during validation: ${error.message}`);
  console.error(error.stack);
  process.exit(1);
}
VALIDATEFIX
      echo "ERROR: code.iss validation failed! The file may have syntax errors." >&2
      echo "This will likely cause InnoSetup to fail with exit code 2." >&2
      exit 1
    fi
    echo "✓ code.iss validation passed" >&2
else
    echo "ERROR: code.iss not found at build/win32/code.iss before system-setup task!" >&2
    echo "This is required for the system-setup build. Cannot continue." >&2
    exit 1
  fi

  if [[ "${SHOULD_BUILD_EXE_SYS}" != "no" ]]; then
    npm run gulp "vscode-win32-${VSCODE_ARCH}-system-setup"
  fi

  if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
    npm run gulp "vscode-win32-${VSCODE_ARCH}-user-setup"
  fi

  if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
    if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
      . ../build/windows/msi/build.sh
    fi

    if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
      . ../build/windows/msi/build-updates-disabled.sh
    fi
  fi

  cd ..

  if [[ "${SHOULD_BUILD_EXE_SYS}" != "no" ]]; then
    echo "Moving System EXE"
    mv "vscode\\.build\\win32-${VSCODE_ARCH}\\system-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}Setup-${VSCODE_ARCH}-${RELEASE_VERSION}${BUILD_ID}.exe"
  fi

  if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
    echo "Moving User EXE"
    mv "vscode\\.build\\win32-${VSCODE_ARCH}\\user-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}UserSetup-${VSCODE_ARCH}-${RELEASE_VERSION}${BUILD_ID}.exe"
  fi

  if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
    if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
      echo "Moving MSI"
      MSI_NAME="${APP_NAME}-${VSCODE_ARCH}-${RELEASE_VERSION}${BUILD_ID}.msi"
      mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-${RELEASE_VERSION}.msi" "assets/${MSI_NAME}"
      echo "Renamed MSI: ${MSI_NAME} (includes fixes from commit ${BUILD_COMMIT_HASH:-unknown})"
    fi

    if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
      echo "Moving MSI with disabled updates"
      MSI_NAME="${APP_NAME}-${VSCODE_ARCH}-updates-disabled-${RELEASE_VERSION}${BUILD_ID}.msi"
      mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-updates-disabled-${RELEASE_VERSION}.msi" "assets/${MSI_NAME}"
      echo "Renamed MSI: ${MSI_NAME} (includes fixes from commit ${BUILD_COMMIT_HASH:-unknown})"
    fi
  fi

  VSCODE_PLATFORM="win32"
else
  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" && "${VSCODE_ARCH}" != "x64" ]]; then
    SHOULD_BUILD_APPIMAGE="no"
  fi

  if [[ "${SHOULD_BUILD_DEB}" != "no" || "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
    npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-deb"
    npm run gulp "vscode-linux-${VSCODE_ARCH}-build-deb"
  fi

  if [[ "${SHOULD_BUILD_RPM}" != "no" ]]; then
    npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-rpm"
    npm run gulp "vscode-linux-${VSCODE_ARCH}-build-rpm"
  fi

  if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
    . ../build/linux/appimage/build.sh
  fi

  cd ..

  if [[ "${CI_BUILD}" == "no" ]]; then
    . ./stores/snapcraft/build.sh

    if [[ "${SKIP_ASSETS}" == "no" ]]; then
      mv stores/snapcraft/build/*.snap assets/
    fi
  fi

  if [[ "${SHOULD_BUILD_TAR}" != "no" ]]; then
    echo "Building and moving TAR"
    cd "VSCode-linux-${VSCODE_ARCH}"
    tar czf "../assets/${APP_NAME}-linux-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
    cd ..
  fi

  if [[ "${SHOULD_BUILD_DEB}" != "no" ]]; then
    echo "Moving DEB"
    mv vscode/.build/linux/deb/*/deb/*.deb assets/
  fi

  if [[ "${SHOULD_BUILD_RPM}" != "no" ]]; then
    echo "Moving RPM"
    mv vscode/.build/linux/rpm/*/*.rpm assets/
  fi

  if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
    echo "Moving AppImage"
    mv build/linux/appimage/out/*.AppImage* assets/

    find assets -name '*.AppImage*' -exec bash -c 'mv $0 ${0/_-_/-}' {} \;
  fi

  VSCODE_PLATFORM="linux"
fi

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building and moving REH"
  cd "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
  cd ..
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building and moving REH-web"
  cd "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"
  tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
  cd ..
fi

if [[ "${OS_NAME}" != "windows" ]]; then
  ./prepare_checksums.sh
fi
