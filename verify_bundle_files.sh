#!/usr/bin/env bash
# Verification script to check if all required files are present in the app bundle
# This helps diagnose ERR_FILE_NOT_FOUND errors at runtime

set -e

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-app-bundle-or-package>" >&2
  echo "Examples:" >&2
  echo "  $0 /Applications/CortexIDE.app" >&2
  echo "  $0 ../VSCode-win32-x64" >&2
  echo "  $0 ../VSCode-linux-x64" >&2
  exit 1
fi

APP_BUNDLE="$1"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "ERROR: Bundle path not found: ${APP_BUNDLE}" >&2
  exit 1
fi

# Determine the correct out directory (macOS .app vs Windows/Linux package)
if [[ -d "${APP_BUNDLE}/Contents/Resources/app/out" ]]; then
  APP_OUT_DIR="${APP_BUNDLE}/Contents/Resources/app/out"
elif [[ -d "${APP_BUNDLE}/resources/app/out" ]]; then
  APP_OUT_DIR="${APP_BUNDLE}/resources/app/out"
else
  echo "ERROR: Could not find resources/app/out within ${APP_BUNDLE}" >&2
  echo "  Checked:" >&2
  echo "    ${APP_BUNDLE}/Contents/Resources/app/out" >&2
  echo "    ${APP_BUNDLE}/resources/app/out" >&2
  exit 1
fi

echo "Verifying files in: ${APP_OUT_DIR}"
echo ""

# Critical files that must exist
CRITICAL_FILES=(
  "main.js"
  "cli.js"
  "vs/workbench/workbench.desktop.main.js"
  "vs/code/electron-browser/workbench/workbench.html"
  "vs/code/electron-browser/workbench/workbench.js"
)

# Files that are commonly missing (from error logs)
COMMON_MISSING_FILES=(
  "vs/base/common/lifecycle.js"
  "vs/platform/theme/common/theme.js"
  "vs/platform/theme/common/themeService.js"
  "vs/base/common/uri.js"
  "vs/base/common/path.js"
  "vs/platform/instantiation/common/instantiation.js"
  "vs/platform/commands/common/commands.js"
  "vs/platform/contextkey/common/contextkey.js"
  "vs/platform/files/common/files.js"
  "vs/editor/common/services/model.js"
  "vs/workbench/contrib/files/browser/files.js"
)

echo "=== Critical Files ==="
MISSING_CRITICAL=0
for file in "${CRITICAL_FILES[@]}"; do
  full_path="${APP_OUT_DIR}/${file}"
  if [[ -f "${full_path}" ]]; then
    echo "✓ ${file}"
  else
    echo "✗ MISSING: ${file}"
    MISSING_CRITICAL=$((MISSING_CRITICAL + 1))
  fi
done

echo ""
echo "=== Commonly Missing Files (from error logs) ==="
MISSING_COMMON=0
for file in "${COMMON_MISSING_FILES[@]}"; do
  full_path="${APP_OUT_DIR}/${file}"
  if [[ -f "${full_path}" ]]; then
    echo "✓ ${file}"
  else
    echo "✗ MISSING: ${file}"
    MISSING_COMMON=$((MISSING_COMMON + 1))
  fi
done

echo ""
echo "=== Statistics ==="
TOTAL_JS=$(find "${APP_OUT_DIR}" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
TOTAL_FILES=$(find "${APP_OUT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')

echo "Total JS files: ${TOTAL_JS}"
echo "Total files: ${TOTAL_FILES}"

if [[ ${MISSING_CRITICAL} -gt 0 ]]; then
  echo ""
  echo "ERROR: ${MISSING_CRITICAL} critical file(s) missing!" >&2
  echo "  The app will fail to launch." >&2
  exit 1
fi

if [[ ${MISSING_COMMON} -gt 0 ]]; then
  echo ""
  echo "WARNING: ${MISSING_COMMON} commonly required file(s) missing!" >&2
  echo "  The app may fail with ERR_FILE_NOT_FOUND errors at runtime." >&2
  echo "  This suggests a bundling or packaging issue." >&2
  exit 1
fi

echo ""
echo "✓ All files verified successfully!"

