#!/usr/bin/env bash
# Comprehensive test to verify the app bundle won't have blank screen issues
# This test checks for all known causes of blank screen errors

set -e

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-app-bundle-or-package>" >&2
  echo "Examples:" >&2
  echo "  $0 /Applications/CortexIDE.app" >&2
  echo "  $0 ../VSCode-darwin-x64/CortexIDE.app" >&2
  echo "  $0 ../VSCode-win32-x64" >&2
  echo "  $0 ../VSCode-linux-x64" >&2
  exit 1
fi

APP_BUNDLE="$1"
FAILED=0
WARNINGS=0

# Determine the correct out directory (macOS .app vs Windows/Linux package)
if [[ -d "${APP_BUNDLE}/Contents/Resources/app/out" ]]; then
  APP_OUT_DIR="${APP_BUNDLE}/Contents/Resources/app/out"
  BUNDLE_TYPE="macOS"
elif [[ -d "${APP_BUNDLE}/resources/app/out" ]]; then
  APP_OUT_DIR="${APP_BUNDLE}/resources/app/out"
  BUNDLE_TYPE="Windows/Linux"
else
  echo "ERROR: Could not find resources/app/out within ${APP_BUNDLE}" >&2
  exit 1
fi

echo "=========================================="
echo "Blank Screen Prevention Test"
echo "=========================================="
echo "Bundle: ${APP_BUNDLE}"
echo "Type: ${BUNDLE_TYPE}"
echo "Out directory: ${APP_OUT_DIR}"
echo ""

# Test 1: Critical files exist
echo "Test 1: Critical files check..."
CRITICAL_FILES=(
  "main.js"
  "cli.js"
  "vs/workbench/workbench.desktop.main.js"
  "vs/code/electron-browser/workbench/workbench.html"
  "vs/code/electron-browser/workbench/workbench.js"
)

MISSING_CRITICAL=0
for file in "${CRITICAL_FILES[@]}"; do
  full_path="${APP_OUT_DIR}/${file}"
  if [[ ! -f "${full_path}" ]]; then
    echo "  ✗ MISSING: ${file}" >&2
    MISSING_CRITICAL=$((MISSING_CRITICAL + 1))
    FAILED=$((FAILED + 1))
  fi
done

if [[ ${MISSING_CRITICAL} -eq 0 ]]; then
  echo "  ✓ All critical files present"
else
  echo "  ✗ ${MISSING_CRITICAL} critical file(s) missing - BLANK SCREEN RISK" >&2
fi
echo ""

# Test 2: File count validation (should have thousands of JS files, not dozens)
echo "Test 2: File count validation..."
TOTAL_JS=$(find "${APP_OUT_DIR}" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
TOTAL_FILES=$(find "${APP_OUT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')

echo "  Total JS files: ${TOTAL_JS}"
echo "  Total files: ${TOTAL_FILES}"

if [[ ${TOTAL_JS} -lt 100 ]]; then
  echo "  ✗ Too few JS files (${TOTAL_JS}) - BLANK SCREEN RISK" >&2
  echo "    Expected: 4000+ JS files" >&2
  FAILED=$((FAILED + 1))
elif [[ ${TOTAL_JS} -lt 1000 ]]; then
  echo "  ⚠ Warning: Low JS file count (${TOTAL_JS}) - may indicate missing modules" >&2
  WARNINGS=$((WARNINGS + 1))
else
  echo "  ✓ File count looks healthy"
fi
echo ""

# Test 3: Check for commonly missing modules (from error logs)
echo "Test 3: Commonly missing modules check..."
COMMON_MODULES=(
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

MISSING_MODULES=0
for file in "${COMMON_MODULES[@]}"; do
  full_path="${APP_OUT_DIR}/${file}"
  if [[ ! -f "${full_path}" ]]; then
    echo "  ✗ MISSING: ${file}" >&2
    MISSING_MODULES=$((MISSING_MODULES + 1))
    FAILED=$((FAILED + 1))
  fi
done

if [[ ${MISSING_MODULES} -eq 0 ]]; then
  echo "  ✓ All commonly required modules present"
else
  echo "  ✗ ${MISSING_MODULES} commonly required module(s) missing - BLANK SCREEN RISK" >&2
fi
echo ""

# Test 4: Validate workbench.desktop.main.js is valid JavaScript
echo "Test 4: workbench.desktop.main.js validation..."
WORKBENCH_MAIN="${APP_OUT_DIR}/vs/workbench/workbench.desktop.main.js"
if [[ -f "${WORKBENCH_MAIN}" ]]; then
  # Check if it's a valid JS file (not empty, has some content)
  if [[ ! -s "${WORKBENCH_MAIN}" ]]; then
    echo "  ✗ workbench.desktop.main.js is empty - BLANK SCREEN RISK" >&2
    FAILED=$((FAILED + 1))
  elif ! head -1 "${WORKBENCH_MAIN}" | grep -qE "(^/\*|^//|^import|^export|^\(async|^function)" 2>/dev/null; then
    echo "  ⚠ Warning: workbench.desktop.main.js doesn't look like valid JavaScript" >&2
    WARNINGS=$((WARNINGS + 1))
  else
    echo "  ✓ workbench.desktop.main.js appears valid"
  fi
  
  # Check for ES module imports that might fail
  IMPORT_COUNT=$(grep -cE "^import\s+.*from\s+['\"]vs/" "${WORKBENCH_MAIN}" 2>/dev/null || echo "0")
  IMPORT_COUNT=$(echo "${IMPORT_COUNT}" | xargs)
  IMPORT_COUNT=${IMPORT_COUNT:-0}
  if [[ ${IMPORT_COUNT} -gt 0 ]]; then
    echo "  ⚠ Warning: Found ${IMPORT_COUNT} ES module import(s) for vs/ modules" >&2
    echo "    These should be bundled, but if files are missing, will cause ERR_FILE_NOT_FOUND" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "  ✗ workbench.desktop.main.js not found - BLANK SCREEN RISK" >&2
  FAILED=$((FAILED + 1))
fi
echo ""

# Test 5: Check for CSS files (CSS import map issues)
echo "Test 5: CSS files check..."
CSS_COUNT=$(find "${APP_OUT_DIR}/vs" -name "*.css" -type f 2>/dev/null | wc -l | xargs)
CSS_COUNT=${CSS_COUNT:-0}
echo "  Total CSS files: ${CSS_COUNT}"

if [[ ${CSS_COUNT} -eq 0 ]]; then
  echo "  ⚠ Warning: No CSS files found - CSS import map may not work correctly" >&2
  WARNINGS=$((WARNINGS + 1))
else
  echo "  ✓ CSS files present"
fi
echo ""

# Test 6: Check vs/ directory structure
echo "Test 6: vs/ directory structure..."
VS_DIR="${APP_OUT_DIR}/vs"
if [[ ! -d "${VS_DIR}" ]]; then
  echo "  ✗ vs/ directory missing - BLANK SCREEN RISK" >&2
  FAILED=$((FAILED + 1))
else
  VS_JS_COUNT=$(find "${VS_DIR}" -name "*.js" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  JS files in vs/: ${VS_JS_COUNT}"
  
  if [[ ${VS_JS_COUNT} -lt 100 ]]; then
    echo "  ✗ Too few JS files in vs/ (${VS_JS_COUNT}) - BLANK SCREEN RISK" >&2
    FAILED=$((FAILED + 1))
  elif [[ ${VS_JS_COUNT} -lt 1000 ]]; then
    echo "  ⚠ Warning: Low JS file count in vs/ (${VS_JS_COUNT})" >&2
    WARNINGS=$((WARNINGS + 1))
  else
    echo "  ✓ vs/ directory has sufficient files"
  fi
fi
echo ""

# Test 7: Check workbench.html exists and references workbench.js correctly
echo "Test 7: workbench.html validation..."
WORKBENCH_HTML="${APP_OUT_DIR}/vs/code/electron-browser/workbench/workbench.html"
if [[ -f "${WORKBENCH_HTML}" ]]; then
  if grep -q "workbench.js" "${WORKBENCH_HTML}" 2>/dev/null; then
    echo "  ✓ workbench.html references workbench.js"
  else
    echo "  ⚠ Warning: workbench.html doesn't reference workbench.js" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "  ✗ workbench.html missing - BLANK SCREEN RISK" >&2
  FAILED=$((FAILED + 1))
fi
echo ""

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
if [[ ${FAILED} -eq 0 && ${WARNINGS} -eq 0 ]]; then
  echo "✓ All tests passed! Bundle should work correctly."
  exit 0
elif [[ ${FAILED} -eq 0 ]]; then
  echo "⚠ ${WARNINGS} warning(s) - Bundle may work but has potential issues"
  exit 0
else
  echo "✗ ${FAILED} critical failure(s) and ${WARNINGS} warning(s)"
  echo ""
  echo "This bundle will likely show a blank screen when launched."
  echo "Please rebuild with the latest fixes from the repository."
  exit 1
fi

