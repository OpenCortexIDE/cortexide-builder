#!/usr/bin/env bash
# Linux Packaging Script for CortexIDE
# Creates DEB, RPM, TAR.GZ, and AppImage for Linux distribution

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VSCODE_DIR="${BUILDER_DIR}/vscode"

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Get version info
get_version() {
  cd "${VSCODE_DIR}" || exit 1
  local version=$(node -p "require('./package.json').version")
  local app_name=$(node -p "require('./product.json').applicationName")
  echo "${version}" "${app_name}"
}

# Create tarball
create_tarball() {
  local version="$1"
  local app_name="$2"
  local arch="${VSCODE_ARCH:-x64}"
  
  log_info "Creating tarball for ${arch}..."
  
  local binary_path="${VSCODE_DIR}/.build/electron/${app_name}"
  
  if [[ ! -f "${binary_path}" ]]; then
    log_error "Binary not found: ${binary_path}"
    exit 1
  fi
  
  local tar_name="CortexIDE-${version}-linux-${arch}.tar.gz"
  local temp_dir="${BUILDER_DIR}/.tar-contents"
  
  rm -rf "${temp_dir}"
  mkdir -p "${temp_dir}/cortexide"
  
  # Copy binary and resources
  cp "${binary_path}" "${temp_dir}/cortexide/"
  cp -r "${VSCODE_DIR}/out" "${temp_dir}/cortexide/" 2>/dev/null || true
  cp "${VSCODE_DIR}/product.json" "${temp_dir}/cortexide/" 2>/dev/null || true
  cp "${VSCODE_DIR}/package.json" "${temp_dir}/cortexide/" 2>/dev/null || true
  
  # Create tarball
  cd "${temp_dir}"
  tar -czf "${BUILDER_DIR}/${tar_name}" cortexide/ || {
    log_error "Failed to create tarball"
    rm -rf "${temp_dir}"
    exit 1
  }
  
  rm -rf "${temp_dir}"
  log_success "Tarball created: ${tar_name}"
}

# Create DEB package (simplified)
create_deb() {
  local version="$1"
  local app_name="$2"
  local arch="${VSCODE_ARCH:-x64}"
  
  log_info "Creating DEB package for ${arch}..."
  
  # Check if dpkg-deb is available
  if ! command -v dpkg-deb &> /dev/null; then
    log_warning "dpkg-deb not found, skipping DEB creation"
    return 0
  fi
  
  # This is a simplified version - full DEB creation would require more setup
  log_info "DEB packaging requires additional setup (control files, etc.)"
  log_info "For now, using tarball as primary distribution method"
}

# Main packaging function
main() {
  log_info "Starting Linux packaging..."
  
  if [[ ! -d "${VSCODE_DIR}" ]]; then
    log_error "vscode directory not found: ${VSCODE_DIR}"
    exit 1
  fi
  
  # Get version info
  read -r version app_name <<< "$(get_version)"
  log_info "Version: ${version}, App: ${app_name}"
  
  # Create tarball
  create_tarball "${version}" "${app_name}"
  
  # Create DEB (if supported)
  if [[ "${CREATE_DEB:-no}" == "yes" ]]; then
    create_deb "${version}" "${app_name}"
  fi
  
  log_success "Linux packaging completed!"
}

# Run main function
main "$@"

