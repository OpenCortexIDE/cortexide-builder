#!/usr/bin/env bash
# Quick fix script to remove macOS Gatekeeper quarantine attribute
# This allows the app to run after being downloaded from the internet

set -e

APP_PATH="${1:-/Applications/CortexIDE.app}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Error: App bundle not found at: ${APP_PATH}"
    echo ""
    echo "Usage: $0 [path/to/CortexIDE.app]"
    echo ""
    echo "Examples:"
    echo "  $0 /Applications/CortexIDE.app"
    echo "  $0 ~/Downloads/CortexIDE.app"
    echo "  $0 /Volumes/CortexIDE/CortexIDE.app"
    exit 1
fi

echo "Removing quarantine attribute from: ${APP_PATH}"
echo ""

# Check if quarantine attribute exists
if xattr -l "${APP_PATH}" 2>/dev/null | grep -q "com.apple.quarantine"; then
    echo "Quarantine attribute found. Removing..."
    sudo xattr -rd com.apple.quarantine "${APP_PATH}" || {
        echo "Error: Failed to remove quarantine attribute"
        echo "You may need to enter your password for sudo"
        exit 1
    }
    echo "✓ Quarantine attribute removed"
else
    echo "No quarantine attribute found (app may already be allowed)"
fi

echo ""
echo "Verifying app can be opened..."
if spctl --assess --verbose "${APP_PATH}" 2>&1 | grep -q "accepted"; then
    echo "✓ App is accepted by Gatekeeper"
else
    echo "⚠ App may still be blocked by Gatekeeper"
    echo ""
    echo "If you still see 'damaged' error, try:"
    echo "  1. System Settings > Privacy & Security > Allow app from developer"
    echo "  2. Or right-click the app > Open (this bypasses Gatekeeper once)"
fi

echo ""
echo "Done! You can now try opening the app."

