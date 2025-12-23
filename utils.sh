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
  local silent_mode="$2"
  if [[ -z "$silent_mode" ]]; then
    echo "Applying patch: $1"
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
    # Check if the failure is due to missing files (patch not applicable to CortexIDE)
    if echo "$PATCH_ERROR" | grep -q "No such file or directory"; then
      [[ -z "$silent_mode" ]] && echo "Info: Patch targets files not in CortexIDE, skipping..."
      mv -f $1{.bak,}
      # Return non-zero but don't abort - let caller decide
      return 1
    # Check if already applied
    elif echo "$PATCH_ERROR" | grep -q "patch does not apply\|already exists in working"; then
      [[ -z "$silent_mode" ]] && echo "Info: Patch already applied or not needed, skipping..."
      mv -f $1{.bak,}
      return 0
    else
      # Try with --reject to see if we can partially apply
      echo "Warning: Patch may have conflicts, attempting partial apply..."
      git apply --reject --ignore-whitespace "$1" 2>&1 || true

      # Check if we have .rej files (unresolved conflicts)
      if find . -name "*.rej" -type f 2>/dev/null | grep -q .; then
        [[ -z "$silent_mode" ]] && echo "Warning: Patch has conflicts, but CortexIDE may already have these changes."
        [[ -z "$silent_mode" ]] && echo "Cleaning up .rej files and continuing..."
        # Clean up .rej files - these are expected for CortexIDE which already has customizations
        find . -name "*.rej" -type f -delete 2>/dev/null || true
        mv -f $1{.bak,}
        # Return 1 to indicate patch didn't fully apply, but don't abort
        return 1
      else
        [[ -z "$silent_mode" ]] && echo "Patch applied with warnings"
        mv -f $1{.bak,}
        return 0
      fi
    fi
  fi

  mv -f $1{.bak,}
  return 0
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

# Verify React build outputs exist and are valid
# This is a critical check - TypeScript compilation depends on these files
verify_react_build_outputs() {
  local react_out_dir="src/vs/workbench/contrib/cortexide/browser/react/out"
  local required_outputs=(
    "diff/index.js"
    "quick-edit-tsx/index.js"
    "sidebar-tsx/index.js"
    "void-editor-widgets-tsx/index.js"
    "void-onboarding/index.js"
    "void-settings-tsx/index.js"
    "void-tooltip/index.js"
  )

  if [[ ! -d "${react_out_dir}" ]]; then
    echo "ERROR: React build output directory missing: ${react_out_dir}"
    echo "This is a critical error - TypeScript compilation cannot proceed without React outputs."
    return 1
  fi

  local missing_files=()
  for output in "${required_outputs[@]}"; do
    local file_path="${react_out_dir}/${output}"
    if [[ ! -f "${file_path}" ]]; then
      missing_files+=("${file_path}")
    fi
  done

  if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo "ERROR: React build incomplete - missing required output files:"
    for file in "${missing_files[@]}"; do
      echo "  - ${file}"
    done
    echo ""
    echo "This indicates the React build failed or was interrupted."
    echo "Please check the React build output above for errors."
    return 1
  fi

  # Verify files are not empty (basic sanity check)
  local empty_files=()
  for output in "${required_outputs[@]}"; do
    local file_path="${react_out_dir}/${output}"
    if [[ ! -s "${file_path}" ]]; then
      empty_files+=("${file_path}")
    fi
  done

  if [[ ${#empty_files[@]} -gt 0 ]]; then
    echo "ERROR: React build produced empty output files:"
    for file in "${empty_files[@]}"; do
      echo "  - ${file}"
    done
    echo ""
    echo "This indicates the React build failed silently."
    return 1
  fi

  echo "✓ React build outputs verified: all required files present and valid"
  return 0
}

# Build React components with comprehensive error handling
build_react_components() {
  local max_retries=2
  local retry_count=0

  echo "Building React components (required for TypeScript compilation)..."

  while [[ ${retry_count} -lt ${max_retries} ]]; do
    # Run React build with explicit error handling
    if npm run buildreact 2>&1 | tee /tmp/react-build.log; then
      # Build command succeeded, verify outputs
      if verify_react_build_outputs; then
        echo "✓ React build completed successfully"
        rm -f /tmp/react-build.log
        return 0
      else
        echo "WARNING: React build command succeeded but outputs are invalid"
        if [[ ${retry_count} -lt $((max_retries - 1)) ]]; then
          echo "Retrying React build (attempt $((retry_count + 2))/${max_retries})..."
          retry_count=$((retry_count + 1))
          sleep 2
          continue
        else
          echo "ERROR: React build failed after ${max_retries} attempts"
          echo "Last build log:"
          tail -50 /tmp/react-build.log || true
          rm -f /tmp/react-build.log
          return 1
        fi
      fi
    else
      # Build command failed
      local exit_code=${PIPESTATUS[0]}
      echo "ERROR: React build command failed with exit code ${exit_code}"
      if [[ ${retry_count} -lt $((max_retries - 1)) ]]; then
        echo "Retrying React build (attempt $((retry_count + 2))/${max_retries})..."
        retry_count=$((retry_count + 1))
        sleep 2
        continue
      else
        echo "ERROR: React build failed after ${max_retries} attempts"
        echo "Build log:"
        cat /tmp/react-build.log || true
        rm -f /tmp/react-build.log
        return 1
      fi
    fi
  done

  rm -f /tmp/react-build.log
  return 1
}
