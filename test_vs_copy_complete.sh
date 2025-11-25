#!/bin/bash
# Comprehensive test for the vs/ copy fix
set -euo pipefail

echo "=== COMPREHENSIVE TEST OF VS/ COPY FIX ==="
echo ""

TEST_DIR="/tmp/test_vs_copy_complete_$$"
mkdir -p "${TEST_DIR}"
trap "rm -rf ${TEST_DIR}" EXIT

# Create realistic directory structure
mkdir -p "${TEST_DIR}/out-vscode-min/vs/platform/files/common"
mkdir -p "${TEST_DIR}/out-vscode-min/vs/base/common"
mkdir -p "${TEST_DIR}/out-build/vs/platform/files/common"
mkdir -p "${TEST_DIR}/out-build/vs/base/common"
mkdir -p "${TEST_DIR}/out-build/vs/platform/theme/common"
mkdir -p "${TEST_DIR}/dest"

# Create test files - some in both, some only in one
echo "// files.js from min" > "${TEST_DIR}/out-vscode-min/vs/platform/files/common/files.js"
echo "// model.js from build only" > "${TEST_DIR}/out-build/vs/platform/files/common/model.js"
echo "// lifecycle.js from both" > "${TEST_DIR}/out-vscode-min/vs/base/common/lifecycle.js"
echo "// lifecycle.js from both" > "${TEST_DIR}/out-build/vs/base/common/lifecycle.js"
echo "// theme.js from build only" > "${TEST_DIR}/out-build/vs/platform/theme/common/theme.js"

echo "Test 1: Copy from out-vscode-min..."
COPIED_ANY=0
if [[ -d "${TEST_DIR}/out-vscode-min/vs" ]]; then
  if rsync -a --include="vs/" --include="vs/**" --exclude="*" "${TEST_DIR}/out-vscode-min/" "${TEST_DIR}/dest/" 2>&1 >/dev/null; then
    COUNT=$(find "${TEST_DIR}/dest/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✓ Copied ${COUNT} files from out-vscode-min"
    COPIED_ANY=1
  fi
fi

echo ""
echo "Test 2: Merge from out-build..."
if [[ -d "${TEST_DIR}/out-build/vs" ]]; then
  if rsync -a --include="vs/" --include="vs/**" --exclude="*" "${TEST_DIR}/out-build/" "${TEST_DIR}/dest/" 2>&1 >/dev/null; then
    FINAL_COUNT=$(find "${TEST_DIR}/dest/vs" -type f -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✓ Merged from out-build: ${FINAL_COUNT} total files"
    COPIED_ANY=1
  fi
fi

echo ""
echo "Test 3: Verify all files are present..."
MISSING=0
for file in "vs/platform/files/common/files.js" "vs/platform/files/common/model.js" "vs/base/common/lifecycle.js" "vs/platform/theme/common/theme.js"; do
  if [[ -f "${TEST_DIR}/dest/${file}" ]]; then
    echo "  ✓ ${file}"
  else
    echo "  ✗ MISSING: ${file}"
    MISSING=$((MISSING + 1))
  fi
done

echo ""
if [[ $MISSING -eq 0 && $COPIED_ANY -eq 1 ]]; then
  echo "✅ ALL TESTS PASSED!"
  echo "  - Files from out-vscode-min: ✓"
  echo "  - Files from out-build: ✓"
  echo "  - Merge works correctly: ✓"
  echo "  - All required files present: ✓"
  exit 0
else
  echo "❌ TESTS FAILED!"
  echo "  Missing files: ${MISSING}"
  echo "  COPIED_ANY: ${COPIED_ANY}"
  exit 1
fi

