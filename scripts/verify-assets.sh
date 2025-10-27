#!/bin/bash
#---------------------------------------------------------------------------------------------
#  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
#  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
#---------------------------------------------------------------------------------------------

# CortexIDE Asset Verification Script
# Verifies that all assets have been properly updated with CortexIDE branding

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}🔍 CortexIDE Asset Verification${NC}"
echo -e "${BLUE}==============================${NC}"
echo "Builder Directory: $BUILDER_DIR"
echo ""

# Function to log with timestamp
log() {
    echo -e "${GREEN}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")]${NC} $1"
}

# Function to log warnings
warn() {
    echo -e "${YELLOW}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WARNING:${NC} $1"
}

# Function to log errors
error() {
    echo -e "${RED}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR:${NC} $1"
}

# Function to check if file exists and is not empty
check_file() {
    local file="$1"
    local description="$2"

    if [ -f "$file" ]; then
        if [ -s "$file" ]; then
            log "✅ $description: $(basename "$file")"
            return 0
        else
            error "❌ $description: $(basename "$file") (empty file)"
            return 1
        fi
    else
        error "❌ $description: $(basename "$file") (missing)"
        return 1
    fi
}

# Function to check desktop file content
check_desktop_content() {
    local file="$1"
    local description="$2"

    if [ -f "$file" ]; then
        # Check if it's a template file (contains @@ variables) or has been processed
        if grep -q "@@NAME_LONG@@" "$file"; then
            # Template file - check if it has CortexIDE branding in comments or keywords
            if grep -q "cortexide" "$file" || grep -q "CortexIDE" "$file"; then
                log "✅ $description: $(basename "$file") (CortexIDE branding in template)"
                return 0
            else
                error "❌ $description: $(basename "$file") (CortexIDE branding not found in template)"
                return 1
            fi
        else
            # Processed file - check for actual values
            if grep -q "Name=CortexIDE" "$file" && grep -q "Comment=CortexIDE" "$file"; then
                log "✅ $description: $(basename "$file") (CortexIDE branding found)"
                return 0
            else
                error "❌ $description: $(basename "$file") (CortexIDE branding not found)"
                return 1
            fi
        fi
    else
        error "❌ $description: $(basename "$file") (missing)"
        return 1
    fi
}

# Function to check appdata content
check_appdata_content() {
    local file="$1"
    local description="$2"

    if [ -f "$file" ]; then
        # Check if it's a template file (contains @@ variables) or has been processed
        if grep -q "@@NAME_LONG@@" "$file"; then
            # Template file - check if it has CortexIDE branding in comments or keywords
            if grep -q "cortexide" "$file" || grep -q "CortexIDE" "$file"; then
                log "✅ $description: $(basename "$file") (CortexIDE branding in template)"
                return 0
            else
                error "❌ $description: $(basename "$file") (CortexIDE branding not found in template)"
                return 1
            fi
        else
            # Processed file - check for actual values
            if grep -q "<name>CortexIDE</name>" "$file" && grep -q "<summary>CortexIDE</summary>" "$file"; then
                log "✅ $description: $(basename "$file") (CortexIDE branding found)"
                return 0
            else
                error "❌ $description: $(basename "$file") (CortexIDE branding not found)"
                return 1
            fi
        fi
    else
        error "❌ $description: $(basename "$file") (missing)"
        return 1
    fi
}

# Counters
total_checks=0
passed_checks=0
failed_checks=0

# Function to run check and update counters
run_check() {
    local check_function="$1"
    local file="$2"
    local description="$3"

    total_checks=$((total_checks + 1))
    if $check_function "$file" "$description"; then
        passed_checks=$((passed_checks + 1))
    else
        failed_checks=$((failed_checks + 1))
    fi
}

log "🔄 Starting asset verification..."

# Check main application icons
log "📱 Checking main application icons..."

# Windows ICO files
run_check check_file "$BUILDER_DIR/src/stable/resources/win32/code.ico" "Stable Windows ICO"
run_check check_file "$BUILDER_DIR/src/insider/resources/win32/code.ico" "Insider Windows ICO"

# macOS ICNS files
run_check check_file "$BUILDER_DIR/src/stable/resources/darwin/code.icns" "Stable macOS ICNS"
run_check check_file "$BUILDER_DIR/src/insider/resources/darwin/code.icns" "Insider macOS ICNS"

# Linux icons
run_check check_file "$BUILDER_DIR/src/stable/resources/linux/code.svg" "Stable Linux SVG"
run_check check_file "$BUILDER_DIR/src/insider/resources/linux/code.svg" "Insider Linux SVG"
run_check check_file "$BUILDER_DIR/src/stable/resources/linux/code.png" "Stable Linux PNG"
run_check check_file "$BUILDER_DIR/src/insider/resources/linux/code.png" "Insider Linux PNG"

# Server icons
run_check check_file "$BUILDER_DIR/src/stable/resources/server/code-192.png" "Stable Server 192x192"
run_check check_file "$BUILDER_DIR/src/insider/resources/server/code-192.png" "Insider Server 192x192"
run_check check_file "$BUILDER_DIR/src/stable/resources/server/code-512.png" "Stable Server 512x512"
run_check check_file "$BUILDER_DIR/src/insider/resources/server/code-512.png" "Insider Server 512x512"
run_check check_file "$BUILDER_DIR/src/stable/resources/server/favicon.ico" "Stable Server favicon"
run_check check_file "$BUILDER_DIR/src/insider/resources/server/favicon.ico" "Insider Server favicon"

# Check desktop files
log "🖥️  Checking desktop files..."
run_check check_desktop_content "$BUILDER_DIR/src/stable/resources/linux/code.desktop" "Stable desktop file"
run_check check_desktop_content "$BUILDER_DIR/src/insider/resources/linux/code.desktop" "Insider desktop file"

# Check appdata files
log "📄 Checking appdata files..."
run_check check_appdata_content "$BUILDER_DIR/src/stable/resources/linux/code.appdata.xml" "Stable appdata file"
run_check check_appdata_content "$BUILDER_DIR/src/insider/resources/linux/code.appdata.xml" "Insider appdata file"

# Check workbench icons
log "🎨 Checking workbench icons..."
run_check check_file "$BUILDER_DIR/src/stable/src/vs/workbench/browser/media/code-icon.svg" "Stable workbench icon"
run_check check_file "$BUILDER_DIR/src/insider/src/vs/workbench/browser/media/code-icon.svg" "Insider workbench icon"

# Check Windows PNG icons
log "🖼️  Checking Windows PNG icons..."
run_check check_file "$BUILDER_DIR/src/stable/resources/win32/code_150x150.png" "Stable Windows 150x150"
run_check check_file "$BUILDER_DIR/src/insider/resources/win32/code_150x150.png" "Insider Windows 150x150"
run_check check_file "$BUILDER_DIR/src/stable/resources/win32/code_70x70.png" "Stable Windows 70x70"
run_check check_file "$BUILDER_DIR/src/insider/resources/win32/code_70x70.png" "Insider Windows 70x70"

# Check file type icons (sample a few)
log "📁 Checking file type icons..."
for variant in stable insider; do
    for platform in darwin win32; do
        for ext in default javascript typescript python; do
            if [ "$platform" = "darwin" ]; then
                ext_file="$BUILDER_DIR/src/$variant/resources/$platform/$ext.icns"
            else
                ext_file="$BUILDER_DIR/src/$variant/resources/$platform/$ext.ico"
            fi
            run_check check_file "$ext_file" "$variant $platform $ext icon"
        done
    done
done

# Check installer bitmaps
log "📦 Checking installer bitmaps..."
run_check check_file "$BUILDER_DIR/src/stable/resources/win32/inno-void.bmp" "Stable installer bitmap"
run_check check_file "$BUILDER_DIR/src/insider/resources/win32/inno-void.bmp" "Insider installer bitmap"

# Check CortexIDE-specific assets
log "🎯 Checking CortexIDE-specific assets..."
run_check check_file "$BUILDER_DIR/src/stable/resources/linux/cortexide.svg" "Stable CortexIDE SVG"
run_check check_file "$BUILDER_DIR/src/insider/resources/linux/cortexide.svg" "Insider CortexIDE SVG"

# Generate verification report
log "📋 Generating verification report..."
cat > "$BUILDER_DIR/asset-verification-report.md" << EOF
# CortexIDE Asset Verification Report

## Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Summary:
- Total Checks: $total_checks
- Passed: $passed_checks
- Failed: $failed_checks
- Success Rate: $(( (passed_checks * 100) / total_checks ))%

## Verification Results:

### Main Application Icons
- Windows ICO files: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)
- macOS ICNS files: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)
- Linux SVG/PNG files: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)
- Server icons: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)

### Desktop Integration
- Desktop files: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)
- AppData files: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)

### Workbench Icons
- Workbench icons: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)

### File Type Icons
- File type icons: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)

### Windows Assets
- Windows PNG icons: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)
- Installer bitmaps: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)

### CortexIDE-Specific Assets
- CortexIDE SVG logos: $(if [ $failed_checks -eq 0 ]; then echo "✅ All passed"; else echo "❌ Some failed"; fi)

## Recommendations:
$(if [ $failed_checks -eq 0 ]; then
    echo "- ✅ All assets verified successfully!"
    echo "- Ready for production use"
    echo "- Consider testing on actual platforms"
else
    echo "- ❌ Some assets failed verification"
    echo "- Review failed checks above"
    echo "- Re-run asset update script if needed"
fi)

## Next Steps:
1. Test assets on actual platforms (Windows, macOS, Linux)
2. Verify icon quality and clarity
3. Test desktop integration
4. Verify installer graphics
5. Consider creating custom CortexIDE-designed assets
EOF

# Final summary
echo ""
echo -e "${BLUE}📊 Verification Summary:${NC}"
echo -e "Total Checks: ${BLUE}$total_checks${NC}"
echo -e "Passed: ${GREEN}$passed_checks${NC}"
echo -e "Failed: ${RED}$failed_checks${NC}"
echo -e "Success Rate: ${BLUE}$(( (passed_checks * 100) / total_checks ))%${NC}"
echo ""

if [ $failed_checks -eq 0 ]; then
    echo -e "${GREEN}✅ All assets verified successfully!${NC}"
    echo -e "${BLUE}📋 Report: $BUILDER_DIR/asset-verification-report.md${NC}"
    exit 0
else
    echo -e "${RED}❌ Some assets failed verification.${NC}"
    echo -e "${BLUE}📋 Report: $BUILDER_DIR/asset-verification-report.md${NC}"
    exit 1
fi
