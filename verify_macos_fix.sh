#!/bin/bash

# Quick verification script to check if macOS window visibility fix is in the built app

APP_NAME="CortexIDE"
APP_PATH="/Applications/${APP_NAME}.app"

# Allow custom app path via first argument
if [[ -n "${1}" ]]; then
    APP_PATH="${1}"
fi

# VS Code bundles all main process code into main.js, not separate files
MAIN_JS="${APP_PATH}/Contents/Resources/app/out/main.js"

if [[ ! -f "${MAIN_JS}" ]]; then
    echo "❌ Compiled main.js file not found: ${MAIN_JS}"
    echo "   The app may not be installed or the build may be incomplete."
    exit 1
fi

echo "Checking for window visibility fix in compiled code..."
echo "File: ${MAIN_JS}"
echo ""

# Check for various markers of the fix in the bundled main.js
FIX_FOUND=false

# Check for ready-to-show event handler with macOS-specific code
if grep -q "ready-to-show.*window ready, ensuring visibility on macOS" "${MAIN_JS}" 2>/dev/null || \
   grep -q "ready-to-show.*macOS" "${MAIN_JS}" 2>/dev/null; then
    echo "✓ Found: ready-to-show event handler for macOS"
    FIX_FOUND=true
fi

# Check for showInactive calls (minified code may have different patterns)
if grep -q "showInactive" "${MAIN_JS}" 2>/dev/null; then
    echo "✓ Found: showInactive() calls"
    FIX_FOUND=true
fi

# Check for window visibility forcing code
if grep -q "forcing window to show on macOS" "${MAIN_JS}" 2>/dev/null || \
   grep -q "window.*isVisible.*showInactive" "${MAIN_JS}" 2>/dev/null; then
    echo "✓ Found: Window visibility forcing code"
    FIX_FOUND=true
fi

# Check for invalid bounds detection
if grep -q "invalid window bounds detected" "${MAIN_JS}" 2>/dev/null || \
   grep -q "invalid bounds, resetting" "${MAIN_JS}" 2>/dev/null; then
    echo "✓ Found: Window bounds validation code"
    FIX_FOUND=true
fi

# Check for error handling for failed loads
if grep -q "Failed to load workbench on macOS" "${MAIN_JS}" 2>/dev/null; then
    echo "✓ Found: Error handling for failed workbench loads"
    FIX_FOUND=true
fi

# Check for renderer process crash handling
if grep -q "Renderer process crashed on macOS" "${MAIN_JS}" 2>/dev/null; then
    echo "✓ Found: Renderer process crash handling"
    FIX_FOUND=true
fi

if [[ "${FIX_FOUND}" == "true" ]]; then
    echo ""
    echo "✅ Window visibility fix appears to be present in the compiled code."
    echo ""
    echo "If you're still experiencing blank screen issues, try:"
    echo "  1. Run: ./debug_macos_app.sh"
    echo "  2. Check Console.app for errors"
    echo "  3. Clear GPU cache: rm -rf ~/Library/Application\\ Support/CortexIDE/GPUCache"
    echo "  4. Launch with --disable-gpu flag"
    exit 0
else
    echo ""
    echo "❌ Window visibility fix NOT FOUND in compiled code!"
    echo ""
    echo "This means the fix was not included in the build."
    echo "Please rebuild the application to include the fix."
    exit 1
fi

