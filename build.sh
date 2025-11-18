#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

. version.sh

if [[ "${SHOULD_BUILD}" == "yes" ]]; then
  echo "MS_COMMIT=\"${MS_COMMIT}\""

  # Pre-build dependency checks
  echo "Checking build dependencies..."
  MISSING_DEPS=0
  
  # Check required commands
  for cmd in node npm jq git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: Required command '$cmd' is not installed" >&2
      MISSING_DEPS=1
    fi
  done
  
  # Check Node.js version
  NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
  if [[ "${NODE_VERSION}" -lt 20 ]]; then
    echo "Error: Node.js 20.x or higher is required. Current: $(node -v)" >&2
    MISSING_DEPS=1
  fi
  
  # Check platform-specific tools
  if [[ "${OS_NAME}" == "osx" ]]; then
    if ! command -v clang++ >/dev/null 2>&1; then
      echo "Warning: clang++ not found. Build may fail." >&2
    fi
  elif [[ "${OS_NAME}" == "linux" ]]; then
    for cmd in gcc g++ make; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Warning: '$cmd' not found. Build may fail." >&2
      fi
    done
  fi
  
  # Check if vscode directory will exist
  if [[ ! -d "vscode" ]] && [[ ! -d "../cortexide" ]]; then
    echo "Warning: Neither 'vscode' nor '../cortexide' directory found. get_repo.sh should create it." >&2
  fi
  
  if [[ $MISSING_DEPS -eq 1 ]]; then
    echo "Error: Missing required dependencies. Please install them before building." >&2
    exit 1
  fi
  
  echo "Dependency checks passed."

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  export NODE_OPTIONS="--max-old-space-size=8192"

  # Skip monaco-compile-check as it's failing due to searchUrl property
  # Skip valid-layers-check as well since it might depend on monaco
  # Void commented these out
  # npm run monaco-compile-check
  # npm run valid-layers-check

  echo "Building React components..."
  # Verify cross-spawn is available before running buildreact
  if [[ ! -d "node_modules/cross-spawn" ]] && [[ ! -f "node_modules/cross-spawn/package.json" ]]; then
    echo "Error: cross-spawn dependency is missing. Installing..." >&2
    if ! npm install cross-spawn; then
      echo "Error: Failed to install cross-spawn. Cannot continue with buildreact." >&2
      echo "Try running: npm install" >&2
      exit 1
    fi
  fi
  
  if ! npm run buildreact; then
    echo "Error: buildreact failed. Check for:" >&2
    echo "  - Missing dependencies (run: npm install)" >&2
    echo "  - cross-spawn not installed (run: npm install cross-spawn)" >&2
    echo "  - TypeScript compilation errors" >&2
    echo "  - React build script issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  echo "Compiling build without mangling..."
  # Verify ternary-stream is available before running gulp
  if [[ ! -d "node_modules/ternary-stream" ]] && [[ ! -f "node_modules/ternary-stream/package.json" ]]; then
    echo "Error: ternary-stream dependency is missing. Installing..." >&2
    # Try installing in build directory first
    if [[ -f "build/package.json" ]]; then
      (cd build && npm install ternary-stream 2>&1 | tail -20) || {
        echo "Trying to install at root level..." >&2
        npm install ternary-stream 2>&1 | tail -20 || {
          echo "Error: Failed to install ternary-stream. Cannot continue." >&2
          echo "Try running: cd vscode && npm install ternary-stream" >&2
          exit 1
        }
      }
    else
      npm install ternary-stream 2>&1 | tail -20 || {
        echo "Error: Failed to install ternary-stream. Cannot continue." >&2
        exit 1
      }
    fi
  fi
  
  if ! npm run gulp compile-build-without-mangling; then
    echo "Error: compile-build-without-mangling failed. Check for:" >&2
    echo "  - TypeScript compilation errors" >&2
    echo "  - Missing build dependencies (ternary-stream)" >&2
    echo "  - Gulp task configuration issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  echo "Compiling extension media..."
  if ! npm run gulp compile-extension-media; then
    echo "Error: compile-extension-media failed. Check for:" >&2
    echo "  - Missing media files" >&2
    echo "  - Asset compilation errors" >&2
    echo "  - Gulp task issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  echo "Compiling extensions build..."
  if ! npm run gulp compile-extensions-build; then
    echo "Error: compile-extensions-build failed. Check for:" >&2
    echo "  - Extension compilation errors" >&2
    echo "  - Missing extension dependencies" >&2
    echo "  - Gulp task configuration issues" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi
  
  # Fix CSS paths in out-build directory before minify
  # This fixes paths that get incorrectly modified during the build process
  echo "Fixing CSS paths in out-build directory..."
  
  # Determine sed command based on system (GNU vs BSD)
  if sed --version >/dev/null 2>&1; then
    SED_CMD="sed -i"
  else
    SED_CMD="sed -i ''"
  fi
  
  # Fix editorgroupview.css: ../../media/code-icon.svg -> ../../../media/code-icon.svg
  if [[ -f "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" ]]; then
    if grep -q "../../media/code-icon.svg" "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null; then
      echo "Fixing path in out-build/editorgroupview.css..."
      $SED_CMD "s|url('../../media/code-icon\.svg')|url('../../../media/code-icon.svg')|g" "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null || true
      $SED_CMD "s|url(\"../../media/code-icon\.svg\")|url('../../../media/code-icon.svg')|g" "out-build/vs/workbench/browser/parts/editor/media/editorgroupview.css" 2>/dev/null || true
    fi
  fi
  
  # Fix void.css: ../../browser/media/code-icon.svg -> ../../../../browser/media/code-icon.svg
  if [[ -f "out-build/vs/workbench/contrib/void/browser/media/void.css" ]]; then
    if grep -q "../../browser/media/code-icon.svg" "out-build/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null; then
      echo "Fixing path in out-build/void.css..."
      $SED_CMD "s|url('../../browser/media/code-icon\.svg')|url('../../../../browser/media/code-icon.svg')|g" "out-build/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null || true
      $SED_CMD "s|url(\"../../browser/media/code-icon\.svg\")|url('../../../../browser/media/code-icon.svg')|g" "out-build/vs/workbench/contrib/void/browser/media/void.css" 2>/dev/null || true
    fi
  fi
  
  # Fix any other CSS files in out-build/browser/parts with incorrect paths to media/
  find out-build/vs/workbench/browser/parts -name "*.css" -type f 2>/dev/null | while read -r css_file; do
    if [[ -f "$css_file" ]] && grep -q "../../media/code-icon.svg" "$css_file" 2>/dev/null; then
      echo "Fixing path in $css_file (parts/*/media/)..."
      $SED_CMD "s|url('../../media/code-icon\.svg')|url('../../../media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
      $SED_CMD "s|url(\"../../media/code-icon\.svg\")|url('../../../media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
    fi
  done
  
  # Fix any CSS files in out-build/contrib with incorrect paths to browser/media/
  find out-build/vs/workbench/contrib -path "*/browser/media/*.css" -type f 2>/dev/null | while read -r css_file; do
    if [[ -f "$css_file" ]] && grep -q "../../browser/media/code-icon.svg" "$css_file" 2>/dev/null; then
      echo "Fixing path in $css_file (contrib/*/browser/media/)..."
      $SED_CMD "s|url('../../browser/media/code-icon\.svg')|url('../../../../browser/media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
      $SED_CMD "s|url(\"../../browser/media/code-icon\.svg\")|url('../../../../browser/media/code-icon.svg')|g" "$css_file" 2>/dev/null || true
    fi
  done
  
  # Also check for any other incorrect relative paths that might cause issues
  # Pattern: ../../media/ from parts/*/media/ (too short, should be ../../../media/)
  find out-build/vs/workbench/browser/parts -path "*/media/*.css" -type f 2>/dev/null | while read -r css_file; do
    if [[ -f "$css_file" ]] && grep -q "url(['\"]\.\./\.\./media/[^'\"].*['\"])" "$css_file" 2>/dev/null; then
      # Check if it's not void-icon-sm.png (which uses correct ../../../../browser/media/)
      if ! grep -q "void-icon-sm.png" "$css_file" 2>/dev/null; then
        echo "Warning: Potential incorrect path in $css_file"
        echo "  Check if relative path is correct for this file location"
      fi
    fi
  done
  
  echo "Minifying VS Code..."
  if ! npm run gulp minify-vscode; then
    echo "Error: minify-vscode failed. Check for:" >&2
    echo "  - CSS path issues (check out-build directory)" >&2
    echo "  - Minification errors" >&2
    echo "  - Missing source files" >&2
    echo "  - Memory issues (try increasing NODE_OPTIONS)" >&2
    echo "  - Check logs above for specific errors" >&2
    exit 1
  fi

  if [[ "${OS_NAME}" == "osx" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies darwin # Void commented this out

    echo "Building macOS package for ${VSCODE_ARCH}..."
    if ! npm run gulp "vscode-darwin-${VSCODE_ARCH}-min-ci"; then
      echo "Error: macOS build failed for ${VSCODE_ARCH}. Check for:" >&2
      echo "  - Electron packaging errors" >&2
      echo "  - Missing build artifacts" >&2
      echo "  - Code signing issues (if applicable)" >&2
      echo "  - Architecture mismatch" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi

    find "../VSCode-darwin-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

    if ! . ../build_cli.sh; then
      echo "Error: CLI build failed for macOS. Check for:" >&2
      echo "  - Rust/Cargo compilation errors" >&2
      echo "  - Missing Rust toolchain" >&2
      echo "  - Architecture-specific build issues" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi

    VSCODE_PLATFORM="darwin"
  elif [[ "${OS_NAME}" == "windows" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies win32 # Void commented this out

    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      . ../build/windows/rtf/make.sh

      echo "Building Windows package for ${VSCODE_ARCH}..."
      if ! npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"; then
        echo "Error: Windows build failed for ${VSCODE_ARCH}. Check for:" >&2
        echo "  - Electron packaging errors" >&2
        echo "  - Missing build artifacts" >&2
        echo "  - Architecture mismatch" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi

      if [[ "${VSCODE_ARCH}" != "x64" ]]; then
        SHOULD_BUILD_REH="no"
        SHOULD_BUILD_REH_WEB="no"
      fi

      if ! . ../build_cli.sh; then
        echo "Error: CLI build failed for Windows. Check for:" >&2
        echo "  - Rust/Cargo compilation errors" >&2
        echo "  - Missing Rust toolchain" >&2
        echo "  - Architecture-specific build issues" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi
    fi

    VSCODE_PLATFORM="win32"
  else # linux
    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      echo "Building Linux package for ${VSCODE_ARCH}..."
      if ! npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"; then
        echo "Error: Linux build failed for ${VSCODE_ARCH}. Check for:" >&2
        echo "  - Electron packaging errors" >&2
        echo "  - Missing build artifacts" >&2
        echo "  - Architecture mismatch" >&2
        echo "  - Missing system libraries" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi

      find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

      if ! . ../build_cli.sh; then
        echo "Error: CLI build failed for Linux. Check for:" >&2
        echo "  - Rust/Cargo compilation errors" >&2
        echo "  - Missing Rust toolchain" >&2
        echo "  - Architecture-specific build issues" >&2
        echo "  - Check logs above for specific errors" >&2
        exit 1
      fi
    fi

    VSCODE_PLATFORM="linux"
  fi

  if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
    echo "Building REH (Remote Extension Host)..."
    if ! npm run gulp minify-vscode-reh; then
      echo "Error: minify-vscode-reh failed. Check for:" >&2
      echo "  - Minification errors" >&2
      echo "  - Missing source files" >&2
      echo "  - Memory issues" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
    if ! npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"; then
      echo "Error: REH build failed for ${VSCODE_PLATFORM}-${VSCODE_ARCH}. Check for:" >&2
      echo "  - REH packaging errors" >&2
      echo "  - Missing build artifacts" >&2
      echo "  - Architecture/platform mismatch" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    echo "Building REH-web (Remote Extension Host Web)..."
    if ! npm run gulp minify-vscode-reh-web; then
      echo "Error: minify-vscode-reh-web failed. Check for:" >&2
      echo "  - Minification errors" >&2
      echo "  - Missing source files" >&2
      echo "  - Memory issues" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
    if ! npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"; then
      echo "Error: REH-web build failed for ${VSCODE_PLATFORM}-${VSCODE_ARCH}. Check for:" >&2
      echo "  - REH-web packaging errors" >&2
      echo "  - Missing build artifacts" >&2
      echo "  - Architecture/platform mismatch" >&2
      echo "  - Check logs above for specific errors" >&2
      exit 1
    fi
  fi

  cd ..
fi
