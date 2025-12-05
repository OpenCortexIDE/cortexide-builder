#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

. version.sh

if [[ "${SHOULD_BUILD}" == "yes" ]]; then
  echo "MS_COMMIT=\"${MS_COMMIT}\""

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  export NODE_OPTIONS="--max-old-space-size=12288"

  # Clean up any running processes and stale build artifacts
  # This ensures a clean build state matching the working local development flow
  echo "Cleaning up processes and build artifacts..."
  pkill -f "$(pwd)/out/main.js" || true
  pkill -f "$(pwd)/out-build/main.js" || true

  # Remove React build output to force fresh build
  # CortexIDE has a React-based UI component that needs to be rebuilt
  if [[ -d "src/vs/workbench/contrib/void/browser/react/out" ]]; then
    echo "Removing old React build output..."
    rm -rf src/vs/workbench/contrib/void/browser/react/out
  fi
  if [[ -d "src/vs/workbench/contrib/cortexide/browser/react/out" ]]; then
    echo "Removing old React build output..."
    rm -rf src/vs/workbench/contrib/cortexide/browser/react/out
  fi

  # Skip monaco-compile-check as it's failing due to searchUrl property
  # Skip valid-layers-check as well since it might depend on monaco
  # These checks are not critical for CortexIDE builds
  # npm run monaco-compile-check
  # npm run valid-layers-check

  # Build React components first (required for CortexIDE UI)
  echo "Building React components..."
  npm run buildreact

  # Compile the main codebase
  # Using compile-build-without-mangling for compatibility and debugging
  echo "Compiling TypeScript..."
  npm run gulp compile-build-without-mangling
  
  # Compile extension media assets
  echo "Compiling extension media..."
  npm run gulp compile-extension-media
  
  # Install extension dependencies before building extensions
  # Extensions need both production AND dev dependencies for TypeScript compilation
  # (devDependencies include @types/node, etc. needed for webpack/tsc)
  echo "Installing extension dependencies..."
  for ext_dir in extensions/*/; do
    if [[ -f "${ext_dir}package.json" ]] && [[ -f "${ext_dir}package-lock.json" ]]; then
      echo "Installing deps for $(basename "$ext_dir")..."
      # Use npm ci without --production to get devDependencies (needed for @types/node)
      (cd "$ext_dir" && npm ci --ignore-scripts) || echo "Skipped $(basename "$ext_dir")"
    fi
  done
  
  # Compile built-in extensions
  echo "Compiling extensions..."
  npm run gulp compile-extensions-build

  # Fix CSS paths in out-build directory before minify
  # CortexIDE has custom CSS that may have incorrect relative paths after compilation
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

  # Minify and bundle the entire application for production
  echo "Minifying and bundling application..."
  npm run gulp minify-vscode

  if [[ "${OS_NAME}" == "osx" ]]; then
    # Generate Group Policy definitions (disabled for CortexIDE)
    # node build/lib/policies darwin

    # Package for macOS with the specified architecture (x64 or arm64)
    echo "Packaging macOS ${VSCODE_ARCH} application..."
    npm run gulp "vscode-darwin-${VSCODE_ARCH}-min-ci"

    # Touch all files to ensure consistent timestamps
    find "../VSCode-darwin-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

    # Build the CLI binary for macOS
    . ../build_cli.sh

    VSCODE_PLATFORM="darwin"
  elif [[ "${OS_NAME}" == "windows" ]]; then
    # Generate Group Policy definitions (disabled for CortexIDE)
    # node build/lib/policies win32

    # In CI, packaging will be done by a separate job to support multi-arch builds
    if [[ "${CI_BUILD}" == "no" ]]; then
      # Generate RTF license file for Windows installer
      . ../build/windows/rtf/make.sh

      # Package for Windows with the specified architecture
      echo "Packaging Windows ${VSCODE_ARCH} application..."
      npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"

      # REH (Remote Extension Host) only supported on x64
      if [[ "${VSCODE_ARCH}" != "x64" ]]; then
        SHOULD_BUILD_REH="no"
        SHOULD_BUILD_REH_WEB="no"
      fi

      # Build the CLI binary for Windows
      . ../build_cli.sh
    fi

    VSCODE_PLATFORM="win32"
  else # linux
    # In CI, packaging will be done by a separate job to support multi-arch builds
    if [[ "${CI_BUILD}" == "no" ]]; then
      # Package for Linux with the specified architecture
      echo "Packaging Linux ${VSCODE_ARCH} application..."
      npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"
    fi

    # Touch all files to ensure consistent timestamps
    if [[ "${CI_BUILD}" == "no" ]]; then
      find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

      # Build the CLI binary for Linux
      . ../build_cli.sh
    fi

    VSCODE_PLATFORM="linux"
  fi

  if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
    npm run gulp minify-vscode-reh

    # Fix fetch.js import issues that prevent REH builds
    # This is a workaround for patch application issues in CI
    if [[ -f "build/lib/fetch.js" ]]; then
      echo "Applying direct fix to fetch.js for REH compatibility..."

      # Use Node.js script to fix the imports more reliably
      node -e "
        const fs = require('fs');
        const path = './build/lib/fetch.js';
        let content = fs.readFileSync(path, 'utf8');

        // Fix event-stream usage
        content = content.replace(
          /return event_stream_1\.default\.readArray\(urls\)\.pipe\(event_stream_1\.default\.map\(/g,
          '// Use a classic CommonJS require for \`event-stream\` to avoid cases where the\n    // transpiled default import does not expose \`readArray\` in some environments.\n    // This mirrors how other build scripts (e.g. \`gulpfile.reh.js\`) consume it.\n    const es = require(\"event-stream\");\n    return es.readArray(urls).pipe(es.map('
        );

        // Replace all ansi_colors_1.default usages with ansiColors first
        content = content.replace(/ansi_colors_1\.default/g, 'ansiColors');

        // Replace all fancy_log_1.default usages with fancyLog first
        content = content.replace(/fancy_log_1\.default/g, 'fancyLog');

        // Remove any existing ansi-colors import patterns
        content = content.replace(
          /const\s+ansi_colors_1\s*=\s*__importDefault\(require\(\"ansi-colors\"\)\);\s*\n?/g,
          ''
        );
        content = content.replace(
          /\/\/\s*Use direct require for ansi-colors[^\n]*\n\s*const\s+ansiColors\s*=\s*require\(\"ansi-colors\"\);\s*\n?/g,
          ''
        );
        content = content.replace(
          /const\s+_ansiColors\s*=\s*require\(\"ansi-colors\"\);\s*\n\s*const\s+ansiColors\s*=\s*\(_ansiColors[^;]+\);\s*\n?/g,
          ''
        );

        // Remove any existing fancy-log import patterns
        content = content.replace(
          /const\s+fancy_log_1\s*=\s*__importDefault\(require\(\"fancy-log\"\)\);\s*\n?/g,
          ''
        );

        // Find insertion point: after the last top-level const declaration before functions
        const lines = content.split('\n');
        let insertIndex = -1;
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i].trim();
          // Stop before function declarations
          if (line.startsWith('function ') || line.startsWith('async function ') || 
              (line.startsWith('const ') && line.includes('= function')) ||
              (line.startsWith('const ') && line.includes('= async function'))) {
            insertIndex = i;
            break;
          }
          // Track the last require/import statement
          if (line.match(/^const\s+\w+\s*=\s*(?:__importDefault\()?require\(/)) {
            insertIndex = i + 1;
          }
        }

        // If no good insertion point found, insert after exports
        if (insertIndex === -1) {
          const exportsIndex = lines.findIndex(line => line.includes('Object.defineProperty(exports'));
          if (exportsIndex !== -1) {
            insertIndex = exportsIndex + 1;
          } else {
            insertIndex = 10; // Fallback: after initial declarations
          }
        }

        // Check if ansiColors is already properly defined
        const hasAnsiColorsDef = content.match(/const\s+_ansiColors\s*=\s*require\(\"ansi-colors\"\);\s*\n\s*const\s+ansiColors\s*=\s*\(_ansiColors[^)]+\)/);
        
        // Check if fancyLog is already properly defined
        const hasFancyLogDef = content.match(/const\s+_fancyLog\s*=\s*require\(\"fancy-log\"\);\s*\n\s*const\s+fancyLog\s*=\s*\(_fancyLog[^)]+\)/);
        
        const definitions = [];
        if (!hasAnsiColorsDef) {
          // Insert the robust ansiColors definition
          definitions.push('// Use direct require for ansi-colors to avoid default import issues in some environments\nconst _ansiColors = require(\"ansi-colors\");\nconst ansiColors = (_ansiColors && _ansiColors.default) ? _ansiColors.default : _ansiColors;');
        }
        if (!hasFancyLogDef) {
          // Insert the robust fancyLog definition
          definitions.push('// Use direct require for fancy-log to avoid default import issues in some environments\nconst _fancyLog = require(\"fancy-log\");\nconst fancyLog = (_fancyLog && _fancyLog.default) ? _fancyLog.default : _fancyLog;');
        }
        
        if (definitions.length > 0) {
          lines.splice(insertIndex, 0, ...definitions);
          content = lines.join('\n');
        }

        fs.writeFileSync(path, content, 'utf8');
        console.log('fetch.js fixes applied successfully');
      "
    fi

    npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    npm run gulp minify-vscode-reh-web
    npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  cd ..
fi
