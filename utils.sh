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
  # First try normal apply
  PATCH_ERROR=$(git apply --ignore-whitespace "$1" 2>&1) || PATCH_FAILED=1
  
  # If that fails, try with 3-way merge first (handles line number shifts better)
  if [[ -n "$PATCH_FAILED" ]] && echo "$PATCH_ERROR" | grep -qE "patch does not apply|hunk.*failed"; then
    echo "Warning: Patch failed to apply cleanly, trying with 3-way merge first..."
    PATCH_ERROR_3WAY=$(git apply --3way --ignore-whitespace "$1" 2>&1) || PATCH_FAILED_3WAY=1
    if [[ -z "$PATCH_FAILED_3WAY" ]]; then
      echo "Applied patch successfully with 3-way merge"
      mv -f $1{.bak,}
      return 0
    fi
    # If 3-way also failed, continue with original error handling
    PATCH_ERROR="$PATCH_ERROR_3WAY"
  fi
  
  if [[ -n "$PATCH_FAILED" ]]; then
    # Check if the failure is due to missing files OR line number issues
    HAS_MISSING_FILES=$(echo "$PATCH_ERROR" | grep -q "No such file or directory" && echo "yes" || echo "no")
    HAS_LINE_ISSUES=$(echo "$PATCH_ERROR" | grep -qE "patch does not apply|hunk.*failed" && echo "yes" || echo "no")
    
    # If we have both missing files and line issues, try 3-way merge with reject
    if [[ "$HAS_MISSING_FILES" == "yes" ]] || [[ "$HAS_LINE_ISSUES" == "yes" ]]; then
      echo "Warning: Patch has issues (missing files or line number shifts), trying 3-way merge with reject..."
      REJECT_OUTPUT=$(git apply --3way --reject --ignore-whitespace "$1" 2>&1) || REJECT_FAILED=1
      
      # Count rejected hunks
      REJ_COUNT=$(find . -name "*.rej" -type f 2>/dev/null | wc -l | tr -d ' ')
      
      if [[ "$REJ_COUNT" -gt 0 ]]; then
        # Check if rejected files are missing files (expected) or actual conflicts
        MISSING_FILES_LIST=$(echo "$PATCH_ERROR" | grep "No such file or directory" | sed 's/.*: //' | sort -u)
        CONFLICT_FILES=""
        
        for rej_file in $(find . -name "*.rej" -type f 2>/dev/null); do
          # Get the source file from .rej filename
          source_file="${rej_file%.rej}"
          if [[ -f "$source_file" ]]; then
            # File exists, so this is a real conflict
            CONFLICT_FILES="${CONFLICT_FILES}${source_file}\n"
          fi
        done
        
        if [[ -n "$CONFLICT_FILES" ]]; then
          echo "Error: Patch has conflicts in existing files:" >&2
          echo -e "$CONFLICT_FILES" >&2
          echo "Patch file: $1" >&2
          echo "This patch may need to be updated for VS Code 1.106" >&2
          # Clean up .rej files before exiting
          find . -name "*.rej" -type f -delete 2>/dev/null || true
          exit 1
        else
          # All rejected hunks are for missing files, which is OK
          echo "Applied patch partially (${REJ_COUNT} hunks skipped for missing files)"
          find . -name "*.rej" -type f -delete 2>/dev/null || true
        fi
      else
        echo "Applied patch successfully with 3-way merge"
      fi
    elif echo "$PATCH_ERROR" | grep -qE "patch does not apply|hunk.*failed"; then
      # Try with --3way for better conflict resolution
      echo "Warning: Patch failed to apply cleanly, trying with 3-way merge..."
      PATCH_ERROR_3WAY=$(git apply --3way --ignore-whitespace "$1" 2>&1) || PATCH_FAILED_3WAY=1
      if [[ -n "$PATCH_FAILED_3WAY" ]]; then
        # Check if 3-way merge left any conflicts
        REJ_COUNT=$(find . -name "*.rej" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$REJ_COUNT" -gt 0 ]]; then
          echo "Error: Patch failed to apply even with 3-way merge" >&2
          echo "Patch file: $1" >&2
          echo "Rejected hunks: ${REJ_COUNT}" >&2
          echo "Error details: $PATCH_ERROR_3WAY" >&2
          echo "This patch may need to be updated for VS Code 1.106" >&2
          find . -name "*.rej" -type f -delete 2>/dev/null || true
          exit 1
        else
          echo "Applied patch with 3-way merge (some conflicts auto-resolved)"
        fi
      else
        echo "Applied patch successfully with 3-way merge"
      fi
    else
      echo "Failed to apply patch: $1" >&2
      echo "Error: $PATCH_ERROR" >&2
      echo "This patch may need to be updated for VS Code 1.106" >&2
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
