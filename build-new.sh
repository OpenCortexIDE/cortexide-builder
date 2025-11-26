#!/usr/bin/env bash
# Streamlined Build Script for CortexIDE Builder
# This script orchestrates the build process using the unified build system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_DIR="${SCRIPT_DIR}"
CORTEXIDE_DIR="${BUILDER_DIR}/../cortexide"

# Set default environment variables before sourcing version.sh
export BUILD_SOURCEVERSION="${BUILD_SOURCEVERSION:-}"
export MS_COMMIT="${MS_COMMIT:-}"
export MS_TAG="${MS_TAG:-}"
export RELEASE_VERSION="${RELEASE_VERSION:-}"
export VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
export APP_NAME="${APP_NAME:-CortexIDE}"
export BINARY_NAME="${BINARY_NAME:-cortexide}"
export GH_REPO_PATH="${GH_REPO_PATH:-cortexide/cortexide}"
export ORG_NAME="${ORG_NAME:-cortexide}"
export CI_BUILD="${CI_BUILD:-no}"
export DISABLE_UPDATE="${DISABLE_UPDATE:-no}"

# Source version script if it exists (with error handling)
if [[ -f "${BUILDER_DIR}/version.sh" ]]; then
  set +u  # Temporarily allow unbound variables
  . "${BUILDER_DIR}/version.sh" 2>/dev/null || true
  set -u  # Re-enable strict mode
fi

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

# Validate environment
validate_environment() {
  log_info "Validating environment..."
  
  # In CI, get_repo.sh runs before build-new.sh and creates vscode/ directory
  # In local dev, we might have ../cortexide directory
  # Check if either exists
  if [[ -d "${BUILDER_DIR}/vscode" ]]; then
    log_success "vscode directory found (from get_repo.sh)"
  elif [[ -d "${CORTEXIDE_DIR}" ]]; then
    log_success "CortexIDE directory found locally"
  else
    log_warning "Neither vscode/ nor ../cortexide found"
    log_info "get_repo.sh should have created vscode/ directory"
    log_info "This is OK if get_repo.sh runs before build-new.sh in workflow"
  fi
  
  log_success "Environment validated"
}

# Get repository (copy or clone)
get_repository() {
  log_info "Preparing source repository..."
  
  # In CI, get_repo.sh runs before this and creates vscode/ directory
  # So if vscode exists, we're good - just skip
  if [[ -d "${BUILDER_DIR}/vscode" ]]; then
    log_info "vscode directory already exists (from get_repo.sh or previous run)"
    return 0
  fi
  
  # For local development, copy from ../cortexide if it exists
  if [[ -d "${CORTEXIDE_DIR}" ]]; then
    log_info "Copying CortexIDE repository to vscode directory..."
    
    # Use rsync to copy efficiently, excluding build artifacts
    rsync -a --delete \
      --exclude ".git" \
      --exclude "node_modules" \
      --exclude "out" \
      --exclude "out-*" \
      --exclude ".build" \
      --exclude ".vscode" \
      --exclude "**/.vscode" \
      --exclude "**/node_modules" \
      "${CORTEXIDE_DIR}/" "${BUILDER_DIR}/vscode/" || {
      log_error "Failed to copy CortexIDE repository"
      exit 1
    }
    
    log_success "Repository copied"
  else
    log_warning "Neither vscode/ nor ../cortexide found"
    log_info "In CI, get_repo.sh should create vscode/ before build-new.sh runs"
    log_info "For local dev, ensure ../cortexide exists or run get_repo.sh first"
    # Don't exit - in CI, get_repo.sh step should have already created vscode/
    # If it didn't, the build will fail later which is fine
  fi
}

# Prepare vscode (apply patches, update settings)
prepare_vscode() {
  log_info "Preparing vscode source..."
  
  cd "${BUILDER_DIR}/vscode" || {
    log_error "Failed to change to vscode directory"
    exit 1
  }
  
  # Apply patches if prepare_vscode.sh exists
  if [[ -f "${BUILDER_DIR}/prepare_vscode.sh" ]]; then
    log_info "Applying patches and preparing source..."
    # Change to builder directory so relative paths in prepare_vscode.sh work
    cd "${BUILDER_DIR}"
    . "${BUILDER_DIR}/prepare_vscode.sh" || {
      log_error "Failed to prepare vscode source"
      exit 1
    }
    cd "${BUILDER_DIR}/vscode" || exit 1
  else
    log_warning "prepare_vscode.sh not found, skipping preparation"
  fi
  
  log_success "Source preparation completed"
}

# Install dependencies
install_dependencies() {
  log_info "Installing dependencies..."
  
  cd "${BUILDER_DIR}/vscode" || {
    log_error "Failed to change to vscode directory"
    exit 1
  }
  
  # Check if node_modules exists
  if [[ ! -d "node_modules" ]] || [[ "${CLEAN_INSTALL:-no}" == "yes" ]]; then
    log_info "Running npm install..."
    
    # Set Node.js options
    export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=8192}"
    
    # Install dependencies
    if npm ci --prefer-offline --no-audit; then
      log_success "Dependencies installed"
    else
      log_warning "npm ci failed, trying npm install..."
      npm install --prefer-offline --no-audit || {
        log_error "Failed to install dependencies"
        exit 1
      }
    fi
  else
    log_info "Dependencies already installed, skipping"
  fi
}

# Build using unified build script
build_application() {
  log_info "Building application using unified build script..."
  
  cd "${BUILDER_DIR}/vscode" || {
    log_error "Failed to change to vscode directory"
    exit 1
  }
  
  # Check if unified build script exists in vscode/scripts
  if [[ -f "scripts/build.sh" ]]; then
    # Make build script executable
    chmod +x scripts/build.sh
    
    # Run unified build script
    if ./scripts/build.sh --verbose; then
      log_success "Application built successfully"
    else
      log_error "Build failed"
      exit 1
    fi
  elif [[ -f "${CORTEXIDE_DIR}/scripts/build.sh" ]]; then
    # Fallback: use build script from cortexide directory
    log_info "Using build script from cortexide directory..."
    chmod +x "${CORTEXIDE_DIR}/scripts/build.sh"
    if "${CORTEXIDE_DIR}/scripts/build.sh" --verbose; then
      log_success "Application built successfully"
    else
      log_error "Build failed"
      exit 1
    fi
  else
    # Fallback to legacy build method (npm run compile)
    log_warning "Unified build script not found, using legacy build method..."
    export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=12288}"
    
    # Build React components first
    if [[ -d "src/vs/workbench/contrib/cortexide/browser/react" ]]; then
      log_info "Building React components..."
      npm run buildreact || {
        log_warning "React build failed, continuing..."
      }
    fi
    
    # Compile TypeScript
    log_info "Compiling TypeScript..."
    if npm run compile; then
      log_success "Application built successfully"
    else
      log_error "Build failed"
      exit 1
    fi
  fi
}

# Package application
package_application() {
  log_info "Packaging application..."
  
  cd "${BUILDER_DIR}/vscode" || {
    log_error "Failed to change to vscode directory"
    exit 1
  }
  
  # Detect platform
  case "$(uname -s)" in
    Darwin*)
      OS_NAME="osx"
      ;;
    Linux*)
      OS_NAME="linux"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      OS_NAME="windows"
      ;;
    *)
      log_error "Unsupported platform"
      exit 1
      ;;
  esac
  
  # Detect architecture
  case "$(uname -m)" in
    x86_64)
      VSCODE_ARCH="x64"
      ;;
    arm64|aarch64)
      VSCODE_ARCH="arm64"
      ;;
    *)
      VSCODE_ARCH="x64"
      ;;
  esac
  
  # Use platform-specific packaging
  if [[ -f "${BUILDER_DIR}/build/${OS_NAME}/package.sh" ]]; then
    log_info "Using platform-specific packaging script..."
    . "${BUILDER_DIR}/build/${OS_NAME}/package.sh" || {
      log_error "Packaging failed"
      exit 1
    }
  else
    log_warning "Platform-specific packaging script not found, using generic package script"
    if [[ -f "scripts/package.sh" ]]; then
      ./scripts/package.sh "${OS_NAME}" "${VSCODE_ARCH}" || {
        log_error "Packaging failed"
        exit 1
      }
    fi
  fi
  
  log_success "Application packaged successfully"
}

# Main build function
main() {
  log_info "Starting CortexIDE build process..."
  log_info "Builder directory: ${BUILDER_DIR}"
  log_info "CortexIDE directory: ${CORTEXIDE_DIR}"
  
  # Validate environment
  validate_environment
  
  # Get repository
  if [[ "${SKIP_SOURCE:-no}" != "yes" ]]; then
    get_repository
  fi
  
  # Prepare vscode
  if [[ "${SKIP_PREPARE:-no}" != "yes" ]]; then
    prepare_vscode
  fi
  
  # Install dependencies
  if [[ "${SKIP_INSTALL:-no}" != "yes" ]]; then
    install_dependencies
  fi
  
  # Build application
  if [[ "${SKIP_BUILD:-no}" != "yes" ]]; then
    build_application
  fi
  
  # Package application
  if [[ "${SKIP_PACKAGE:-no}" != "yes" ]]; then
    package_application
  fi
  
  log_success "Build process completed successfully!"
}

# Run main function
main "$@"

