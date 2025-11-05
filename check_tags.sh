#!/usr/bin/env bash
# shellcheck disable=SC2129

# CortexIDE completely rewrote this file
set -e

if [[ -z "${GH_TOKEN}" ]] && [[ -z "${GITHUB_TOKEN}" ]] && [[ -z "${GH_ENTERPRISE_TOKEN}" ]] && [[ -z "${GITHUB_ENTERPRISE_TOKEN}" ]] && [[ -z "${RELEASE_GITHUB_TOKEN}" ]]; then
  echo "Will not build because no GITHUB_TOKEN defined"
  exit 0
else
  GITHUB_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN:-${RELEASE_GITHUB_TOKEN}}}}}"
fi

# Support for GitHub Enterprise
GH_HOST="${GH_HOST:-github.com}"

APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"

# Always build and deploy for initial setup
echo "Always building from main branch"
export SHOULD_BUILD="yes"
export SHOULD_DEPLOY="yes"

# Set all build flags to "yes" by default
export SHOULD_BUILD_APPIMAGE="yes"
export SHOULD_BUILD_DEB="yes"
export SHOULD_BUILD_DMG="yes"
export SHOULD_BUILD_EXE_SYS="yes"
export SHOULD_BUILD_EXE_USR="yes"
export SHOULD_BUILD_MSI="yes"
export SHOULD_BUILD_MSI_NOUP="yes"
export SHOULD_BUILD_REH="yes"
export SHOULD_BUILD_REH_WEB="yes"
export SHOULD_BUILD_RPM="yes"
export SHOULD_BUILD_TAR="yes"
export SHOULD_BUILD_ZIP="yes"

# Turn off certain builds based on architecture
if [[ "${IS_SPEARHEAD}" == "yes" ]]; then
  # We never want to package and release the source code
  export SHOULD_BUILD_SRC="no"
elif [[ "${OS_NAME}" == "linux" ]]; then
  if [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
    export SHOULD_BUILD_DEB="no"
    export SHOULD_BUILD_RPM="no"
  elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
    export SHOULD_BUILD_DEB="no"
    export SHOULD_BUILD_RPM="no"
  elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
    export SHOULD_BUILD_DEB="no"
    export SHOULD_BUILD_RPM="no"
  fi

  if [[ "${VSCODE_ARCH}" != "x64" || "${DISABLE_APPIMAGE}" == "yes" ]]; then
    export SHOULD_BUILD_APPIMAGE="no"
  fi
elif [[ "${OS_NAME}" == "windows" ]]; then
  if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
    export SHOULD_BUILD_REH="no"
    export SHOULD_BUILD_REH_WEB="no"
  fi

  if [[ "${DISABLE_MSI}" == "yes" ]]; then
    export SHOULD_BUILD_MSI="no"
    export SHOULD_BUILD_MSI_NOUP="no"
  fi
fi

echo "SHOULD_BUILD=${SHOULD_BUILD}" >> "${GITHUB_ENV}"
echo "SHOULD_DEPLOY=${SHOULD_DEPLOY}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_APPIMAGE=${SHOULD_BUILD_APPIMAGE}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_DEB=${SHOULD_BUILD_DEB}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_DMG=${SHOULD_BUILD_DMG}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_EXE_SYS=${SHOULD_BUILD_EXE_SYS}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_EXE_USR=${SHOULD_BUILD_EXE_USR}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_MSI=${SHOULD_BUILD_MSI}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_MSI_NOUP=${SHOULD_BUILD_MSI_NOUP}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_REH=${SHOULD_BUILD_REH}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_REH_WEB=${SHOULD_BUILD_REH_WEB}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_RPM=${SHOULD_BUILD_RPM}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_TAR=${SHOULD_BUILD_TAR}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_ZIP=${SHOULD_BUILD_ZIP}" >> "${GITHUB_ENV}"
echo "SHOULD_BUILD_SRC=${SHOULD_BUILD_SRC}" >> "${GITHUB_ENV}"
