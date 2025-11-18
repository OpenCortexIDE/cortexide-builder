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
  # For brand.patch, use --reject directly due to widespread hunk header issues
  # This allows partial application which is acceptable for branding changes
  if [[ "$(basename "$1")" == "brand.patch" ]]; then
    echo "Note: Using --reject for brand.patch to handle hunk header mismatches..."
    # Try to apply with reject - this will skip corrupt hunks but apply what it can
    PATCH_ERROR=$(git apply --reject --ignore-whitespace "$1" 2>&1) || PATCH_FAILED=1
    # If patch is completely corrupt and can't be parsed, skip it with a warning
    if [[ -n "$PATCH_FAILED" ]] && echo "$PATCH_ERROR" | grep -q "corrupt patch"; then
      echo "Warning: brand.patch is corrupt and cannot be applied. Skipping this patch." >&2
      echo "Branding changes may be incomplete. Consider regenerating this patch." >&2
      find . -name "*.rej" -type f -delete 2>/dev/null || true
      mv -f $1{.bak,}
      return 0
    fi
    if [[ -n "$PATCH_FAILED" ]]; then
      # Count rejected hunks
      REJ_COUNT=$(find . -name "*.rej" -type f 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$REJ_COUNT" -gt 0 ]]; then
        # Check if any rejected files actually exist (real conflicts)
        CONFLICT_FILES=""
        for rej_file in $(find . -name "*.rej" -type f 2>/dev/null); do
          source_file="${rej_file%.rej}"
          if [[ -f "$source_file" ]]; then
            CONFLICT_FILES="${CONFLICT_FILES}${source_file}\n"
          fi
        done
        
        if [[ -n "$CONFLICT_FILES" ]]; then
          echo "Warning: Some hunks in brand.patch had conflicts in existing files:" >&2
          echo -e "$CONFLICT_FILES" >&2
          echo "These may need manual review, but build will continue..." >&2
        fi
        
        echo "Applied brand.patch partially (${REJ_COUNT} hunks skipped - likely due to hunk header mismatches)"
        find . -name "*.rej" -type f -delete 2>/dev/null || true
        mv -f $1{.bak,}
        return 0
      else
        echo "Applied brand.patch successfully with --reject"
        mv -f $1{.bak,}
        return 0
      fi
    else
      echo "Applied brand.patch successfully"
      mv -f $1{.bak,}
      return 0
    fi
  fi
  
  # First try normal apply for other patches
  PATCH_ERROR=$(git apply --ignore-whitespace "$1" 2>&1) || PATCH_FAILED=1
  
  # Check if we have git history (required for --3way)
  # In CI, vscode is often a shallow clone, so --3way won't work
  HAS_GIT_HISTORY=$(git rev-list --count HEAD 2>/dev/null || echo "0")
  CAN_USE_3WAY="no"
  if [[ "$HAS_GIT_HISTORY" -gt 1 ]]; then
    CAN_USE_3WAY="yes"
  fi
  
  # If that fails, try with 3-way merge first (handles line number shifts better)
  # But only if we have git history
  if [[ -n "$PATCH_FAILED" ]] && echo "$PATCH_ERROR" | grep -qE "patch does not apply|hunk.*failed" && [[ "$CAN_USE_3WAY" == "yes" ]]; then
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
    
    # If we have both missing files and line issues, try 3-way merge with reject (if history available)
    # Otherwise fall back to regular reject
    if [[ "$HAS_MISSING_FILES" == "yes" ]] || [[ "$HAS_LINE_ISSUES" == "yes" ]]; then
      if [[ "$CAN_USE_3WAY" == "yes" ]]; then
        echo "Warning: Patch has issues (missing files or line number shifts), trying 3-way merge with reject..."
        REJECT_OUTPUT=$(git apply --3way --reject --ignore-whitespace "$1" 2>&1) || REJECT_FAILED=1
      else
        # No git history, so can't use --3way
        # --reject will work for missing files but may create .rej files for line number issues
        echo "Warning: Patch has issues (missing files or line number shifts), trying with reject..."
        echo "Note: 3-way merge not available (shallow clone), so line number shifts may cause conflicts"
        REJECT_OUTPUT=$(git apply --reject --ignore-whitespace "$1" 2>&1) || REJECT_FAILED=1
      fi
      
      # Count rejected hunks
      REJ_COUNT=$(find . -name "*.rej" -type f 2>/dev/null | wc -l | tr -d ' ')
      
      if [[ "$REJ_COUNT" -gt 0 ]]; then
        # Check if rejected files are missing files (expected) or actual conflicts
        MISSING_FILES_LIST=$(echo "$PATCH_ERROR" | grep "No such file or directory" | sed 's/.*: //' | sort -u)
        CONFLICT_FILES=""
        
        for rej_file in $(find . -name "*.rej" -type f 2>/dev/null); do
          # Get the source file from .rej filename
          # .rej files are named like "path/to/file.ext.rej" for "path/to/file.ext"
          source_file="${rej_file%.rej}"
          # Check if the source file exists (if it does, it's a real conflict)
          # If it doesn't exist, it's a missing file (expected)
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
      # Try with --3way for better conflict resolution (if history available)
      if [[ "$CAN_USE_3WAY" == "yes" ]]; then
        echo "Warning: Patch failed to apply cleanly, trying with 3-way merge..."
        PATCH_ERROR_3WAY=$(git apply --3way --ignore-whitespace "$1" 2>&1) || PATCH_FAILED_3WAY=1
      else
        echo "Error: Patch failed to apply and 3-way merge not available (shallow clone)" >&2
        echo "Patch file: $1" >&2
        echo "Error: $PATCH_ERROR" >&2
        echo "This patch may need to be updated for VS Code 1.106" >&2
        exit 1
      fi
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
      # Check if this is a non-critical patch that can be skipped
      PATCH_NAME=$(basename "$1")
      NON_CRITICAL_PATCHES="policies.patch report-issue.patch fix-node-gyp-env-paths.patch disable-signature-verification.patch merge-user-product.patch remove-mangle.patch terminal-suggest.patch version-1-update.patch"
      if echo "$NON_CRITICAL_PATCHES" | grep -q "$PATCH_NAME"; then
        echo "Warning: Non-critical patch $PATCH_NAME failed to apply. Skipping..." >&2
        echo "Error: $PATCH_ERROR" >&2
        echo "This patch may need to be updated for VS Code 1.106" >&2
        mv -f $1{.bak,}
        return 0
      fi
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
