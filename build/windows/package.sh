#!/usr/bin/env bash
# Windows Packaging Script for CortexIDE
# Creates ZIP and MSI/EXE installers for Windows distribution

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

# Create ZIP
create_zip() {
  local version="$1"
  local app_name="$2"
  local arch="${VSCODE_ARCH:-x64}"
  
  log_info "Creating ZIP for ${arch}..."
  
  local exe_path="${VSCODE_DIR}/.build/electron/${app_name}.exe"
  
  if [[ ! -f "${exe_path}" ]]; then
    log_error "Executable not found: ${exe_path}"
    exit 1
  fi
  
  local zip_name="CortexIDE-${version}-win32-${arch}.zip"
  local temp_dir="${BUILDER_DIR}/.zip-contents"
  
  rm -rf "${temp_dir}"
  mkdir -p "${temp_dir}/cortexide"
  
  # Copy executable and resources
  cp "${exe_path}" "${temp_dir}/cortexide/"
  cp -r "${VSCODE_DIR}/out" "${temp_dir}/cortexide/" 2>/dev/null || true
  cp "${VSCODE_DIR}/product.json" "${temp_dir}/cortexide/" 2>/dev/null || true
  cp "${VSCODE_DIR}/package.json" "${temp_dir}/cortexide/" 2>/dev/null || true
  
  # Create ZIP
  cd "${temp_dir}"
  if command -v zip &> /dev/null; then
    zip -r "${BUILDER_DIR}/${zip_name}" cortexide/ || {
      log_error "Failed to create ZIP"
      rm -rf "${temp_dir}"
      exit 1
    }
    log_success "ZIP created: ${zip_name}"
  else
    log_warning "zip command not found, skipping ZIP creation"
  fi
  
  rm -rf "${temp_dir}"
}

# Create MSI (simplified - requires WiX Toolset)
create_msi() {
  local version="$1"
  local app_name="$2"
  local arch="${VSCODE_ARCH:-x64}"
  
  log_info "Creating MSI package for ${arch}..."
  
  # Check if WiX is available
  if ! command -v candle &> /dev/null && ! command -v light &> /dev/null; then
    log_warning "WiX Toolset not found, skipping MSI creation"
    log_info "Install WiX Toolset from https://wixtoolset.org/ to create MSI installers"
    return 0
  fi
  
  # This is a simplified version - full MSI creation would require WiX setup files
  log_info "MSI packaging requires WiX Toolset and setup files"
  log_info "For now, using ZIP as primary distribution method"
}

# Main packaging function
main() {
  log_info "Starting Windows packaging..."
  
  if [[ ! -d "${VSCODE_DIR}" ]]; then
    log_error "vscode directory not found: ${VSCODE_DIR}"
    exit 1
  fi
  
  # Get version info
  read -r version app_name <<< "$(get_version)"
  log_info "Version: ${version}, App: ${app_name}"
  
  # Create ZIP
  create_zip "${version}" "${app_name}"
  
  # Create MSI (if supported)
  if [[ "${CREATE_MSI:-no}" == "yes" ]]; then
    create_msi "${version}" "${app_name}"
  fi
  
  log_success "Windows packaging completed!"
}

# Run main function
main "$@"
