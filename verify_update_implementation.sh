#!/bin/bash
# Script to verify auto-update implementation in CortexIDE

set -e

echo "=========================================="
echo "CortexIDE Auto-Update Implementation Check"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORTEXIDE_REPO="${SCRIPT_DIR}/../cortexide"
BUILDER_REPO="${SCRIPT_DIR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ISSUES=0
WARNINGS=0

check() {
    local description="$1"
    local command="$2"
    local expected="$3"
    
    echo -n "Checking: ${description}... "
    if eval "$command" | grep -q "$expected" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        ISSUES=$((ISSUES + 1))
        return 1
    fi
}

warn() {
    local description="$1"
    echo -e "${YELLOW}⚠ Warning: ${description}${NC}"
    WARNINGS=$((WARNINGS + 1))
}

echo "1. PATCH VERIFICATION"
echo "---------------------"

if [[ ! -f "${BUILDER_REPO}/patches/version-1-update.patch" ]]; then
    echo -e "${RED}✗ version-1-update.patch not found${NC}"
    ISSUES=$((ISSUES + 1))
else
    echo -e "${GREEN}✓ version-1-update.patch exists${NC}"
fi

echo ""
echo "2. SOURCE CODE VERIFICATION"
echo "---------------------------"

# Check if patch types exist
if grep -q "export type Architecture" "${CORTEXIDE_REPO}/src/vs/platform/update/common/update.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ Architecture type exists${NC}"
else
    echo -e "${RED}✗ Architecture type missing (patch may not be applied)${NC}"
    ISSUES=$((ISSUES + 1))
fi

if grep -q "export type Platform" "${CORTEXIDE_REPO}/src/vs/platform/update/common/update.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ Platform type exists${NC}"
else
    echo -e "${RED}✗ Platform type missing (patch may not be applied)${NC}"
    ISSUES=$((ISSUES + 1))
fi

if grep -q "export type Target" "${CORTEXIDE_REPO}/src/vs/platform/update/common/update.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ Target type exists${NC}"
else
    echo -e "${RED}✗ Target type missing (patch may not be applied)${NC}"
    ISSUES=$((ISSUES + 1))
fi

# Check createUpdateURL signature
if grep -q "createUpdateURL(productService: IProductService" "${CORTEXIDE_REPO}/src/vs/platform/update/electron-main/abstractUpdateService.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ createUpdateURL has new signature${NC}"
else
    echo -e "${RED}✗ createUpdateURL has old signature (patch not applied)${NC}"
    ISSUES=$((ISSUES + 1))
fi

# Check URL format
if grep -q "latest.json" "${CORTEXIDE_REPO}/src/vs/platform/update/electron-main/abstractUpdateService.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ URL format uses latest.json${NC}"
else
    echo -e "${RED}✗ URL format uses old /api/update format${NC}"
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo "3. PLATFORM-SPECIFIC IMPLEMENTATIONS"
echo "-------------------------------------"

# macOS
if grep -q "createUpdateURL(this.productService, quality, process.platform" "${CORTEXIDE_REPO}/src/vs/platform/update/electron-main/updateService.darwin.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ macOS uses new createUpdateURL signature${NC}"
else
    echo -e "${RED}✗ macOS uses old createUpdateURL signature${NC}"
    ISSUES=$((ISSUES + 1))
fi

# Windows
if grep -q "createUpdateURL(this.productService, quality, process.platform" "${CORTEXIDE_REPO}/src/vs/platform/update/electron-main/updateService.win32.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ Windows uses new createUpdateURL signature${NC}"
else
    echo -e "${RED}✗ Windows uses old createUpdateURL signature${NC}"
    ISSUES=$((ISSUES + 1))
fi

# Linux
if grep -q "createUpdateURL(this.productService, quality, process.platform" "${CORTEXIDE_REPO}/src/vs/platform/update/electron-main/updateService.linux.ts" 2>/dev/null; then
    echo -e "${GREEN}✓ Linux uses new createUpdateURL signature${NC}"
else
    echo -e "${RED}✗ Linux uses old createUpdateURL signature${NC}"
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo "4. CONFIGURATION"
echo "----------------"

# Check updateUrl in prepare_vscode.sh
UPDATE_URL=$(grep -E "setpath.*updateUrl" "${BUILDER_REPO}/prepare_vscode.sh" | grep -oE 'https://[^"]+' | head -1)
if [[ -n "${UPDATE_URL}" ]]; then
    echo -e "${GREEN}✓ updateUrl configured: ${UPDATE_URL}${NC}"
    
    # Verify it points to cortexide-versions
    if echo "${UPDATE_URL}" | grep -q "cortexide-versions"; then
        echo -e "${GREEN}✓ updateUrl points to cortexide-versions repository${NC}"
    else
        warn "updateUrl does not point to cortexide-versions repository"
    fi
else
    echo -e "${RED}✗ updateUrl not found in prepare_vscode.sh${NC}"
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo "5. UPDATE URL FORMAT VERIFICATION"
echo "----------------------------------"

# Expected URL format: ${updateUrl}/${quality}/${platform}/${architecture}/latest.json
# Example: https://raw.githubusercontent.com/OpenCortexIDE/cortexide-versions/refs/heads/main/stable/darwin/arm64/latest.json

echo "Expected URL format:"
echo "  \${updateUrl}/\${quality}/\${platform}/\${architecture}/latest.json"
echo ""
echo "Example URLs:"
echo "  macOS ARM64: ${UPDATE_URL}/stable/darwin/arm64/latest.json"
echo "  macOS x64:   ${UPDATE_URL}/stable/darwin/x64/latest.json"
echo "  Windows x64: ${UPDATE_URL}/stable/win32/x64/archive/latest.json"
echo "  Linux x64:   ${UPDATE_URL}/stable/linux/x64/latest.json"

echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="

if [[ ${ISSUES} -eq 0 ]]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    if [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "${YELLOW}⚠ ${WARNINGS} warning(s)${NC}"
    fi
    exit 0
else
    echo -e "${RED}✗ ${ISSUES} issue(s) found${NC}"
    if [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "${YELLOW}⚠ ${WARNINGS} warning(s)${NC}"
    fi
    echo ""
    echo "ACTION REQUIRED:"
    echo "  1. Ensure version-1-update.patch is applied during build"
    echo "  2. Verify patch matches current VS Code source"
    echo "  3. Rebuild the application to include the fix"
    exit 1
fi

