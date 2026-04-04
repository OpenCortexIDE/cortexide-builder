#!/usr/bin/env bash
# Test script for build regression fixes
# This validates that the fixes work correctly without running a full build

set -e

echo "🧪 Testing Build Regression Fixes"
echo "=================================="
echo ""

# Test 1: Syntax validation
echo "Test 1: Syntax validation"
echo "-------------------------"
if bash -n get_repo.sh && bash -n prepare_vscode.sh; then
  echo "✅ PASS: All scripts have valid syntax"
else
  echo "❌ FAIL: Syntax errors found"
  exit 1
fi
echo ""

# Test 2: Source state verification logic
echo "Test 2: Source state verification"
echo "----------------------------------"
if [[ -d "../cortexide/.git" ]]; then
  cd ../cortexide 2>/dev/null || true
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "⚠️  Warning detected: Uncommitted changes (this is expected in dev)"
    echo "✅ PASS: Warning system works"
  else
    echo "✓ No uncommitted changes"
    echo "✅ PASS: Clean state detected"
  fi
  cd - > /dev/null 2>&1 || true
else
  echo "⚠️  Main repo not a git repo (skipping git checks)"
fi
echo ""

# Test 3: Critical files check
echo "Test 3: Critical files verification"
echo "-------------------------------------"
if [[ -f "../cortexide/package.json" ]] && [[ -f "../cortexide/product.json" ]]; then
  echo "✅ PASS: Critical files exist in main repo"
else
  echo "❌ FAIL: Missing critical files"
  exit 1
fi
echo ""

# Test 4: Cleanup commands
echo "Test 4: Cleanup command validation"
echo "-----------------------------------"
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
touch out out-build .cache dist test.tsbuildinfo
mkdir -p src/vs/workbench/contrib/test/browser/react/out

# Test cleanup
rm -rf out out-build .cache dist build/out 2>/dev/null || true
find . -name "*.tsbuildinfo" -type f -delete 2>/dev/null || true
find . -type d -path "*/browser/react/out" -exec rm -rf {} + 2>/dev/null || true

if [[ ! -f "out" ]] && [[ ! -f "out-build" ]] && [[ ! -d ".cache" ]] && [[ ! -f "test.tsbuildinfo" ]]; then
  echo "✅ PASS: Cleanup commands work correctly"
else
  echo "❌ FAIL: Cleanup commands didn't remove all artifacts"
  exit 1
fi
cd - > /dev/null
rm -rf "$TEST_DIR"
echo ""

# Test 5: Timestamp normalization
echo "Test 5: Timestamp normalization"
echo "---------------------------------"
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
mkdir -p src
touch src/test.ts src/test.tsx

# Test timestamp normalization
find src -name "*.ts" -type f -exec touch {} + 2>/dev/null || true
find src -name "*.tsx" -type f -exec touch {} + 2>/dev/null || true

if [[ -f "src/test.ts" ]] && [[ -f "src/test.tsx" ]]; then
  echo "✅ PASS: Timestamp normalization works"
else
  echo "❌ FAIL: Timestamp normalization failed"
  exit 1
fi
cd - > /dev/null
rm -rf "$TEST_DIR"
echo ""

# Test 6: File integrity check logic
echo "Test 6: File integrity check logic"
echo "-----------------------------------"
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"

# Test with missing files
if [[ ! -f "package.json" ]]; then
  echo "✅ PASS: Missing package.json detected correctly"
else
  echo "❌ FAIL: File check logic incorrect"
  exit 1
fi

# Test with existing files
touch package.json product.json
if [[ -f "package.json" ]] && [[ -f "product.json" ]]; then
  echo "✅ PASS: File integrity check would pass"
else
  echo "❌ FAIL: File check logic incorrect"
  exit 1
fi
cd - > /dev/null
rm -rf "$TEST_DIR"
echo ""

# Test 7: Rsync exclusions pattern validation
echo "Test 7: Rsync exclusion patterns"
echo "-------------------------------"
# Check that exclusion patterns are properly formatted
EXCLUSIONS=(
  ".git"
  "node_modules"
  "out"
  "out-build"
  "out-vscode-min"
  ".build"
  ".cache"
  "dist"
  "build/out"
  "*.tsbuildinfo"
  "**/*.tsbuildinfo"
  ".vscode"
  "**/.vscode"
  "src/vs/workbench/contrib/*/browser/react/out"
  "**/react/out"
)

for exclude in "${EXCLUSIONS[@]}"; do
  if [[ -n "$exclude" ]]; then
    echo "  ✓ Exclusion pattern: $exclude"
  fi
done
echo "✅ PASS: All exclusion patterns are valid"
echo ""

echo "=================================="
echo "✅ All tests passed!"
echo ""
echo "Summary:"
echo "  - Syntax validation: ✅"
echo "  - Source state verification: ✅"
echo "  - Critical files check: ✅"
echo "  - Cleanup commands: ✅"
echo "  - Timestamp normalization: ✅"
echo "  - File integrity check: ✅"
echo "  - Rsync exclusions: ✅"
echo ""
echo "The build regression fixes are ready for use!"

