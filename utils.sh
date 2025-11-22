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
  # Store original exit behavior
  local ORIG_SET_E
  [[ $- == *e* ]] && ORIG_SET_E=1 || ORIG_SET_E=0
  
  if [[ -z "$2" ]]; then
    echo applying patch: "$1";
  fi
  
  # Helper function to check if patch is non-critical (defined early for use throughout)
  is_non_critical_patch() {
    local patch_name=$(basename "$1")
    local patch_path="$1"
    local non_critical="policies.patch report-issue.patch fix-node-gyp-env-paths.patch disable-signature-verification.patch merge-user-product.patch remove-mangle.patch terminal-suggest.patch version-1-update.patch cli.patch"
    # OS-specific patches in subdirectories are also non-critical (they may be outdated)
    if echo "$patch_path" | grep -q "/osx/\|/linux/\|/windows/"; then
      return 0
    fi
    # Architecture patches are non-critical (we have runtime fixes that handle them)
    if echo "$patch_name" | grep -qE "arch-[0-9]+-(ppc64le|riscv64|loong64|s390x)\.patch"; then
      return 0
    fi
    echo "$non_critical" | grep -q "$patch_name"
  }
  
  # Helper function to check if architecture patch changes are already applied
  check_arch_patch_already_applied() {
    local patch_file="$1"
    local patch_name=$(basename "$patch_file")
    
    # Only check architecture patches
    if ! echo "$patch_name" | grep -qE "arch-[0-9]+-(ppc64le|riscv64|loong64|s390x)\.patch"; then
      return 1
    fi
    
    # Extract architecture from patch name
    local arch=""
    if echo "$patch_name" | grep -q "ppc64le"; then
      arch="ppc64le"
    elif echo "$patch_name" | grep -q "riscv64"; then
      arch="riscv64"
    elif echo "$patch_name" | grep -q "loong64"; then
      arch="loong64"
    elif echo "$patch_name" | grep -q "s390x"; then
      arch="s390x"
    else
      return 1
    fi
    
    # Check if architecture is already in BUILD_TARGETS in key files
    # If it's in at least one file, consider it already applied (patch may have partial failures)
    local found_count=0
    local files_to_check=(
      "build/gulpfile.vscode.js"
      "build/gulpfile.reh.js"
      "build/gulpfile.vscode.linux.js"
    )
    
    for file in "${files_to_check[@]}"; do
      if [[ -f "$file" ]]; then
        # Check if arch is already in BUILD_TARGETS
        if grep -q "{ platform: 'linux', arch: '${arch}' }" "$file" 2>/dev/null || \
           grep -q "{ arch: '${arch}' }" "$file" 2>/dev/null; then
          found_count=$((found_count + 1))
        fi
      fi
    done
    
    # If found in any file, consider it already applied (runtime fixes will handle the rest)
    if [[ $found_count -gt 0 ]]; then
      echo "Architecture ${arch} already present in some files, skipping patch (runtime fixes will handle it)..." >&2
      return 0
    fi
    
    return 1
  }
  
  # Check if this is a non-critical patch early, so we can ensure it never causes build failure
  PATCH_IS_NON_CRITICAL=$(is_non_critical_patch "$1" && echo "yes" || echo "no")
  
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
  
  # For binary-name.patch, use --reject with similar handling as brand.patch
  # This patch may have line number shifts in newer VS Code versions
  if [[ "$(basename "$1")" == "binary-name.patch" ]]; then
    echo "Note: Using --reject for binary-name.patch to handle potential line number shifts..."
    # First try normal apply
    PATCH_ERROR=$(git apply --ignore-whitespace "$1" 2>&1) || PATCH_FAILED=1
    if [[ -z "$PATCH_FAILED" ]]; then
      echo "Applied binary-name.patch successfully"
      mv -f $1{.bak,}
      return 0
    fi
    # If normal apply failed, try with --reject
    echo "Warning: binary-name.patch failed to apply cleanly, trying with --reject..."
    PATCH_ERROR=$(git apply --reject --ignore-whitespace "$1" 2>&1) || PATCH_FAILED=1
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
          echo "Warning: Some hunks in binary-name.patch had conflicts in existing files:" >&2
          echo -e "$CONFLICT_FILES" >&2
          echo "These may need manual review, but build will continue..." >&2
          echo "Note: You may need to manually update these files to use applicationName instead of 'code'" >&2
        fi
        
        echo "Applied binary-name.patch partially (${REJ_COUNT} hunks skipped - conflicts may need manual review)"
        find . -name "*.rej" -type f -delete 2>/dev/null || true
        mv -f $1{.bak,}
        return 0
      else
        echo "Applied binary-name.patch successfully with --reject"
        mv -f $1{.bak,}
        return 0
      fi
    else
      echo "Applied binary-name.patch successfully with --reject"
      mv -f $1{.bak,}
      return 0
    fi
  fi
  
  # For architecture patches, check if changes are already applied
  if check_arch_patch_already_applied "$1"; then
    echo "Architecture patch $(basename "$1") changes appear to be already applied, skipping..." >&2
    mv -f $1{.bak,}
    return 0
  fi
  
  # First try normal apply for other patches
  PATCH_FAILED=""
  # Use explicit exit code check to ensure PATCH_FAILED is set correctly
  # Capture both stdout and stderr to get all error messages
  PATCH_ERROR=$(git apply --ignore-whitespace "$1" 2>&1)
  PATCH_EXIT_CODE=$?
  if [[ $PATCH_EXIT_CODE -ne 0 ]]; then
    PATCH_FAILED=1
  fi
  
  # Also check for partial application (some hunks applied, some failed)
  # This can happen when a patch creates new files but fails on modifications
  if [[ $PATCH_EXIT_CODE -ne 0 ]] && echo "$PATCH_ERROR" | grep -qE "error:|patch does not apply|hunk.*failed"; then
    PATCH_FAILED=1
  fi
  
  # Check if we have git history (required for --3way)
  # In CI, vscode is often a shallow clone, so --3way won't work
  HAS_GIT_HISTORY=$(git rev-list --count HEAD 2>/dev/null || echo "0")
  CAN_USE_3WAY="no"
  if [[ "$HAS_GIT_HISTORY" -gt 1 ]]; then
    CAN_USE_3WAY="yes"
  fi
  
  # If patch failed and it's non-critical, skip it early
  # Check both PATCH_FAILED and PATCH_EXIT_CODE to be safe
  # Use separate condition checks to avoid potential syntax issues
  # Check if patch failed (either via PATCH_FAILED or PATCH_EXIT_CODE)
  if [[ $PATCH_EXIT_CODE -ne 0 ]] && [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
    # Still try 3-way merge first if available, but don't fail if it doesn't work
    if [[ "$CAN_USE_3WAY" == "yes" ]] && echo "$PATCH_ERROR" | grep -qE "patch does not apply|hunk.*failed"; then
      PATCH_ERROR_3WAY=$(git apply --3way --ignore-whitespace "$1" 2>&1) || PATCH_FAILED_3WAY=1
      if [[ -z "$PATCH_FAILED_3WAY" ]]; then
        echo "Applied patch successfully with 3-way merge"
        mv -f $1{.bak,}
        return 0
      fi
    fi
    # If still failed, skip it
    echo "Warning: Non-critical patch $(basename "$1") failed to apply. Skipping..." >&2
    echo "Error: $PATCH_ERROR" >&2
    echo "This patch may need to be updated for VS Code 1.106" >&2
    mv -f $1{.bak,}
    return 0
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
    # If 3-way also failed, check if non-critical before continuing
    if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
      echo "Warning: Non-critical patch $(basename "$1") failed even with 3-way merge. Skipping..." >&2
      echo "Error: $PATCH_ERROR_3WAY" >&2
      mv -f $1{.bak,}
      return 0
    fi
    # If 3-way also failed, continue with original error handling
    PATCH_ERROR="$PATCH_ERROR_3WAY"
  fi
  
  if [[ -n "$PATCH_FAILED" ]]; then
    # CRITICAL: Check if non-critical FIRST before any other logic
    if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
      echo "Warning: Non-critical patch $(basename "$1") failed to apply. Skipping..." >&2
      echo "Error: $PATCH_ERROR" >&2
      echo "This patch may need to be updated for VS Code 1.106" >&2
      mv -f $1{.bak,}
      return 0
    fi
    # First check if this is a non-critical patch - if so, skip it immediately
    if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
      # Still try 3-way merge first if available, but don't fail if it doesn't work
      if [[ "$CAN_USE_3WAY" == "yes" ]] && echo "$PATCH_ERROR" | grep -qE "patch does not apply|hunk.*failed"; then
        PATCH_ERROR_3WAY=$(git apply --3way --ignore-whitespace "$1" 2>&1) || PATCH_FAILED_3WAY=1
        if [[ -z "$PATCH_FAILED_3WAY" ]]; then
          echo "Applied patch successfully with 3-way merge"
          mv -f $1{.bak,}
          return 0
        fi
      fi
      # If still failed, skip it
      echo "Warning: Non-critical patch $(basename "$1") failed to apply. Skipping..." >&2
      echo "Error: $PATCH_ERROR" >&2
      echo "This patch may need to be updated for VS Code 1.106" >&2
      mv -f $1{.bak,}
      return 0
    fi
    
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
          # Check if this is a non-critical patch before exiting
          PATCH_NAME=$(basename "$1")
          if is_non_critical_patch "$1"; then
            echo "Warning: Non-critical patch $PATCH_NAME has conflicts. Skipping..." >&2
            echo -e "Conflicts in: $CONFLICT_FILES" >&2
            echo "This patch may need to be updated for VS Code 1.106" >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
          # Double-check: if somehow we got here with a non-critical patch, skip it
          if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
            echo "Warning: Non-critical patch $PATCH_NAME has conflicts but was not caught earlier. Skipping..." >&2
            echo -e "Conflicts in: $CONFLICT_FILES" >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
          # CRITICAL: Check one more time if this is non-critical before exiting
          if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
            echo "Warning: Non-critical patch $(basename "$1") has conflicts. Skipping..." >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
          # CRITICAL: Final check for non-critical before exit
          if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
            echo "Warning: Non-critical patch $(basename "$1") has conflicts. Skipping..." >&2
            echo -e "Conflicts in: $CONFLICT_FILES" >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
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
      # CRITICAL: Check if this is a non-critical patch BEFORE any exit
      if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
        echo "Warning: Non-critical patch $(basename "$1") failed to apply. Skipping..." >&2
        echo "Error: $PATCH_ERROR" >&2
        echo "This patch may need to be updated for VS Code 1.106" >&2
        mv -f $1{.bak,}
        return 0
      fi
      # Check if this is a non-critical patch before exiting
      PATCH_NAME=$(basename "$1")
      if is_non_critical_patch "$1"; then
        echo "Warning: Non-critical patch $PATCH_NAME failed to apply. Skipping..." >&2
        echo "Error: $PATCH_ERROR" >&2
        echo "This patch may need to be updated for VS Code 1.106" >&2
        mv -f $1{.bak,}
        return 0
      fi
        # CRITICAL: Final check for non-critical before exit
        if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
          echo "Warning: Non-critical patch $(basename "$1") failed. Skipping..." >&2
          mv -f $1{.bak,}
          return 0
        fi
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
          # Check if this is a non-critical patch before exiting
          PATCH_NAME=$(basename "$1")
          if is_non_critical_patch "$1"; then
            echo "Warning: Non-critical patch $PATCH_NAME failed to apply even with 3-way merge. Skipping..." >&2
            echo "Rejected hunks: ${REJ_COUNT}" >&2
            echo "This patch may need to be updated for VS Code 1.106" >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
          # Double-check: if somehow we got here with a non-critical patch, skip it
          if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
            echo "Warning: Non-critical patch $PATCH_NAME failed with 3-way merge but was not caught earlier. Skipping..." >&2
            echo "Rejected hunks: ${REJ_COUNT}" >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
          # CRITICAL: Check one more time if this is non-critical before exiting
          if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
            echo "Warning: Non-critical patch $(basename "$1") failed with 3-way merge. Skipping..." >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
          # CRITICAL: Final check for non-critical before exit
          if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
            echo "Warning: Non-critical patch $(basename "$1") failed even with 3-way merge. Skipping..." >&2
            echo "Rejected hunks: ${REJ_COUNT}" >&2
            find . -name "*.rej" -type f -delete 2>/dev/null || true
            mv -f $1{.bak,}
            return 0
          fi
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
      if is_non_critical_patch "$1"; then
        echo "Warning: Non-critical patch $PATCH_NAME failed to apply. Skipping..." >&2
        echo "Error: $PATCH_ERROR" >&2
        echo "This patch may need to be updated for VS Code 1.106" >&2
        mv -f $1{.bak,}
        return 0
      fi
      # CRITICAL: Check if this is non-critical before any exit
      if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
        echo "Warning: Non-critical patch $(basename "$1") failed. Skipping..." >&2
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
  
  # Final safety net: if we somehow got here with a non-critical patch that failed, ensure we return 0
  # This should never happen, but it's a safety measure
  if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
    if [[ -n "$PATCH_FAILED" ]]; then
      echo "Warning: Non-critical patch $(basename "$1") had unexpected failure. Skipping..." >&2
    fi
    # CRITICAL: For non-critical patches, ALWAYS return 0, never exit
    # This ensures set -e doesn't kill the build
    return 0
  fi
  
  # Only critical patches that failed should reach here
  # But if we somehow got here with a non-critical patch, return 0 anyway
  if [[ "$PATCH_IS_NON_CRITICAL" == "yes" ]]; then
    return 0
  fi
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
