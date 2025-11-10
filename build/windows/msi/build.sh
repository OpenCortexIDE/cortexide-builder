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

PRODUCT_ID=$( powershell.exe -command "[guid]::NewGuid().ToString().ToUpper()" )
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

	cscript "${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\WiLangId.vbs" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi" Product "${LANGID}"

	"${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\x86\\msitran" -g "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.mst"

	cscript "${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\wisubstg.vbs" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.mst" "${LANGID}"

	cscript "${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\wisubstg.vbs" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi"

	rm -f "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.msi"
	rm -f "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.${CULTURE}.mst"
}

# Transform version to MSI-compatible format
MSI_VERSION=$(transformMsiVersion "${RELEASE_VERSION}")

"${WIX}bin\\heat.exe" dir "${BINARY_DIR}" -out "Files-${OUTPUT_BASE_FILENAME}.wxs" -t vscodium.xsl -gg -sfrag -scom -sreg -srd -ke -cg "AppFiles" -var var.ManufacturerName -var var.AppName -var var.AppCodeName -var var.ProductVersion -var var.IconDir -var var.LicenseDir -var var.BinaryDir -dr APPLICATIONFOLDER -platform "${PLATFORM}"
"${WIX}bin\\candle.exe" -arch "${PLATFORM}" vscodium.wxs "Files-${OUTPUT_BASE_FILENAME}.wxs" -ext WixUIExtension -ext WixUtilExtension -ext WixNetFxExtension -dManufacturerName="Void" -dAppCodeName="${PRODUCT_CODE}" -dAppName="${PRODUCT_NAME}" -dProductVersion="${MSI_VERSION}" -dProductId="${PRODUCT_ID}" -dBinaryDir="${BINARY_DIR}" -dIconDir="${ICON_DIR}" -dLicenseDir="${LICENSE_DIR}" -dSetupResourcesDir="${SETUP_RESOURCES_DIR}" -dCulture="${CULTURE}" -dExeFileId="${EXE_FILE_ID}"
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
cscript "${PROGRAM_FILES_86}\\Windows Kits\\${WIN_SDK_MAJOR_VERSION}\\bin\\${WIN_SDK_FULL_VERSION}\\${PLATFORM}\\WiLangId.vbs" "${SETUP_RELEASE_DIR}\\${OUTPUT_BASE_FILENAME}.msi" Package "${LANGIDS}"

# Remove files we do not need any longer.
rm -rf "${TEMP}\\vscodium-cab-cache"
rm -f "Files-${OUTPUT_BASE_FILENAME}.wxs"
rm -f "Files-${OUTPUT_BASE_FILENAME}.wixobj"
rm -f "vscodium.wixobj"

cd "${CALLER_DIR}"
