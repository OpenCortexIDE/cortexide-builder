#!/usr/bin/env bash
# Quick fix script to fix CSS imports in an already-installed app bundle
# This can be run on an existing installation

set -e

APP_PATH="${1:-/Applications/CortexIDE.app}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Error: App bundle not found at: ${APP_PATH}"
    echo "Usage: $0 [path/to/CortexIDE.app]"
    exit 1
fi

APP_OUT_DIR="${APP_PATH}/Contents/Resources/app/out/vs"

if [[ ! -d "${APP_OUT_DIR}" ]]; then
    echo "Error: App out directory not found at: ${APP_OUT_DIR}"
    exit 1
fi

echo "Fixing CSS imports in installed app: ${APP_PATH}"
echo "This requires write permissions to the app bundle..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="${SCRIPT_DIR}/fix_css_imports.js"

if [[ ! -f "${FIX_SCRIPT}" ]]; then
    echo "Error: fix_css_imports.js not found at ${FIX_SCRIPT}"
    exit 1
fi

# Make files writable using sudo
echo "Making files writable using sudo (you'll be prompted for password)..."
sudo chmod -R u+w "${APP_OUT_DIR}" || {
    echo "Error: Failed to make files writable. Please ensure you have sudo privileges."
    exit 1
}

# Run the fix
echo "Running CSS import fix..."
if node "${FIX_SCRIPT}" "${APP_OUT_DIR}"; then
    echo "✓ Fixed CSS imports in installed app"
    
    # Verify the fix
    CSS_IMPORT_COUNT=$(grep -r "import.*\.css" "${APP_OUT_DIR}" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ ${CSS_IMPORT_COUNT} -gt 0 ]]; then
        echo "⚠ Warning: ${CSS_IMPORT_COUNT} CSS imports still found after fix"
        echo "  This may indicate the fix didn't work completely"
    else
        echo "✓ Verified: No CSS imports found - fix successful!"
    fi
    
    echo ""
    echo "Please restart CortexIDE for changes to take effect"
else
    echo "✗ Failed to fix CSS imports"
    exit 1
fi
