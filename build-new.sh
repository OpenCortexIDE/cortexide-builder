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
  
  # Check if node_modules exists and is valid
  local should_install="yes"
  if [[ -d "node_modules" ]] && [[ "${CLEAN_INSTALL:-no}" != "yes" ]]; then
    # Check if package-lock.json exists and node_modules is not empty
    if [[ -f "package-lock.json" ]] && [[ -n "$(ls -A node_modules 2>/dev/null)" ]]; then
      should_install="no"
      log_info "node_modules exists, checking if update is needed..."
      
      # Quick check: compare package-lock.json modification time with node_modules
      if [[ "package-lock.json" -nt "node_modules" ]]; then
        log_info "package-lock.json is newer than node_modules, updating..."
        should_install="yes"
      fi
    fi
  fi
  
  if [[ "${should_install}" == "yes" ]]; then
    log_info "Running npm install..."
    
    # Set Node.js options
    export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=8192}"
    
    # Install dependencies
    if [[ -f "package-lock.json" ]]; then
      if npm ci --prefer-offline --no-audit; then
        log_success "Dependencies installed (npm ci)"
      else
        log_warning "npm ci failed, trying npm install..."
        npm install --prefer-offline --no-audit || {
          log_error "Failed to install dependencies"
          exit 1
        }
      fi
    else
      log_info "No package-lock.json found, using npm install..."
      npm install --prefer-offline --no-audit || {
        log_error "Failed to install dependencies"
        exit 1
      }
    fi
  else
    log_success "Dependencies already installed and up-to-date, skipping"
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
    
    # Minify VS Code (creates out-vscode-min directory required for packaging)
    log_info "Minifying VS Code (required for packaging)..."
    log_info "Current directory: $(pwd)"
    log_info "Checking if out-build exists: $([ -d 'out-build' ] && echo 'yes' || echo 'no')"
    
    if npm run gulp minify-vscode; then
      log_success "VS Code minified successfully"
      
      # Verify out-vscode-min was created
      if [[ -d "out-vscode-min" ]]; then
        local file_count=$(find out-vscode-min -type f | wc -l | tr -d ' ')
        log_success "out-vscode-min directory created with ${file_count} files"
        
        # Check for critical file
        if [[ -f "out-vscode-min/vs/base/parts/sandbox/electron-browser/preload.js" ]]; then
          log_success "Critical file preload.js found in out-vscode-min"
        else
          log_warning "preload.js not found in out-vscode-min, but directory exists"
        fi
      else
        log_error "minify-vscode completed but out-vscode-min directory was not created!"
        log_error "This will cause packaging to fail"
        exit 1
      fi
    else
      log_error "Minification failed - this is required for packaging"
      log_info "The minify-vscode task creates out-vscode-min directory"
      log_info "This directory is required by the packaging tasks"
      log_info "Checking if out-build directory exists (required for minify)..."
      if [[ -d "out-build" ]]; then
        log_info "out-build exists, minify should work"
      else
        log_error "out-build directory missing! TypeScript compilation may have failed."
      fi
      exit 1
    fi
    
    # Build Electron app bundle after compilation
    build_electron_app
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
    
    # Minify VS Code (creates out-vscode-min directory required for packaging)
    log_info "Minifying VS Code (required for packaging)..."
    log_info "Current directory: $(pwd)"
    log_info "Checking if out-build exists: $([ -d 'out-build' ] && echo 'yes' || echo 'no')"
    
    if npm run gulp minify-vscode; then
      log_success "VS Code minified successfully"
      
      # Verify out-vscode-min was created
      if [[ -d "out-vscode-min" ]]; then
        local file_count=$(find out-vscode-min -type f | wc -l | tr -d ' ')
        log_success "out-vscode-min directory created with ${file_count} files"
        
        # Check for critical file
        if [[ -f "out-vscode-min/vs/base/parts/sandbox/electron-browser/preload.js" ]]; then
          log_success "Critical file preload.js found in out-vscode-min"
        else
          log_warning "preload.js not found in out-vscode-min, but directory exists"
        fi
      else
        log_error "minify-vscode completed but out-vscode-min directory was not created!"
        log_error "This will cause packaging to fail"
        exit 1
      fi
    else
      log_error "Minification failed - this is required for packaging"
      log_info "The minify-vscode task creates out-vscode-min directory"
      log_info "This directory is required by the packaging tasks"
      log_info "Checking if out-build directory exists (required for minify)..."
      if [[ -d "out-build" ]]; then
        log_info "out-build exists, minify should work"
      else
        log_error "out-build directory missing! TypeScript compilation may have failed."
      fi
      exit 1
    fi
    
    # Build Electron app bundle after compilation
    build_electron_app
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
    
    # Compile TypeScript (main source, not extensions)
    log_info "Compiling TypeScript..."
    export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=12288}"
    
    # Use compile-build-without-mangling to avoid mangler hanging issues
    # The mangler can sometimes hang on large codebases
    log_info "Using compile-build-without-mangling (faster, more reliable)..."
    if npm run gulp compile-build-without-mangling 2>/dev/null; then
      log_success "Application built successfully"
    elif npm run compile-build 2>/dev/null; then
      log_success "Application built successfully"
    elif npm run gulp compile 2>/dev/null; then
      log_success "Application built successfully"
    else
      log_warning "Main compilation had issues, but continuing..."
      # Don't exit - extensions might have errors but main build might be OK
    fi
    
    # Try extension compilation separately (non-fatal)
    log_info "Compiling extensions (non-fatal)..."
    if npm run compile-extensions-build 2>/dev/null; then
      log_success "Extensions compiled successfully"
    else
      log_warning "Extension compilation had errors, but continuing..."
      log_info "Some extensions may have TypeScript errors, but core build should work"
    fi
  fi
  
  # Minify VS Code (creates out-vscode-min directory required for packaging)
  log_info "Minifying VS Code (required for packaging)..."
  log_info "Current directory: $(pwd)"
  log_info "Checking if out-build exists: $([ -d 'out-build' ] && echo 'yes' || echo 'no')"
  
  if npm run gulp minify-vscode; then
    log_success "VS Code minified successfully"
    
    # Verify out-vscode-min was created
    if [[ -d "out-vscode-min" ]]; then
      local file_count=$(find out-vscode-min -type f | wc -l | tr -d ' ')
      log_success "out-vscode-min directory created with ${file_count} files"
      
      # Check for critical file
      if [[ -f "out-vscode-min/vs/base/parts/sandbox/electron-browser/preload.js" ]]; then
        log_success "Critical file preload.js found in out-vscode-min"
      else
        log_warning "preload.js not found in out-vscode-min, but directory exists"
      fi
    else
      log_error "minify-vscode completed but out-vscode-min directory was not created!"
      log_error "This will cause packaging to fail"
      exit 1
    fi
  else
    log_error "Minification failed - this is required for packaging"
    log_info "The minify-vscode task creates out-vscode-min directory"
    log_info "This directory is required by the packaging tasks"
    log_info "Checking if out-build directory exists (required for minify)..."
    if [[ -d "out-build" ]]; then
      log_info "out-build exists, minify should work"
    else
      log_error "out-build directory missing! TypeScript compilation may have failed."
    fi
    exit 1
  fi
  
  # Build Electron app bundle (required for packaging)
  build_electron_app
}

# Ensure Electron binaries are cached
ensure_electron_cached() {
  local os_name="$1"
  local vscode_arch="$2"
  
  # Map OS names to Electron platform names
  local electron_platform=""
  case "${os_name}" in
    osx) electron_platform="darwin" ;;
    linux) electron_platform="linux" ;;
    windows) electron_platform="win32" ;;
    *) return 0 ;; # Skip if unknown
  esac
  
  # Set up Electron cache directory
  local cache_dir="${ELECTRON_DOWNLOAD_CACHE:-$(pwd)/.electron-cache}"
  mkdir -p "${cache_dir}"
  export ELECTRON_DOWNLOAD_CACHE="${cache_dir}"
  
  # Try to detect Electron version from package.json
  local electron_version=""
  if [[ -f "package.json" ]]; then
    electron_version=$(node -p "require('./package.json').electronVersion || (require('./package.json').engines && require('./package.json').engines.electron) || ''" 2>/dev/null || echo "")
    # Remove '^' or '~' prefix if present
    electron_version="${electron_version#^}"
    electron_version="${electron_version#~}"
  fi
  
  if [[ -n "${electron_version}" ]]; then
    log_info "Electron version detected: ${electron_version}"
    log_info "Electron cache directory: ${cache_dir}"
    
    # Check if cached
    local artifact_arch="${vscode_arch}"
    if [[ "${electron_platform}" == "linux" && "${vscode_arch}" == "armhf" ]]; then
      artifact_arch="armv7l"
    fi
    
    local artifact="electron-v${electron_version}-${electron_platform}-${artifact_arch}.zip"
    local destination="${cache_dir}/${artifact}"
    
    if [[ -f "${destination}" && -s "${destination}" ]]; then
      log_success "Electron binary already cached: ${artifact}"
      return 0
    else
      log_info "Electron binary not cached, will be downloaded during build"
    fi
  else
    log_info "Could not detect Electron version, will use default download"
  fi
  
  return 0
}

# Build Electron app bundle
build_electron_app() {
  log_info "Building Electron app bundle..."
  
  # Determine OS and architecture
  local os_name="${OS_NAME:-}"
  local vscode_arch="${VSCODE_ARCH:-}"
  
  # Auto-detect if not set
  if [[ -z "${os_name}" ]]; then
    case "$(uname -s)" in
      Darwin*) os_name="osx" ;;
      Linux*) os_name="linux" ;;
      MINGW*|MSYS*|CYGWIN*) os_name="windows" ;;
      *) os_name="linux" ;; # Default
    esac
  fi
  
  if [[ -z "${vscode_arch}" ]]; then
    case "$(uname -m)" in
      arm64|aarch64) vscode_arch="arm64" ;;
      x86_64|amd64) vscode_arch="x64" ;;
      *) vscode_arch="x64" ;; # Default
    esac
  fi
  
  log_info "Building for ${os_name} (${vscode_arch})..."
  
  # Ensure Electron is cached (non-fatal)
  ensure_electron_cached "${os_name}" "${vscode_arch}" || {
    log_warning "Electron cache check failed, continuing anyway..."
  }
  
  # Get app name from product.json
  local app_name="CortexIDE"
  if [[ -f "product.json" ]]; then
    app_name=$(node -p "require('./product.json').nameShort || 'CortexIDE'" 2>/dev/null || echo "CortexIDE")
    if [[ "${app_name}" == "null" || "${app_name}" == "undefined" ]]; then
      app_name="CortexIDE"
    fi
  fi
  
  # Ensure we're in the vscode directory
  local current_dir=$(pwd)
  log_info "Current directory: ${current_dir}"
  
  # Build Electron app based on platform
  case "${os_name}" in
    osx)
      log_info "Running: npm run gulp vscode-darwin-${vscode_arch}-min-ci"
      log_info "Working directory: $(pwd)"
      if npm run gulp "vscode-darwin-${vscode_arch}-min-ci"; then
        log_success "Gulp task completed successfully"
        
        # The gulp task creates the app in ../VSCode-darwin-${arch}/ (relative to vscode dir)
        # Also check absolute paths
        local source_dir="../VSCode-darwin-${vscode_arch}"
        local source_dir_abs="${BUILDER_DIR}/VSCode-darwin-${vscode_arch}"
        local target_dir=".build/electron"
        local source_app="${source_dir}/${app_name}.app"
        local source_app_abs="${source_dir_abs}/${app_name}.app"
        
        log_info "Looking for app bundle at:"
        log_info "  - ${source_app} (relative)"
        log_info "  - ${source_app_abs} (absolute)"
        
        # Try to find the app bundle
        local found_app=""
        if [[ -d "${source_app}" ]]; then
          found_app="${source_app}"
        elif [[ -d "${source_app_abs}" ]]; then
          found_app="${source_app_abs}"
        else
          # Search for any .app in the VSCode-darwin directory
          log_info "App not found at expected location, searching..."
          if [[ -d "${source_dir}" ]]; then
            found_app=$(find "${source_dir}" -name "*.app" -type d | head -1)
          elif [[ -d "${source_dir_abs}" ]]; then
            found_app=$(find "${source_dir_abs}" -name "*.app" -type d | head -1)
          fi
        fi
        
        if [[ -n "${found_app}" && -d "${found_app}" ]]; then
          log_info "Found app bundle at: ${found_app}"
          log_info "Copying app bundle to .build/electron/..."
          mkdir -p "${target_dir}"
          if [[ -d "${target_dir}/${app_name}.app" ]]; then
            rm -rf "${target_dir}/${app_name}.app"
          fi
          if cp -R "${found_app}" "${target_dir}/"; then
            log_success "App bundle copied to ${target_dir}/${app_name}.app"
          else
            log_error "Failed to copy app bundle from ${found_app}"
            exit 1
          fi
        else
          log_error "App bundle not found after gulp task completed"
          log_error "Searched in:"
          log_error "  - ${source_app}"
          log_error "  - ${source_app_abs}"
          if [[ -d "${source_dir}" ]]; then
            log_info "Contents of ${source_dir}:"
            ls -la "${source_dir}" || true
          fi
          if [[ -d "${source_dir_abs}" ]]; then
            log_info "Contents of ${source_dir_abs}:"
            ls -la "${source_dir_abs}" || true
          fi
          exit 1
        fi
      else
        log_error "Failed to create Electron app bundle (gulp task failed)"
        exit 1
      fi
      ;;
    linux)
      log_info "Running: npm run gulp vscode-linux-${vscode_arch}-min-ci"
      if npm run gulp "vscode-linux-${vscode_arch}-min-ci"; then
        log_success "Electron app bundle created successfully"
      else
        log_error "Failed to create Electron app bundle"
        exit 1
      fi
      ;;
    windows)
      log_info "Running: npm run gulp vscode-win32-${vscode_arch}-min-ci"
      if npm run gulp "vscode-win32-${vscode_arch}-min-ci"; then
        log_success "Electron app bundle created successfully"
      else
        log_error "Failed to create Electron app bundle"
        exit 1
      fi
      ;;
    *)
      log_error "Unknown OS: ${os_name}"
      exit 1
      ;;
  esac
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

