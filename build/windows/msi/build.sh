#!/usr/bin/env bash

set -ex

CALLER_DIR=$( pwd )

cd "$( dirname "${BASH_SOURCE[0]}" )"

WIN_SDK_MAJOR_VERSION="10"
WIN_SDK_FULL_VERSION="10.0.17763.0"

# Get executable name from APP_NAME or product.json
if [[ -n "${APP_NAME}" ]]; then
  EXE_NAME="$( echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]' )"
else
  # Fallback to reading from product.json if available
  if [[ -f "../../vscode/product.json" ]]; then
    EXE_NAME=$( node -p "require('../../vscode/product.json').applicationName || 'cortexide'" )
  else
    EXE_NAME="cortexide"
  fi
fi

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  PRODUCT_NAME="CortexIDE - Insiders"
  PRODUCT_CODE="CortexIDEInsiders"
  PRODUCT_UPGRADE_CODE="1C9B7195-5A9A-43B3-B4BD-583E20498467"
  ICON_DIR="..\\..\\..\\src\\insider\\resources\\win32"
  SETUP_RESOURCES_DIR=".\\resources\\insider"
else
  PRODUCT_NAME="CortexIDE"
  PRODUCT_CODE="CortexIDE"
  PRODUCT_UPGRADE_CODE="965370CD-253C-4720-82FC-2E6B02A53808"
  ICON_DIR="..\\..\\..\\src\\stable\\resources\\win32"
  SETUP_RESOURCES_DIR=".\\resources\\stable"
fi

# Convert EXE_NAME to uppercase for WiX file ID (e.g., "cortexide.exe" -> "CORTEXIDE.EXE")
EXE_FILE_ID="$( echo "${EXE_NAME}.exe" | tr '[:lower:]' '[:upper:]' )"

# CRITICAL: Validate WIX toolset is available
if [[ -z "${WIX}" ]]; then
  echo "Error: WIX environment variable is not set" >&2
  echo "WIX should point to the WiX Toolset installation directory (e.g., C:\\Program Files (x86)\\WiX Toolset v3.11\\)" >&2
  echo "Please set WIX before running this script" >&2
  exit 1
fi

# Validate WIX directory exists and contains required tools
if [[ ! -d "${WIX}" ]]; then
  echo "Error: WIX directory does not exist: ${WIX}" >&2
  exit 1
fi

# Check for required WiX tools
for tool in heat.exe candle.exe light.exe; do
  if [[ ! -f "${WIX}bin\\${tool}" ]]; then
    echo "Error: Required WiX tool not found: ${WIX}bin\\${tool}" >&2
    echo "Please verify your WiX Toolset installation" >&2
    exit 1
  fi
done
echo "✓ WiX Toolset found at: ${WIX}" >&2

# Validate PowerShell is available
if ! command -v powershell.exe >/dev/null 2>&1; then
  echo "Error: powershell.exe not found in PATH" >&2
  echo "PowerShell is required to generate Product ID" >&2
  exit 1
fi

PRODUCT_ID=$( powershell.exe -command "[guid]::NewGuid().ToString().ToUpper()" 2>&1 )
if [[ $? -ne 0 ]]; then
  echo "Error: Failed to generate Product ID using PowerShell" >&2
  echo "PowerShell output: ${PRODUCT_ID}" >&2
  exit 1
fi
PRODUCT_ID="${PRODUCT_ID%%[[:cntrl:]]}"

CULTURE="en-us"
LANGIDS="1033"

SETUP_RELEASE_DIR=".\\releasedir"
BINARY_DIR="..\\..\\..\\VSCode-win32-${VSCODE_ARCH}"
LICENSE_DIR="..\\..\\..\\vscode"
PROGRAM_FILES_86=$( env | sed -n 's/^ProgramFiles(x86)=//p' )

if [[ -z "${1}" ]]; then
	OUTPUT_BASE_FILENAME="CortexIDE-${VSCODE_ARCH}-${RELEASE_VERSION}"
else
	OUTPUT_BASE_FILENAME="CortexIDE-${VSCODE_ARCH}-${1}-${RELEASE_VERSION}"
fi

if [[ "${VSCODE_ARCH}" == "ia32" ]]; then
   export PLATFORM="x86"
else
   export PLATFORM="${VSCODE_ARCH}"
fi

sed -i "s|@@PRODUCT_UPGRADE_CODE@@|${PRODUCT_UPGRADE_CODE}|g" .\\includes\\vscodium-variables.wxi
sed -i "s|@@PRODUCT_NAME@@|${PRODUCT_NAME}|g" .\\vscodium.xsl
sed -i "s|@@EXE_FILE_ID@@|${EXE_FILE_ID}|g" .\\vscodium.xsl
# CRITICAL: Replace @@EXE_NAME@@ with actual executable name (lowercase, no spaces)
# The XSL file searches for the executable file, which is named based on applicationName
# not PRODUCT_NAME (which has spaces and different casing)
sed -i "s|@@EXE_NAME@@|${EXE_NAME}|g" .\\vscodium.xsl

find i18n -name '*.wxl' -print0 | xargs -0 sed -i "s|@@PRODUCT_NAME@@|${PRODUCT_NAME}|g"

# Transform version to MSI-compatible format (x.x.x.x where each part is 0-65534)
transformMsiVersion() {
	local version="${1%-insider}"
	local parts
	IFS='.' read -r -a parts <<< "${version}"
	
	# MSI requires exactly 4 parts, each 0-65534
	# Handle versions with more than 4 parts by combining the extra parts
	local major="${parts[0]:-0}"
	local minor="${parts[1]:-0}"
	local patch="${parts[2]:-0}"
	local build="${parts[3]:-0}"
	
	# If there are more than 4 parts, combine them into the build number
	if [[ ${#parts[@]} -gt 4 ]]; then
		# Combine parts[3] and parts[4] (e.g., "0.2" becomes "2" or handle as needed)
		# For "1.99.30.0.2", we want "1.99.30.2" (combining 0 and 2)
		if [[ -n "${parts[4]}" ]]; then
			# If parts[3] is 0 and parts[4] exists, use parts[4] as build
			if [[ "${parts[3]}" == "0" ]]; then
				build="${parts[4]}"
			else
				# Otherwise, combine them (limit to 65534)
				build=$((10#${parts[3]} * 1000 + 10#${parts[4]}))
				if [[ ${build} -gt 65534 ]]; then
					build=65534
				fi
			fi
		fi
	fi
	
	# Ensure each part is within valid range (0-65534)
	major=$((10#${major}))
	minor=$((10#${minor}))
	patch=$((10#${patch}))
	build=$((10#${build}))
	
	# Clamp values to valid range
	[[ ${major} -gt 65534 ]] && major=65534
	[[ ${minor} -gt 65534 ]] && minor=65534
	[[ ${patch} -gt 65534 ]] && patch=65534
	[[ ${build} -gt 65534 ]] && build=65534
	
	echo "${major}.${minor}.${patch}.${build}"
}

BuildSetupTranslationTransform() {
	local CULTURE=${1}
	local LANGID=${2}

	LANGIDS="${LANGIDS},${LANGID}"

	echo "Building setup translation for culture \"${CULTURE}\" with LangID \"${LANGID}\"..."

	"${WIX}bin\\light.exe" vscodium.wixobj "Files-${OUTPUT_BASE_FILENAME}.wixobj" -ext WixUIExtension -ext WixUtilExtension -ext WixNetFxExtension -spdb -cc "${TEMP}\\vscodium-cab-cache\\${PLATFORM}" -reusecab -out "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi" -loc "i18n\\vscodium.${CULTURE}.wxl" -cultures:"${CULTURE}" -sice:ICE60 -sice:ICE69

	WILANGID_VBS="${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\WiLangId.vbs"
	if [[ -f "${WILANGID_VBS}" ]]; then
		cscript "${WILANGID_VBS}" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi" Product "${LANGID}" 2>&1 || {
			echo "Warning: Failed to set language ID for ${CULTURE} using WiLangId.vbs" >&2
		}
	else
		echo "Warning: WiLangId.vbs not found at ${WILANGID_VBS}, skipping language ID setting for ${CULTURE}" >&2
	fi

	# Windows SDK tools are optional - check before using
	MSITRAN="${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\x86\\msitran"
	if [[ -f "${MSITRAN}" ]]; then
		"${MSITRAN}" -g "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.mst" 2>&1 || {
			echo "Warning: Failed to create transform using msitran for ${CULTURE}" >&2
		}
	else
		echo "Warning: msitran not found at ${MSITRAN}, skipping transform creation for ${CULTURE}" >&2
	fi

	WISUBSTG_VBS="${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\wisubstg.vbs"
	if [[ -f "${WISUBSTG_VBS}" ]]; then
		cscript "${WISUBSTG_VBS}" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.mst" "${LANGID}" 2>&1 || {
			echo "Warning: Failed to add transform using wisubstg.vbs for ${CULTURE}" >&2
		}
		cscript "${WISUBSTG_VBS}" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" 2>&1 || {
			echo "Warning: Failed to finalize transforms using wisubstg.vbs" >&2
		}
	else
		echo "Warning: wisubstg.vbs not found at ${WISUBSTG_VBS}, skipping transform operations for ${CULTURE}" >&2
	fi

	rm -f "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi"
	rm -f "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.mst"
}

# CRITICAL: Validate RELEASE_VERSION is set before building MSI
if [[ -z "${RELEASE_VERSION}" ]]; then
  echo "Error: RELEASE_VERSION is not set. Cannot build MSI installer." >&2
  echo "Attempting to read version from built package..." >&2
  
  # Try to read from the built package's package.json
  if [[ -f "${BINARY_DIR}\\resources\\app\\package.json" ]]; then
    FALLBACK_VERSION=$( node -p "require('${BINARY_DIR}/resources/app/package.json').version" 2>/dev/null || echo "" )
    if [[ -n "${FALLBACK_VERSION}" && "${FALLBACK_VERSION}" != "null" && "${FALLBACK_VERSION}" != "undefined" ]]; then
      RELEASE_VERSION="${FALLBACK_VERSION}"
      echo "Using fallback version from built package.json: ${RELEASE_VERSION}" >&2
    else
      echo "Error: Could not read version from built package.json" >&2
      exit 1
    fi
  else
    echo "Error: Built package.json not found at ${BINARY_DIR}\\resources\\app\\package.json" >&2
    exit 1
  fi
fi

# Transform version to MSI-compatible format
MSI_VERSION=$(transformMsiVersion "${RELEASE_VERSION}")

# Validate MSI_VERSION is not empty
if [[ -z "${MSI_VERSION}" ]]; then
  echo "Error: MSI_VERSION is empty after transformation. RELEASE_VERSION was: '${RELEASE_VERSION}'" >&2
  exit 1
fi

# CRITICAL: Verify the executable file exists before running heat.exe
EXE_FILE_PATH="${BINARY_DIR}\\bin\\${EXE_NAME}.exe"
echo "Checking for executable at: ${EXE_FILE_PATH}" >&2
if [[ ! -f "${EXE_FILE_PATH}" ]]; then
  echo "Error: Executable file not found at ${EXE_FILE_PATH}" >&2
  echo "Expected file: ${EXE_NAME}.exe" >&2
  echo "Looking for alternative locations..." >&2
  # Try to find the actual executable
  FOUND_EXE=$(find "${BINARY_DIR}" -name "*.exe" -type f 2>/dev/null | grep -v "tunnel\|server" | head -1)
  if [[ -n "${FOUND_EXE}" ]]; then
    FOUND_EXE_NAME=$(basename "${FOUND_EXE}" .exe)
    echo "Found executable: ${FOUND_EXE}" >&2
    echo "Updating EXE_NAME from '${EXE_NAME}' to '${FOUND_EXE_NAME}'" >&2
    EXE_NAME="${FOUND_EXE_NAME}"
    EXE_FILE_ID="$( echo "${EXE_NAME}.exe" | tr '[:lower:]' '[:upper:]' )"
    # Update the XSL file with the correct name
    sed -i "s|@@EXE_NAME@@|${EXE_NAME}|g" .\\vscodium.xsl
    sed -i "s|@@EXE_FILE_ID@@|${EXE_FILE_ID}|g" .\\vscodium.xsl
  else
    echo "Error: No executable file found in ${BINARY_DIR}" >&2
    echo "Listing bin directory contents:" >&2
    ls -la "${BINARY_DIR}\\bin" 2>&1 || echo "bin directory not found" >&2
    exit 1
  fi
else
  echo "✓ Executable found: ${EXE_FILE_PATH}" >&2
fi

"${WIX}bin\\heat.exe" dir "${BINARY_DIR}" -out "Files-${OUTPUT_BASE_FILENAME}.wxs" -t vscodium.xsl -gg -sfrag -scom -sreg -srd -ke -cg "AppFiles" -var var.ManufacturerName -var var.AppName -var var.AppCodeName -var var.ProductVersion -var var.IconDir -var var.LicenseDir -var var.BinaryDir -dr APPLICATIONFOLDER -platform "${PLATFORM}"
# Set manufacturer name - use CortexIDE instead of Void
MANUFACTURER_NAME="CortexIDE"

# Verify the generated Files-*.wxs contains the executable file
echo "Verifying generated Files-*.wxs contains executable..." >&2
if ! grep -qi "File.*Id.*${EXE_FILE_ID}" "Files-${OUTPUT_BASE_FILENAME}.wxs" 2>/dev/null && ! grep -qi "File.*Id.*${EXE_NAME}.exe" "Files-${OUTPUT_BASE_FILENAME}.wxs" 2>/dev/null; then
  echo "Warning: Executable file ID not found in generated Files-*.wxs" >&2
  echo "Searching for executable references in generated file..." >&2
  grep -i "\.exe" "Files-${OUTPUT_BASE_FILENAME}.wxs" | head -5 >&2 || echo "No .exe files found" >&2
  echo "This may cause unresolved reference errors. Continuing anyway..." >&2
fi

"${WIX}bin\\candle.exe" -arch "${PLATFORM}" vscodium.wxs "Files-${OUTPUT_BASE_FILENAME}.wxs" -ext WixUIExtension -ext WixUtilExtension -ext WixNetFxExtension -dManufacturerName="${MANUFACTURER_NAME}" -dAppCodeName="${PRODUCT_CODE}" -dAppName="${PRODUCT_NAME}" -dProductVersion="${MSI_VERSION}" -dProductId="${PRODUCT_ID}" -dBinaryDir="${BINARY_DIR}" -dIconDir="${ICON_DIR}" -dLicenseDir="${LICENSE_DIR}" -dSetupResourcesDir="${SETUP_RESOURCES_DIR}" -dCulture="${CULTURE}" -dExeFileId="${EXE_FILE_ID}"
"${WIX}bin\\light.exe" vscodium.wixobj "Files-${OUTPUT_BASE_FILENAME}.wixobj" -ext WixUIExtension -ext WixUtilExtension -ext WixNetFxExtension -spdb -cc "${TEMP}\\vscodium-cab-cache\\${PLATFORM}" -out "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" -loc "i18n\\vscodium.${CULTURE}.wxl" -cultures:"${CULTURE}" -sice:ICE60 -sice:ICE69

BuildSetupTranslationTransform de-de 1031
BuildSetupTranslationTransform es-es 3082
BuildSetupTranslationTransform fr-fr 1036
BuildSetupTranslationTransform it-it 1040
# WixUI_Advanced bug: https://github.com/wixtoolset/issues/issues/5909
# BuildSetupTranslationTransform ja-jp 1041
BuildSetupTranslationTransform ko-kr 1042
BuildSetupTranslationTransform ru-ru 1049
BuildSetupTranslationTransform zh-cn 2052
BuildSetupTranslationTransform zh-tw 1028

# Add all supported languages to MSI Package attribute
# Add all supported languages to MSI Package attribute
# Validate Windows SDK path exists before using cscript
WILANGID_VBS="${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\WiLangId.vbs"
if [[ -f "${WILANGID_VBS}" ]]; then
	cscript "${WILANGID_VBS}" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" Package "${LANGIDS}" 2>&1 || {
		echo "Warning: Failed to set language IDs using WiLangId.vbs" >&2
		echo "This is non-critical - MSI will still work, but language support may be limited" >&2
	}
else
	echo "Warning: WiLangId.vbs not found at ${WILANGID_VBS}" >&2
	echo "Skipping language ID setting - MSI will still work, but language support may be limited" >&2
fi

# Remove files we do not need any longer.
rm -rf "${TEMP}\\vscodium-cab-cache"
rm -f "Files-${OUTPUT_BASE_FILENAME}.wxs"
rm -f "Files-${OUTPUT_BASE_FILENAME}.wixobj"
rm -f "vscodium.wixobj"

cd "${CALLER_DIR}"
