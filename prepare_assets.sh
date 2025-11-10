#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"

mkdir -p assets

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

    echo "+ notarize"

    ZIP_FILE="./${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip"

    # Create ZIP for notarization
    echo "+ creating ZIP archive for notarization..."
    if ! zip -r -X -y "${ZIP_FILE}" ./*.app; then
      echo "Error: Failed to create ZIP archive for notarization"
      exit 1
    fi

    # Store notarization credentials
    if ! xcrun notarytool store-credentials "${APP_NAME}" --apple-id "${CERTIFICATE_OSX_ID}" --team-id "${CERTIFICATE_OSX_TEAM_ID}" --password "${CERTIFICATE_OSX_APP_PASSWORD}" --keychain "${KEYCHAIN}"; then
      echo "Error: Failed to store notarization credentials"
      exit 1
    fi
    
    # Submit for notarization
    echo "+ submitting for notarization (this may take several minutes)..."
    NOTARIZATION_OUTPUT=$( xcrun notarytool submit "${ZIP_FILE}" --keychain-profile "${APP_NAME}" --wait --keychain "${KEYCHAIN}" 2>&1 )
    NOTARIZATION_EXIT_CODE=$?
    
    if [[ ${NOTARIZATION_EXIT_CODE} -ne 0 ]]; then
      echo "Error: Notarization submission failed"
      echo "${NOTARIZATION_OUTPUT}"
      exit 1
    fi
    
    # Check notarization status
    if echo "${NOTARIZATION_OUTPUT}" | grep -qi "status:.*Accepted"; then
      echo "✓ Notarization accepted"
    elif echo "${NOTARIZATION_OUTPUT}" | grep -qi "status:.*Invalid"; then
      echo "Error: Notarization was rejected"
      echo "${NOTARIZATION_OUTPUT}"
      exit 1
    else
      echo "Warning: Could not determine notarization status from output"
      echo "${NOTARIZATION_OUTPUT}"
    fi

    echo "+ attach staple"
    if ! xcrun stapler staple "${APP_BUNDLE}"; then
      echo "Error: Failed to staple notarization ticket"
      exit 1
    fi
    
    # Verify stapling succeeded
    if ! xcrun stapler validate "${APP_BUNDLE}"; then
      echo "Error: Stapling validation failed"
      exit 1
    fi
    echo "✓ Stapling verified successfully"
    
    # Final verification: check Gatekeeper assessment
    echo "+ final Gatekeeper verification"
    SPCTL_OUTPUT=$( spctl --assess --verbose "${APP_BUNDLE}" 2>&1 )
    SPCTL_EXIT_CODE=$?
    
    if [[ ${SPCTL_EXIT_CODE} -eq 0 ]]; then
      echo "✓ Gatekeeper assessment passed"
    else
      echo "Warning: Gatekeeper assessment failed or returned non-zero exit code"
      echo "This may be expected for self-signed certificates"
      echo "Output: ${SPCTL_OUTPUT}"
    fi

    rm "${ZIP_FILE}"

    cd ..
  fi

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    echo "Building and moving ZIP"
    cd "VSCode-darwin-${VSCODE_ARCH}"
    zip -r -X -y "../assets/${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" ./*.app
    cd ..
  fi

  if [[ "${SHOULD_BUILD_DMG}" != "no" ]]; then
    echo "Building and moving DMG"
    pushd "VSCode-darwin-${VSCODE_ARCH}"
    if [[ -n "${CODESIGN_IDENTITY}" ]]; then
      npx create-dmg ./*.app .
    else
      npx create-dmg --no-code-sign ./*.app .
    fi
    mv ./*.dmg "../assets/${APP_NAME}.${VSCODE_ARCH}.${RELEASE_VERSION}.dmg"
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

  npm run gulp "vscode-win32-${VSCODE_ARCH}-inno-updater"

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    7z.exe a -tzip "../assets/${APP_NAME}-win32-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" -x!CodeSignSummary*.md -x!tools "../VSCode-win32-${VSCODE_ARCH}/*" -r
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
    mv "vscode\\.build\\win32-${VSCODE_ARCH}\\system-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}Setup-${VSCODE_ARCH}-${RELEASE_VERSION}.exe"
  fi

  if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
    echo "Moving User EXE"
    mv "vscode\\.build\\win32-${VSCODE_ARCH}\\user-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}UserSetup-${VSCODE_ARCH}-${RELEASE_VERSION}.exe"
  fi

  if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
    if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
      echo "Moving MSI"
      mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-${RELEASE_VERSION}.msi" assets/
    fi

    if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
      echo "Moving MSI with disabled updates"
      mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-updates-disabled-${RELEASE_VERSION}.msi" assets/
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
