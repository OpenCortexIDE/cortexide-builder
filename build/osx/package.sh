#!/usr/bin/env bash
# macOS Packaging Script for CortexIDE
# Creates DMG and ZIP archives for macOS distribution

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
  local name=$(node -p "require('./product.json').nameLong")
  echo "${version}" "${name}"
}

# Create DMG
create_dmg() {
  local version="$1"
  local app_name="$2"
  local arch="${VSCODE_ARCH:-x64}"
  
  log_info "Creating DMG for ${arch}..."
  
  local app_path="${VSCODE_DIR}/.build/electron/${app_name}.app"
  
  if [[ ! -d "${app_path}" ]]; then
    log_error "App not found: ${app_path}"
    log_info "Run: npm run electron"
    exit 1
  fi
  
  local dmg_name="CortexIDE-${version}-darwin-${arch}.dmg"
  local temp_dmg="CortexIDE-temp.dmg"
  
  # Create temporary directory for DMG contents
  local dmg_dir="${BUILDER_DIR}/.dmg-contents"
  rm -rf "${dmg_dir}"
  mkdir -p "${dmg_dir}"
  
  # Copy app to DMG directory
  cp -R "${app_path}" "${dmg_dir}/"
  
  # Create DMG using hdiutil
  if command -v hdiutil &> /dev/null; then
    # Remove existing DMG if present
    rm -f "${BUILDER_DIR}/${dmg_name}" "${BUILDER_DIR}/${temp_dmg}"
    
    # Create DMG
    hdiutil create -volname "CortexIDE" -srcfolder "${dmg_dir}" \
      -ov -format UDRW "${BUILDER_DIR}/${temp_dmg}" || {
      log_error "Failed to create DMG"
      rm -rf "${dmg_dir}"
      exit 1
    }
    
    # Convert to compressed DMG
    hdiutil convert "${BUILDER_DIR}/${temp_dmg}" -format UDZO \
      -o "${BUILDER_DIR}/${dmg_name}" || {
      log_error "Failed to convert DMG"
      rm -f "${BUILDER_DIR}/${temp_dmg}"
      rm -rf "${dmg_dir}"
      exit 1
    }
    
    rm -f "${BUILDER_DIR}/${temp_dmg}"
    rm -rf "${dmg_dir}"
    
    log_success "DMG created: ${dmg_name}"
  else
    log_warning "hdiutil not found, skipping DMG creation"
  fi
}

# Create ZIP
create_zip() {
  local version="$1"
  local app_name="$2"
  local arch="${VSCODE_ARCH:-x64}"
  
  log_info "Creating ZIP for ${arch}..."
  
  local app_path="${VSCODE_DIR}/.build/electron/${app_name}.app"
  
  if [[ ! -d "${app_path}" ]]; then
    log_error "App not found: ${app_path}"
    exit 1
  fi
  
  local zip_name="CortexIDE-${version}-darwin-${arch}.zip"
  
  cd "${BUILDER_DIR}"
  rm -f "${zip_name}"
  
  if command -v zip &> /dev/null; then
    zip -r "${zip_name}" "${app_path}" || {
      log_error "Failed to create ZIP"
      exit 1
    }
    log_success "ZIP created: ${zip_name}"
  else
    log_warning "zip command not found, skipping ZIP creation"
  fi
}

# Main packaging function
main() {
  log_info "Starting macOS packaging..."
  
  if [[ ! -d "${VSCODE_DIR}" ]]; then
    log_error "vscode directory not found: ${VSCODE_DIR}"
    exit 1
  fi
  
  # Get version info
  read -r version app_name <<< "$(get_version)"
  log_info "Version: ${version}, App: ${app_name}"
  
  # Create DMG
  create_dmg "${version}" "${app_name}"
  
  # Create ZIP
  create_zip "${version}" "${app_name}"
  
  log_success "macOS packaging completed!"
}

# Run main function
main "$@"

