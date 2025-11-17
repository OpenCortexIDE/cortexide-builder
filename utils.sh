#!/usr/bin/env bash

APP_NAME="${APP_NAME:-CortexIDE}"
APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"
BINARY_NAME="${BINARY_NAME:-cortexide}"
GH_REPO_PATH="${GH_REPO_PATH:-cortexide/cortexide}"
ORG_NAME="${ORG_NAME:-cortexide}"

echo "---------- utils.sh -----------"
echo "APP_NAME=\"${APP_NAME}\""
echo "APP_NAME_LC=\"${APP_NAME_LC}\""
echo "BINARY_NAME=\"${BINARY_NAME}\""
echo "GH_REPO_PATH=\"${GH_REPO_PATH}\""
echo "ORG_NAME=\"${ORG_NAME}\""

# All common functions can be added to this file

apply_patch() {
  if [[ -z "$2" ]]; then
    echo applying patch: "$1";
  fi
  # grep '^+++' "$1"  | sed -e 's#+++ [ab]/#./vscode/#' | while read line; do shasum -a 256 "${line}"; done

  cp $1{,.bak}

  replace "s|!!APP_NAME!!|${APP_NAME}|g" "$1"
  replace "s|!!APP_NAME_LC!!|${APP_NAME_LC}|g" "$1"
  replace "s|!!BINARY_NAME!!|${BINARY_NAME}|g" "$1"
  replace "s|!!GH_REPO_PATH!!|${GH_REPO_PATH}|g" "$1"
  replace "s|!!ORG_NAME!!|${ORG_NAME}|g" "$1"
  replace "s|!!RELEASE_VERSION!!|${RELEASE_VERSION}|g" "$1"

  # Try to apply the patch, capturing errors
  PATCH_ERROR=$(git apply --ignore-whitespace "$1" 2>&1) || PATCH_FAILED=1
  if [[ -n "$PATCH_FAILED" ]]; then
    # Check if the failure is due to missing files
    if echo "$PATCH_ERROR" | grep -q "No such file or directory"; then
      # Try with --reject to apply what we can
      echo "Warning: Some files in patch do not exist, attempting partial apply..."
      if git apply --reject --ignore-whitespace "$1" 2>&1; then
        # Remove .rej files for missing files (they're expected)
        find . -name "*.rej" -type f -delete 2>/dev/null || true
        echo "Applied patch partially (some files skipped)"
      else
        # Check if we have actual patch failures (not just missing files)
        if find . -name "*.rej" -type f 2>/dev/null | grep -q .; then
          echo "Error: Patch has conflicts that need to be resolved" >&2
          exit 1
        else
          echo "Applied patch partially (some files skipped)"
        fi
      fi
    else
      echo failed to apply patch "$1" >&2
      echo "$PATCH_ERROR" >&2
      exit 1
    fi
  fi

  mv -f $1{.bak,}
}

exists() { type -t "$1" &> /dev/null; }

is_gnu_sed() {
  sed --version &> /dev/null
}

replace() {
  if is_gnu_sed; then
    sed -i -E "${1}" "${2}"
  else
    sed -i '' -E "${1}" "${2}"
  fi
}

if ! exists gsed; then
  if is_gnu_sed; then
    function gsed() {
      sed -i -E "$@"
    }
  else
    function gsed() {
      sed -i '' -E "$@"
    }
  fi
fi
