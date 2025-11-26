#!/usr/bin/env bash
# Complete Release Script for CortexIDE
# This script orchestrates the entire build and release process

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Show usage
show_usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Complete release script for CortexIDE. Builds, packages, and releases the application.

Options:
  --platform PLATFORM    Platform to build (osx, linux, windows) [default: auto-detect]
  --arch ARCH            Architecture (x64, arm64, etc.) [default: auto-detect]
  --skip-build           Skip building (use existing build)
  --skip-package         Skip packaging (use existing packages)
  --skip-release         Skip GitHub release (just build and package)
  --skip-version         Skip version update
  --local-only           Only build locally, don't release
  --help, -h             Show this help message

Environment Variables:
  GITHUB_TOKEN           GitHub token for releases
  RELEASE_GITHUB_TOKEN   Alternative token variable
  VSCODE_QUALITY         Build quality (stable, insider) [default: stable]
  APP_NAME               Application name [default: CortexIDE]

Examples:
  # Build and release for current platform
  $0

  # Build for macOS ARM64
  $0 --platform osx --arch arm64

  # Build only (no release)
  $0 --local-only

  # Release existing build
  $0 --skip-build --skip-package

EOF
}

# Parse arguments
SKIP_BUILD="no"
SKIP_PACKAGE="no"
SKIP_RELEASE="no"
SKIP_VERSION="no"
LOCAL_ONLY="no"
PLATFORM=""
ARCH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD="yes"
      shift
      ;;
    --skip-package)
      SKIP_PACKAGE="yes"
      shift
      ;;
    --skip-release)
      SKIP_RELEASE="yes"
      shift
      ;;
    --skip-version)
      SKIP_VERSION="yes"
      shift
      ;;
    --local-only)
      LOCAL_ONLY="yes"
      SKIP_RELEASE="yes"
      SKIP_VERSION="yes"
      shift
      ;;
    --help|-h)
      show_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_usage
      exit 1
      ;;
  esac
done

# Detect platform if not specified
if [[ -z "${PLATFORM}" ]]; then
  case "$(uname -s)" in
    Darwin*)
      PLATFORM="osx"
      ;;
    Linux*)
      PLATFORM="linux"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      PLATFORM="windows"
      ;;
    *)
      log_error "Cannot auto-detect platform. Please specify --platform"
      exit 1
      ;;
  esac
fi

# Detect architecture if not specified
if [[ -z "${ARCH}" ]]; then
  case "$(uname -m)" in
    x86_64)
      ARCH="x64"
      ;;
    arm64|aarch64)
      ARCH="arm64"
      ;;
    *)
      ARCH="x64"
      ;;
  esac
fi

# Set environment variables
export OS_NAME="${PLATFORM}"
export VSCODE_ARCH="${ARCH}"
export VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
export APP_NAME="${APP_NAME:-CortexIDE}"
export BINARY_NAME="${BINARY_NAME:-cortexide}"
export ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-OpenCortexIDE/cortexide-binaries}"
export VERSIONS_REPOSITORY="${VERSIONS_REPOSITORY:-OpenCortexIDE/cortexide-versions}"

log_info "Release Configuration:"
log_info "  Platform: ${PLATFORM}"
log_info "  Architecture: ${ARCH}"
log_info "  Quality: ${VSCODE_QUALITY}"
log_info "  App Name: ${APP_NAME}"

# Step 1: Build
if [[ "${SKIP_BUILD}" == "no" ]]; then
  log_info "Step 1: Building application..."
  cd "${SCRIPT_DIR}"
  
  if [[ -f "build-new.sh" ]]; then
    ./build-new.sh || {
      log_error "Build failed"
      exit 1
    }
    log_success "Build completed"
  else
    log_error "build-new.sh not found. Using legacy build.sh..."
    if [[ -f "build.sh" ]]; then
      . build.sh || {
        log_error "Build failed"
        exit 1
      }
    else
      log_error "No build script found"
      exit 1
    fi
  fi
else
  log_info "Skipping build (--skip-build)"
fi

# Step 2: Package
if [[ "${SKIP_PACKAGE}" == "no" ]]; then
  log_info "Step 2: Packaging application..."
  cd "${SCRIPT_DIR}"
  
  # Use platform-specific packaging script
  if [[ -f "build/${PLATFORM}/package.sh" ]]; then
    . "build/${PLATFORM}/package.sh" || {
      log_error "Packaging failed"
      exit 1
    }
    log_success "Packaging completed"
  else
    log_warning "Platform-specific packaging script not found, skipping..."
  fi
else
  log_info "Skipping packaging (--skip-package)"
fi

# Step 3: Prepare assets
if [[ "${LOCAL_ONLY}" == "no" ]]; then
  log_info "Step 3: Preparing assets for release..."
  cd "${SCRIPT_DIR}"
  
  if [[ -f "prepare_assets.sh" ]]; then
    . prepare_assets.sh || {
      log_error "Asset preparation failed"
      exit 1
    }
    log_success "Assets prepared"
  else
    log_warning "prepare_assets.sh not found, skipping asset preparation"
  fi
fi

# Step 4: Release to GitHub
if [[ "${SKIP_RELEASE}" == "no" ]] && [[ "${LOCAL_ONLY}" == "no" ]]; then
  log_info "Step 4: Releasing to GitHub..."
  
  # Check for GitHub token
  if [[ -z "${GITHUB_TOKEN}" ]] && [[ -z "${RELEASE_GITHUB_TOKEN}" ]]; then
    log_error "GITHUB_TOKEN or RELEASE_GITHUB_TOKEN required for releases"
    log_info "Set GITHUB_TOKEN environment variable or use --local-only"
    exit 1
  fi
  
  cd "${SCRIPT_DIR}"
  
  if [[ -f "release.sh" ]]; then
    . release.sh || {
      log_error "Release failed"
      exit 1
    }
    log_success "Release completed"
  else
    log_error "release.sh not found"
    exit 1
  fi
else
  log_info "Skipping release (--skip-release or --local-only)"
fi

# Step 5: Update version
if [[ "${SKIP_VERSION}" == "no" ]] && [[ "${LOCAL_ONLY}" == "no" ]]; then
  log_info "Step 5: Updating version file..."
  cd "${SCRIPT_DIR}"
  
  if [[ -f "update_version.sh" ]]; then
    . update_version.sh || {
      log_error "Version update failed"
      exit 1
    }
    log_success "Version updated"
  else
    log_warning "update_version.sh not found, skipping version update"
  fi
else
  log_info "Skipping version update (--skip-version or --local-only)"
fi

log_success "Release process completed successfully!"
log_info ""
log_info "Summary:"
log_info "  Platform: ${PLATFORM}"
log_info "  Architecture: ${ARCH}"
if [[ "${LOCAL_ONLY}" == "no" ]]; then
  log_info "  Assets: assets/ directory"
  log_info "  Release: ${ASSETS_REPOSITORY}"
else
  log_info "  Build output: vscode/.build/electron/"
fi

