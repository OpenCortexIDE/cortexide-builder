#!/bin/bash

# Debug script for macOS blank screen issue
# This script launches CortexIDE with verbose logging to help diagnose issues

set -e

APP_NAME="CortexIDE"
APP_PATH="/Applications/${APP_NAME}.app"

# Auto-detect executable name from Info.plist or MacOS directory
if [[ -f "${APP_PATH}/Contents/Info.plist" ]]; then
    EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")
fi

# Fallback: check what's actually in MacOS directory
if [[ -z "${EXECUTABLE_NAME}" || "${EXECUTABLE_NAME}" == "" ]]; then
    if [[ -d "${APP_PATH}/Contents/MacOS" ]]; then
        # Get the first executable file in MacOS directory
        EXECUTABLE_NAME=$(ls -1 "${APP_PATH}/Contents/MacOS" | head -1)
    fi
fi

# Final fallback
if [[ -z "${EXECUTABLE_NAME}" || "${EXECUTABLE_NAME}" == "" ]]; then
    EXECUTABLE_NAME="${APP_NAME}"
fi

EXECUTABLE="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
LOG_DIR="${HOME}/Library/Logs/${APP_NAME}"
LOG_FILE="${LOG_DIR}/debug-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "CortexIDE macOS Debug Launcher"
echo "=========================================="
echo ""

# Check if app exists
if [[ ! -d "${APP_PATH}" ]]; then
    echo -e "${RED}❌ Error: ${APP_PATH} not found!${NC}"
    echo "   Please ensure CortexIDE is installed in /Applications/"
    exit 1
fi

# Check if executable exists
if [[ ! -f "${EXECUTABLE}" ]]; then
    echo -e "${RED}❌ Error: Executable not found at ${EXECUTABLE}${NC}"
    exit 1
fi

# Create log directory
mkdir -p "${LOG_DIR}"

echo -e "${GREEN}✓ Found app at: ${APP_PATH}${NC}"
echo -e "${GREEN}✓ Executable: ${EXECUTABLE_NAME}${NC}"
echo ""

# Check if app is already running
if pgrep -f "${APP_NAME}" > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: ${APP_NAME} appears to be running!${NC}"
    echo "   For best results, please quit the app (Cmd+Q) before running this script."
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# Verify critical files
echo "Step 1: Verifying critical files..."
echo "---------------------------------------------------"

WORKBENCH_HTML="${APP_PATH}/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html"
MAIN_JS="${APP_PATH}/Contents/Resources/app/out/main.js"
PRODUCT_JSON="${APP_PATH}/Contents/Resources/app/product.json"

critical_files_ok=true

if [[ -f "${WORKBENCH_HTML}" ]]; then
    echo -e "${GREEN}✓ workbench.html exists${NC}"
else
    echo -e "${RED}❌ workbench.html MISSING: ${WORKBENCH_HTML}${NC}"
    critical_files_ok=false
fi

if [[ -f "${MAIN_JS}" ]]; then
    echo -e "${GREEN}✓ main.js exists${NC}"
else
    echo -e "${RED}❌ main.js MISSING: ${MAIN_JS}${NC}"
    critical_files_ok=false
fi

if [[ -f "${PRODUCT_JSON}" ]]; then
    echo -e "${GREEN}✓ product.json exists${NC}"
    # Check if extensionsGallery is correct
    if command -v jq >/dev/null 2>&1; then
        if jq -e '.extensionsGallery.serviceUrl | contains("open-vsx")' "${PRODUCT_JSON}" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ extensionsGallery is correctly configured${NC}"
        else
            echo -e "${YELLOW}⚠ extensionsGallery may be misconfigured${NC}"
        fi
    fi
else
    echo -e "${RED}❌ product.json MISSING: ${PRODUCT_JSON}${NC}"
    critical_files_ok=false
fi

if [[ "${critical_files_ok}" == "false" ]]; then
    echo ""
    echo -e "${RED}❌ Critical files are missing! The app bundle may be incomplete.${NC}"
    echo "   Please rebuild the application."
    exit 1
fi

echo ""
echo "Step 2: Checking window visibility fix..."
echo "---------------------------------------------------"

# Check if the compiled code contains the window visibility fix
# We'll check the compiled JS file
COMPILED_WINDOW="${APP_PATH}/Contents/Resources/app/out/vs/platform/windows/electron-main/windowImpl.js"

if [[ -f "${COMPILED_WINDOW}" ]]; then
    if grep -q "macOS: Comprehensive fix for blank screen" "${COMPILED_WINDOW}" 2>/dev/null || \
       grep -q "Fix for macOS blank screen" "${COMPILED_WINDOW}" 2>/dev/null || \
       grep -q "ensureWindowVisible" "${COMPILED_WINDOW}" 2>/dev/null; then
        echo -e "${GREEN}✓ Window visibility fix detected in compiled code${NC}"
    else
        echo -e "${YELLOW}⚠ Window visibility fix may not be present in compiled code${NC}"
        echo "   This could cause blank screen issues."
    fi
else
    echo -e "${YELLOW}⚠ Cannot verify window visibility fix (compiled file not found)${NC}"
fi

echo ""
echo "Step 3: Clearing caches (optional)..."
echo "---------------------------------------------------"
echo "This will clear GPU cache and other caches that might cause rendering issues."
read -p "Clear caches? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    APP_SUPPORT_DIR="${HOME}/Library/Application Support/${APP_NAME}"
    CACHE_DIR="${HOME}/Library/Caches/${APP_NAME}"
    
    if [[ -d "${APP_SUPPORT_DIR}/GPUCache" ]]; then
        rm -rf "${APP_SUPPORT_DIR}/GPUCache"
        echo -e "${GREEN}✓ Cleared GPUCache${NC}"
    fi
    
    if [[ -d "${APP_SUPPORT_DIR}/Code Cache" ]]; then
        rm -rf "${APP_SUPPORT_DIR}/Code Cache"
        echo -e "${GREEN}✓ Cleared Code Cache${NC}"
    fi
    
    if [[ -d "${CACHE_DIR}" ]]; then
        rm -rf "${CACHE_DIR}"/*
        echo -e "${GREEN}✓ Cleared application caches${NC}"
    fi
fi

echo ""
echo "Step 4: Launching with debug logging..."
echo "---------------------------------------------------"
echo "Log file: ${LOG_FILE}"
echo ""
echo "Launching with the following flags:"
echo "  --enable-logging (enable Chromium logging)"
echo "  --log-level=0 (verbose logging)"
echo "  --enable-logging=stderr (log to stderr)"
echo ""

# Launch the app with verbose logging
# Redirect both stdout and stderr to log file and terminal
echo "Starting ${APP_NAME}..." | tee -a "${LOG_FILE}"
echo "Timestamp: $(date)" | tee -a "${LOG_FILE}"
DEBUG_ARGS=(--enable-logging --log-level=0 --enable-logging=stderr)
echo "Command: ELECTRON_RUN_AS_NODE=0 ${EXECUTABLE} ${DEBUG_ARGS[*]}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Launch in background and capture output
ELECTRON_RUN_AS_NODE=0 "${EXECUTABLE}" "${DEBUG_ARGS[@]}" 2>&1 | tee -a "${LOG_FILE}" &

APP_PID=$!

echo ""
echo -e "${GREEN}✓ App launched (PID: ${APP_PID})${NC}"
echo ""
echo "The app is now running with verbose logging enabled."
echo ""
echo "What to do next:"
echo "  1. Watch the terminal for error messages"
echo "  2. Check Console.app (Applications → Utilities → Console)"
echo "     - Filter for 'CortexIDE' or 'Electron'"
echo "     - Look for errors related to:"
echo "       * Window creation"
echo "       * workbench.html loading"
echo "       * GPU/rendering issues"
echo "       * File not found errors"
echo "  3. Check the log file: ${LOG_FILE}"
echo ""
echo "Common issues to look for:"
echo "  - 'Failed to load workbench' → workbench.html may be missing"
echo "  - 'Renderer process crashed' → GPU/rendering issue"
echo "  - 'Window not visible' → Window visibility fix may not be working"
echo "  - 'Invalid window bounds' → Window size issue"
echo ""
echo "To stop the app, press Ctrl+C or quit it normally (Cmd+Q)"
echo ""
echo "Waiting for app to start (will monitor for 30 seconds)..."
echo ""

# Monitor for 30 seconds
for i in {1..30}; do
    sleep 1
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        echo ""
        echo -e "${RED}⚠ App process exited unexpectedly (PID: ${APP_PID})${NC}"
        echo "   Check the log file for errors: ${LOG_FILE}"
        exit 1
    fi
    if [[ $((i % 5)) -eq 0 ]]; then
        echo "  Still running... (${i}/30 seconds)"
    fi
done

echo ""
echo -e "${GREEN}✓ App is still running after 30 seconds${NC}"
echo ""
echo "If you see a blank screen:"
echo "  1. Check Console.app for errors (see instructions above)"
echo "  2. Try launching with --disable-gpu:"
echo "     ${EXECUTABLE} --disable-gpu"
echo "  3. Check the log file: ${LOG_FILE}"
echo "  4. Verify window visibility fix is in the compiled code"
echo ""
echo "Common issues found in your debug output:"
echo "  - TrustedTypes CSP error: This may block rendering"
echo "  - Check if window is actually visible (not just created)"
echo "  - Try: defaults delete com.cortexide.code 2>/dev/null || true"
echo ""
echo "Log file saved to: ${LOG_FILE}"
echo ""
echo "To check if window is visible, run:"
echo "  ps aux | grep -i cortexide | grep -v grep"
echo "  # If processes are running but no window, it's a visibility issue"
echo ""

