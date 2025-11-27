#!/usr/bin/env bash
# CortexIDE Builder - Local Build Test Script
# This script tests the build locally before pushing to CI

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "CortexIDE Builder - Local Build Test"
echo "========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

# Check Node.js
if ! command -v node &> /dev/null; then
    echo -e "${RED}✗ Node.js not found${NC}"
    exit 1
fi
NODE_VERSION=$(node --version)
echo -e "${GREEN}✓ Node.js${NC} $NODE_VERSION"

# Check npm
if ! command -v npm &> /dev/null; then
    echo -e "${RED}✗ npm not found${NC}"
    exit 1
fi
NPM_VERSION=$(npm --version)
echo -e "${GREEN}✓ npm${NC} $NPM_VERSION"

# Check for CortexIDE source
CORTEXIDE_SOURCE="../cortexide"
if [[ ! -d "$CORTEXIDE_SOURCE" ]]; then
    echo -e "${RED}✗ CortexIDE source not found at $CORTEXIDE_SOURCE${NC}"
    exit 1
fi
echo -e "${GREEN}✓ CortexIDE source${NC} found at $CORTEXIDE_SOURCE"

# Check system
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" == "Darwin" ]]; then
    OS_NAME="osx"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
        VSCODE_ARCH="arm64"
    else
        VSCODE_ARCH="x64"
    fi
    echo -e "${GREEN}✓ macOS${NC} detected (${VSCODE_ARCH})"
elif [[ "$OS_TYPE" == "Linux" ]]; then
    OS_NAME="linux"
    VSCODE_ARCH="x64"
    echo -e "${GREEN}✓ Linux${NC} detected"
elif [[ "$OS_TYPE" == *"MINGW"* || "$OS_TYPE" == *"MSYS"* ]]; then
    OS_NAME="windows"
    VSCODE_ARCH="x64"
    echo -e "${GREEN}✓ Windows${NC} detected"
else
    echo -e "${YELLOW}⚠ Unknown OS: $OS_TYPE${NC}"
    OS_NAME="linux"
    VSCODE_ARCH="x64"
fi

# Check memory (with error handling)
TOTAL_MEM_GB=0
if [[ "$OS_NAME" == "osx" ]]; then
    MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
    if [[ "$MEM_BYTES" =~ ^[0-9]+$ ]] && [[ $MEM_BYTES -gt 0 ]]; then
        TOTAL_MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
    fi
elif [[ "$OS_NAME" == "linux" ]]; then
    MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    if [[ "$MEM_KB" =~ ^[0-9]+$ ]] && [[ $MEM_KB -gt 0 ]]; then
        TOTAL_MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    fi
fi

if [[ $TOTAL_MEM_GB -eq 0 ]]; then
    echo -e "${YELLOW}⚠ Warning: Could not detect RAM. Build requires 12GB+ for best results.${NC}"
elif [[ $TOTAL_MEM_GB -lt 12 ]]; then
    echo -e "${YELLOW}⚠ Warning: Only ${TOTAL_MEM_GB}GB RAM detected. Build requires 12GB+ for best results.${NC}"
else
    echo -e "${GREEN}✓ Memory${NC} ${TOTAL_MEM_GB}GB"
fi

# Check disk space (with error handling)
AVAILABLE_GB=0
if [[ "$OS_NAME" == "osx" ]]; then
    AVAILABLE_GB=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
elif [[ "$OS_NAME" == "linux" ]]; then
    AVAILABLE_GB=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")
fi

if [[ "$AVAILABLE_GB" =~ ^[0-9]+$ ]]; then
    if [[ $AVAILABLE_GB -lt 10 ]]; then
        echo -e "${YELLOW}⚠ Warning: Only ${AVAILABLE_GB}GB disk space available. Build needs 10GB+${NC}"
    else
        echo -e "${GREEN}✓ Disk space${NC} ${AVAILABLE_GB}GB available"
    fi
else
    echo -e "${YELLOW}⚠ Warning: Could not detect disk space. Build needs 10GB+${NC}"
fi

echo ""
echo "========================================="
echo "Build Configuration"
echo "========================================="
export APP_NAME="CortexIDE"
export BINARY_NAME="cortexide"
export VSCODE_QUALITY="stable"
export CI_BUILD="no"
export SHOULD_BUILD="yes"
export OS_NAME
export VSCODE_ARCH

echo "APP_NAME:        $APP_NAME"
echo "BINARY_NAME:     $BINARY_NAME"
echo "OS_NAME:         $OS_NAME"
echo "VSCODE_ARCH:     $VSCODE_ARCH"
echo "VSCODE_QUALITY:  $VSCODE_QUALITY"
echo ""

# Confirm
echo -e "${YELLOW}This will build CortexIDE for ${OS_NAME}-${VSCODE_ARCH}${NC}"
echo "Estimated time: 20-40 minutes"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Build cancelled."
    exit 0
fi

echo ""
echo "========================================="
echo "Starting Build"
echo "========================================="
echo ""

# Clean up old build artifacts
echo "Cleaning up old build artifacts..."
rm -rf vscode 2>/dev/null || true
rm -rf ../VSCode-${OS_NAME}-${VSCODE_ARCH} 2>/dev/null || true

# Run get_repo.sh
echo ""
echo "Step 1/3: Fetching source..."
if ! ./get_repo.sh; then
    echo -e "${RED}✗ Failed to fetch source${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Source fetched${NC}"

# Check if vscode directory was created
if [[ ! -d "vscode" ]]; then
    echo -e "${RED}✗ vscode directory not created${NC}"
    exit 1
fi

# Run build.sh
echo ""
echo "Step 2/3: Building..."
START_TIME=$(date +%s)

if ! ./build.sh; then
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo -e "${GREEN}✓ Build completed${NC} in ${MINUTES}m ${SECONDS}s"

# Check output
echo ""
echo "Step 3/3: Verifying output..."

OUTPUT_DIR="../VSCode-${OS_NAME}-${VSCODE_ARCH}"
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo -e "${RED}✗ Output directory not found: $OUTPUT_DIR${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Output directory${NC} exists"

if [[ "$OS_NAME" == "osx" ]]; then
    APP_PATH="$OUTPUT_DIR/CortexIDE.app"
    if [[ ! -d "$APP_PATH" ]]; then
        echo -e "${RED}✗ CortexIDE.app not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ CortexIDE.app${NC} created"
    
    BINARY_PATH="$APP_PATH/Contents/MacOS/Electron"
    if [[ ! -f "$BINARY_PATH" ]]; then
        echo -e "${RED}✗ Electron binary not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Electron binary${NC} exists"
    
elif [[ "$OS_NAME" == "linux" ]]; then
    BINARY_PATH="$OUTPUT_DIR/bin/cortexide"
    if [[ ! -f "$BINARY_PATH" ]]; then
        echo -e "${RED}✗ cortexide binary not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ cortexide binary${NC} exists"
    
elif [[ "$OS_NAME" == "windows" ]]; then
    BINARY_PATH="$OUTPUT_DIR/CortexIDE.exe"
    if [[ ! -f "$BINARY_PATH" ]]; then
        echo -e "${RED}✗ CortexIDE.exe not found${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ CortexIDE.exe${NC} exists"
fi

# Check size
if [[ -f "$BINARY_PATH" ]]; then
    SIZE_MB=$(du -m "$BINARY_PATH" | cut -f1)
    echo -e "${GREEN}✓ Binary size${NC} ${SIZE_MB}MB"
fi

# Check product.json
PRODUCT_JSON="$OUTPUT_DIR/resources/app/product.json"
if [[ "$OS_NAME" == "osx" ]]; then
    PRODUCT_JSON="$APP_PATH/Contents/Resources/app/product.json"
fi

if [[ -f "$PRODUCT_JSON" ]]; then
    APP_NAME_CHECK=$(grep -o '"applicationName"[[:space:]]*:[[:space:]]*"[^"]*"' "$PRODUCT_JSON" | cut -d'"' -f4)
    if [[ "$APP_NAME_CHECK" == "cortexide" ]]; then
        echo -e "${GREEN}✓ Branding${NC} correct (applicationName: cortexide)"
    else
        echo -e "${YELLOW}⚠ Warning: applicationName is '$APP_NAME_CHECK' (expected 'cortexide')${NC}"
    fi
fi

echo ""
echo "========================================="
echo "Build Test Summary"
echo "========================================="
echo -e "${GREEN}✓ All checks passed!${NC}"
echo ""
echo "Build location: $OUTPUT_DIR"
echo "Build time: ${MINUTES}m ${SECONDS}s"
echo ""
echo "To run the built application:"
if [[ "$OS_NAME" == "osx" ]]; then
    echo "  $APP_PATH/Contents/MacOS/Electron"
elif [[ "$OS_NAME" == "linux" ]]; then
    echo "  $OUTPUT_DIR/bin/cortexide"
elif [[ "$OS_NAME" == "windows" ]]; then
    echo "  $OUTPUT_DIR/CortexIDE.exe"
fi
echo ""
echo "To create installers, run:"
echo "  ./prepare_assets.sh"
echo ""

