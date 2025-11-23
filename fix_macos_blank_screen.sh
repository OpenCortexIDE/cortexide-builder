#!/bin/bash

# Fix macOS Blank Screen Issue for CortexIDE
# This script helps diagnose and fix blank screen issues after installation

set -e

APP_NAME="CortexIDE"
APP_PATH="/Applications/${APP_NAME}.app"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/${APP_NAME}"
CACHE_DIR="${HOME}/Library/Caches/${APP_NAME}"

echo "=========================================="
echo "CortexIDE macOS Blank Screen Fix"
echo "=========================================="
echo ""

# Check if app exists
if [[ ! -d "${APP_PATH}" ]]; then
    echo "❌ Error: ${APP_PATH} not found!"
    echo "   Please ensure CortexIDE is installed in /Applications/"
    exit 1
fi

echo "✓ Found app at: ${APP_PATH}"
echo ""

# Check if app is running and warn user
if pgrep -f "${APP_NAME}" > /dev/null 2>&1; then
    echo "⚠ Warning: ${APP_NAME} appears to be running!"
    echo "   For best results, please quit the app (Cmd+Q) before running this script."
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. Please quit ${APP_NAME} and try again."
        exit 0
    fi
    echo ""
fi

# Function to check if a file exists
check_file() {
    local file_path="$1"
    local description="$2"
    
    if [[ -f "${file_path}" ]]; then
        echo "✓ ${description} exists"
        return 0
    else
        echo "❌ ${description} MISSING: ${file_path}"
        return 1
    fi
}

# Step 1: Verify critical files
echo "Step 1: Verifying critical files in app bundle..."
echo "---------------------------------------------------"

WORKBENCH_HTML="${APP_PATH}/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html"
MAIN_JS="${APP_PATH}/Contents/Resources/app/out/main.js"

critical_files_ok=true
check_file "${WORKBENCH_HTML}" "workbench.html" || critical_files_ok=false
check_file "${MAIN_JS}" "main.js" || critical_files_ok=false

if [[ "${critical_files_ok}" == "false" ]]; then
    echo ""
    echo "❌ Critical files are missing from the app bundle!"
    echo "   This indicates a build problem. You may need to rebuild the application."
    echo ""
    read -p "Continue with cache clearing anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "✓ All critical files present"
fi

echo ""

# Step 2: Clear GPU cache
echo "Step 2: Clearing GPU and renderer caches..."
echo "---------------------------------------------------"

# Function to safely delete directory and verify
delete_cache_dir() {
    local dir_path="$1"
    local dir_name="$2"
    
    if [[ -d "${dir_path}" ]]; then
        echo "  Removing ${dir_name}..."
        # Try to delete, capture both stdout and stderr
        if rm -rf "${dir_path}" 2>&1; then
            # Wait a moment for filesystem to sync
            sleep 0.1
            # Verify deletion
            if [[ ! -d "${dir_path}" ]] && [[ ! -e "${dir_path}" ]]; then
                echo "  ✓ ${dir_name} deleted successfully"
                return 0
            else
                echo "  ⚠ Warning: ${dir_name} still exists after deletion attempt"
                echo "     This may happen if files are locked. Try quitting the app and running again."
                return 1
            fi
        else
            echo "  ❌ Error: Failed to delete ${dir_name}"
            echo "     The directory may be locked or in use."
            return 1
        fi
    else
        echo "  ℹ ${dir_name} not found (may not exist yet)"
        return 0
    fi
}

# Delete cache directories
deleted_count=0
total_count=0

if [[ -d "${APP_SUPPORT_DIR}/GPUCache" ]]; then
    total_count=$((total_count + 1))
    delete_cache_dir "${APP_SUPPORT_DIR}/GPUCache" "GPUCache" && deleted_count=$((deleted_count + 1))
fi

if [[ -d "${APP_SUPPORT_DIR}/Code Cache" ]]; then
    total_count=$((total_count + 1))
    delete_cache_dir "${APP_SUPPORT_DIR}/Code Cache" "Code Cache" && deleted_count=$((deleted_count + 1))
fi

if [[ -d "${CACHE_DIR}" ]]; then
    total_count=$((total_count + 1))
    delete_cache_dir "${CACHE_DIR}" "Application cache" && deleted_count=$((deleted_count + 1))
fi

# Also check for ShaderCache and other Electron cache directories
SHADER_CACHE="${APP_SUPPORT_DIR}/ShaderCache"
if [[ -d "${SHADER_CACHE}" ]]; then
    total_count=$((total_count + 1))
    delete_cache_dir "${SHADER_CACHE}" "ShaderCache" && deleted_count=$((deleted_count + 1))
fi

# Check for any remaining cache files in the support directory
if [[ -d "${APP_SUPPORT_DIR}" ]]; then
    CACHE_FILES=$(find "${APP_SUPPORT_DIR}" -type d \( -name "*Cache" -o -name "*cache" \) 2>/dev/null | grep -v "^$" || true)
    if [[ -n "${CACHE_FILES}" ]]; then
        echo ""
        echo "  Found additional cache directories:"
        while IFS= read -r cache_dir; do
            if [[ -d "${cache_dir}" ]]; then
                total_count=$((total_count + 1))
                cache_name=$(basename "${cache_dir}")
                delete_cache_dir "${cache_dir}" "${cache_name}" && deleted_count=$((deleted_count + 1))
            fi
        done <<< "${CACHE_FILES}"
    fi
fi

echo ""
if [[ ${total_count} -gt 0 ]]; then
    echo "  Summary: Deleted ${deleted_count} of ${total_count} cache directories"
else
    echo "  ℹ No cache directories found to delete"
fi

echo ""

# Step 3: Check for console errors
echo "Step 3: Diagnostic information..."
echo "---------------------------------------------------"
echo "  App bundle: ${APP_PATH}"
echo "  Support dir: ${APP_SUPPORT_DIR}"
echo "  Cache dir: ${CACHE_DIR}"
echo ""

# Step 4: Provide next steps
echo "Step 4: Next steps..."
echo "---------------------------------------------------"
echo ""
echo "✓ Cache clearing complete!"
echo ""
echo "Please try the following:"
echo ""
echo "1. Quit CortexIDE completely (Cmd+Q if it's running)"
echo ""
echo "2. Launch CortexIDE again from /Applications/"
echo ""
echo "3. If the blank screen persists, try launching from Terminal with:"
echo "   ${APP_PATH}/Contents/MacOS/${APP_NAME} --disable-gpu"
echo ""
echo "4. Check Console.app for errors:"
echo "   - Open Console.app (Applications → Utilities → Console)"
echo "   - Filter for 'CortexIDE' or 'Electron'"
echo "   - Look for rendering or GPU errors"
echo ""
echo "5. If still not working, you may need to:"
echo "   - Rebuild the application"
echo "   - Check build logs for errors during minify-vscode step"
echo "   - Verify workbench.html was generated correctly"
echo ""
echo "For more troubleshooting steps, see:"
echo "  docs/troubleshooting.md#macos-blank-screen"
echo ""

