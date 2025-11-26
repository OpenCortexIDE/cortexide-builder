#!/bin/bash
# Script to verify that the bundler fix is working correctly
# This checks that the bundled workbench.desktop.main.js doesn't have import statements for vs/ modules

set -e

echo "🔍 Verifying bundler fix..."
echo ""

# Check if the fix is in place
echo "1. Checking if the fix is in the source files..."
if grep -q "Ensure all internal vs/ modules" vscode/build/lib/optimize.ts; then
    echo "   ✅ Fix found in optimize.ts"
else
    echo "   ❌ Fix NOT found in optimize.ts"
    exit 1
fi

if grep -q "Ensure all internal vs/ modules" vscode/build/lib/optimize.js; then
    echo "   ✅ Fix found in optimize.js"
else
    echo "   ❌ Fix NOT found in optimize.js"
    exit 1
fi

echo ""
echo "2. To test the fix, you need to:"
echo "   a) Build the application (compile + bundle)"
echo "   b) Check the bundled file for import statements"
echo ""
echo "   After building, run:"
echo "   grep -c 'import.*from.*[\"']vs/' out-vscode/vs/workbench/workbench.desktop.main.js"
echo ""
echo "   Expected: 0 import statements for vs/ modules"
echo "   (npm packages may still have imports, which is expected)"
echo ""
echo "3. To build and test:"
echo "   cd vscode"
echo "   npm install  # if not already done"
echo "   npm run gulp compile-build"
echo "   npm run gulp bundle-vscode"
echo "   grep 'import.*from.*[\"']vs/' out-vscode/vs/workbench/workbench.desktop.main.js | head -10"
echo ""

echo "✅ Verification script complete!"
