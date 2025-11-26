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

if [[ -f "fix_css_imports.js" ]]; then
    # Make files writable
    echo "Making files writable..."
    chmod -R u+w "${APP_OUT_DIR}" 2>/dev/null || {
        echo "Error: Cannot make files writable. You may need to run:"
        echo "  sudo chmod -R u+w ${APP_OUT_DIR}"
        exit 1
    }
    
    # Run the fix
    if node fix_css_imports.js "${APP_OUT_DIR}"; then
        echo "✓ Fixed CSS imports in installed app"
        echo "Please restart CortexIDE for changes to take effect"
    else
        echo "✗ Failed to fix CSS imports"
        exit 1
    fi
else
    echo "Error: fix_css_imports.js not found in current directory"
    exit 1
fi

