#!/bin/bash
#---------------------------------------------------------------------------------------------
#  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
#  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
#---------------------------------------------------------------------------------------------

# Cross-Platform Packaging Tests
# This script tests packaging across macOS, Linux, and Windows

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect current platform
detect_platform() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    local platform=$(detect_platform)
    print_status "Detected platform: $platform"
    
    # Common prerequisites
    if ! command_exists node; then
        print_error "Node.js is not installed. Please install Node.js to run tests."
        exit 1
    fi
    
    if ! command_exists npm; then
        print_error "npm is not installed. Please install npm to run tests."
        exit 1
    fi
    
    # Platform-specific prerequisites
    case "$platform" in
        "macos")
            if ! command_exists xcodebuild; then
                print_warning "Xcode command line tools not found. Some macOS packaging tests may fail."
            fi
            ;;
        "linux")
            if ! command_exists dpkg && ! command_exists rpm; then
                print_warning "Package managers (dpkg/rpm) not found. Some Linux packaging tests may fail."
            fi
            if ! command_exists appimagetool; then
                print_warning "AppImage tool not found. AppImage packaging tests may fail."
            fi
            ;;
        "windows")
            if ! command_exists makensis; then
                print_warning "NSIS not found. Windows installer tests may fail."
            fi
            ;;
    esac
    
    print_success "Prerequisites check completed"
}

# Function to test macOS packaging
test_macos_packaging() {
    print_status "Testing macOS packaging..."
    
    # Check for macOS-specific files
    local macos_files=(
        "build/osx/include.gypi"
        "resources/darwin"
    )
    
    for file in "${macos_files[@]}"; do
        if [ -f "$file" ] || [ -d "$file" ]; then
            print_success "Found macOS file: $file"
        else
            print_error "Missing macOS file: $file"
            return 1
        fi
    done
    
    # Check for macOS bundle structure
    if [ -d "resources/darwin" ]; then
        local darwin_files=(
            "resources/darwin/cortexide.icns"
            "resources/darwin/cortexide.iconset"
        )
        
        for file in "${darwin_files[@]}"; do
            if [ -f "$file" ] || [ -d "$file" ]; then
                print_success "Found macOS resource: $file"
            else
                print_warning "Missing macOS resource: $file"
            fi
        done
    fi
    
    # Test macOS build configuration
    if [ -f "build/osx/include.gypi" ]; then
        if grep -q "cortexide" "build/osx/include.gypi" 2>/dev/null; then
            print_success "macOS build configuration contains CortexIDE branding"
        else
            print_warning "macOS build configuration may not contain CortexIDE branding"
        fi
    fi
    
    print_success "macOS packaging tests completed"
}

# Function to test Linux packaging
test_linux_packaging() {
    print_status "Testing Linux packaging..."
    
    # Check for Linux-specific files
    local linux_files=(
        "build/linux/appimage/build.sh"
        "build/linux/appimage/recipe.yml"
        "build/linux/package_bin.sh"
        "build/linux/package_reh.sh"
        "build/linux/deps.sh"
    )
    
    for file in "${linux_files[@]}"; do
        if [ -f "$file" ]; then
            print_success "Found Linux file: $file"
        else
            print_error "Missing Linux file: $file"
            return 1
        fi
    done
    
    # Check for Linux desktop files
    local desktop_files=(
        "resources/linux/cortexide.desktop"
        "resources/linux/cortexide-insider.desktop"
    )
    
    for file in "${desktop_files[@]}"; do
        if [ -f "$file" ]; then
            print_success "Found Linux desktop file: $file"
            # Check for CortexIDE branding
            if grep -q "CortexIDE" "$file" 2>/dev/null; then
                print_success "Desktop file contains CortexIDE branding"
            else
                print_warning "Desktop file may not contain CortexIDE branding"
            fi
        else
            print_warning "Missing Linux desktop file: $file"
        fi
    done
    
    # Check for AppStream metadata
    local appstream_files=(
        "resources/linux/cortexide.appdata.xml"
        "resources/linux/cortexide-insider.appdata.xml"
    )
    
    for file in "${appstream_files[@]}"; do
        if [ -f "$file" ]; then
            print_success "Found AppStream metadata: $file"
            # Check for CortexIDE branding
            if grep -q "CortexIDE" "$file" 2>/dev/null; then
                print_success "AppStream metadata contains CortexIDE branding"
            else
                print_warning "AppStream metadata may not contain CortexIDE branding"
            fi
        else
            print_warning "Missing AppStream metadata: $file"
        fi
    done
    
    # Test AppImage configuration
    if [ -f "build/linux/appimage/recipe.yml" ]; then
        if grep -q "cortexide" "build/linux/appimage/recipe.yml" 2>/dev/null; then
            print_success "AppImage recipe contains CortexIDE branding"
        else
            print_warning "AppImage recipe may not contain CortexIDE branding"
        fi
    fi
    
    # Test package scripts
    local package_scripts=(
        "build/linux/package_bin.sh"
        "build/linux/package_reh.sh"
    )
    
    for script in "${package_scripts[@]}"; do
        if [ -f "$script" ]; then
            if grep -q "cortexide" "$script" 2>/dev/null; then
                print_success "Package script contains CortexIDE branding: $script"
            else
                print_warning "Package script may not contain CortexIDE branding: $script"
            fi
        fi
    done
    
    print_success "Linux packaging tests completed"
}

# Function to test Windows packaging
test_windows_packaging() {
    print_status "Testing Windows packaging..."
    
    # Check for Windows-specific files
    local windows_files=(
        "build/windows/msi/build.sh"
        "build/windows/msi/vscodium.wxs"
        "build/windows/msi/vscodium.xsl"
        "build/windows/package.sh"
    )
    
    for file in "${windows_files[@]}"; do
        if [ -f "$file" ]; then
            print_success "Found Windows file: $file"
        else
            print_error "Missing Windows file: $file"
            return 1
        fi
    done
    
    # Check for Windows resources
    local windows_resources=(
        "resources/win32/cortexide.ico"
        "resources/win32/cortexide.rc"
    )
    
    for file in "${windows_resources[@]}"; do
        if [ -f "$file" ]; then
            print_success "Found Windows resource: $file"
        else
            print_warning "Missing Windows resource: $file"
        fi
    done
    
    # Test MSI configuration
    if [ -f "build/windows/msi/vscodium.wxs" ]; then
        if grep -q "cortexide" "build/windows/msi/vscodium.wxs" 2>/dev/null; then
            print_success "MSI configuration contains CortexIDE branding"
        else
            print_warning "MSI configuration may not contain CortexIDE branding"
        fi
    fi
    
    # Test MSI resources
    local msi_resources=(
        "build/windows/msi/resources/stable/wix-banner.bmp"
        "build/windows/msi/resources/stable/wix-dialog.bmp"
        "build/windows/msi/resources/insider/wix-banner.bmp"
        "build/windows/msi/resources/insider/wix-dialog.bmp"
    )
    
    for file in "${msi_resources[@]}"; do
        if [ -f "$file" ]; then
            print_success "Found MSI resource: $file"
        else
            print_warning "Missing MSI resource: $file"
        fi
    done
    
    # Test MSI localization files
    local msi_i18n_dir="build/windows/msi/i18n"
    if [ -d "$msi_i18n_dir" ]; then
        local i18n_files=$(find "$msi_i18n_dir" -name "*.wxl" | wc -l)
        print_success "Found $i18n_files MSI localization files"
    else
        print_warning "Missing MSI localization directory"
    fi
    
    print_success "Windows packaging tests completed"
}

# Function to test cross-platform consistency
test_cross_platform_consistency() {
    print_status "Testing cross-platform consistency..."
    
    # Check for consistent branding across platforms
    local branding_files=(
        "product.json"
        "package.json"
    )
    
    for file in "${branding_files[@]}"; do
        if [ -f "$file" ]; then
            if grep -q "cortexide" "$file" 2>/dev/null; then
                print_success "Found CortexIDE branding in: $file"
            else
                print_warning "Missing CortexIDE branding in: $file"
            fi
        fi
    done
    
    # Check for consistent version information
    if [ -f "package.json" ]; then
        local version=$(grep '"version"' package.json | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
        if [ -n "$version" ]; then
            print_success "Found version: $version"
        else
            print_warning "Could not extract version from package.json"
        fi
    fi
    
    # Check for consistent build scripts
    local build_scripts=(
        "build.sh"
        "build_cli.sh"
    )
    
    for script in "${build_scripts[@]}"; do
        if [ -f "$script" ]; then
            if grep -q "cortexide" "$script" 2>/dev/null; then
                print_success "Build script contains CortexIDE branding: $script"
            else
                print_warning "Build script may not contain CortexIDE branding: $script"
            fi
        fi
    done
    
    print_success "Cross-platform consistency tests completed"
}

# Function to test packaging scripts
test_packaging_scripts() {
    print_status "Testing packaging scripts..."
    
    # Check for main packaging scripts
    local main_scripts=(
        "build.sh"
        "build_cli.sh"
        "prepare_src.sh"
        "prepare_vscode.sh"
        "prepare_assets.sh"
        "prepare_checksums.sh"
    )
    
    for script in "${main_scripts[@]}"; do
        if [ -f "$script" ]; then
            print_success "Found packaging script: $script"
            # Check if script is executable
            if [ -x "$script" ]; then
                print_success "Script is executable: $script"
            else
                print_warning "Script is not executable: $script"
            fi
        else
            print_warning "Missing packaging script: $script"
        fi
    done
    
    # Test script syntax (basic check)
    for script in "${main_scripts[@]}"; do
        if [ -f "$script" ]; then
            if bash -n "$script" 2>/dev/null; then
                print_success "Script syntax is valid: $script"
            else
                print_error "Script syntax error in: $script"
                return 1
            fi
        fi
    done
    
    print_success "Packaging scripts tests completed"
}

# Function to test asset preparation
test_asset_preparation() {
    print_status "Testing asset preparation..."
    
    # Check for asset preparation scripts
    local asset_scripts=(
        "prepare_assets.sh"
        "prepare_checksums.sh"
    )
    
    for script in "${asset_scripts[@]}"; do
        if [ -f "$script" ]; then
            print_success "Found asset script: $script"
        else
            print_warning "Missing asset script: $script"
        fi
    done
    
    # Check for asset directories
    local asset_dirs=(
        "src/stable"
        "src/insider"
    )
    
    for dir in "${asset_dirs[@]}"; do
        if [ -d "$dir" ]; then
            print_success "Found asset directory: $dir"
            # Count files in directory
            local file_count=$(find "$dir" -type f | wc -l)
            print_success "Found $file_count files in $dir"
        else
            print_warning "Missing asset directory: $dir"
        fi
    done
    
    print_success "Asset preparation tests completed"
}

# Function to run all packaging tests
run_all_tests() {
    print_status "Running all cross-platform packaging tests..."
    
    local platform=$(detect_platform)
    
    # Run platform-specific tests
    case "$platform" in
        "macos")
            test_macos_packaging
            ;;
        "linux")
            test_linux_packaging
            ;;
        "windows")
            test_windows_packaging
            ;;
        *)
            print_warning "Unknown platform, running generic tests only"
            ;;
    esac
    
    # Run cross-platform tests
    test_cross_platform_consistency
    test_packaging_scripts
    test_asset_preparation
    
    print_success "All cross-platform packaging tests completed"
}

# Function to run specific test type
run_specific_test() {
    case "$1" in
        "macos")
            test_macos_packaging
            ;;
        "linux")
            test_linux_packaging
            ;;
        "windows")
            test_windows_packaging
            ;;
        "consistency")
            test_cross_platform_consistency
            ;;
        "scripts")
            test_packaging_scripts
            ;;
        "assets")
            test_asset_preparation
            ;;
        "all")
            run_all_tests
            ;;
        *)
            print_error "Unknown test type: $1"
            print_status "Available test types: macos, linux, windows, consistency, scripts, assets, all"
            exit 1
            ;;
    esac
}

# Function to show help
show_help() {
    echo "Cross-Platform Packaging Tests"
    echo ""
    echo "Usage: $0 [OPTIONS] [TEST_TYPE]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help     Show this help message"
    echo "  -c, --check    Check prerequisites only"
    echo ""
    echo "TEST_TYPE:"
    echo "  macos         Test macOS packaging only"
    echo "  linux         Test Linux packaging only"
    echo "  windows       Test Windows packaging only"
    echo "  consistency   Test cross-platform consistency only"
    echo "  scripts       Test packaging scripts only"
    echo "  assets        Test asset preparation only"
    echo "  all           Run all tests (default)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run all tests"
    echo "  $0 macos              # Test macOS packaging only"
    echo "  $0 linux              # Test Linux packaging only"
    echo "  $0 windows            # Test Windows packaging only"
    echo "  $0 --check            # Check prerequisites only"
}

# Main function
main() {
    local test_type="all"
    local check_only=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--check)
                check_only=true
                shift
                ;;
            macos|linux|windows|consistency|scripts|assets|all)
                test_type="$1"
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check prerequisites
    check_prerequisites
    
    if [ "$check_only" = true ]; then
        print_success "Prerequisites check completed"
        exit 0
    fi
    
    # Run tests
    run_specific_test "$test_type"
    
    print_success "Cross-platform packaging tests completed successfully"
}

# Run main function with all arguments
main "$@"
