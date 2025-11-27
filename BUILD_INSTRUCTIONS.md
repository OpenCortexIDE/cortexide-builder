# CortexIDE Builder - Build Instructions for 1.106

## Overview
This builder has been updated to work with the CortexIDE 1.106.x fork located at `../cortexide`. It now correctly integrates with the working local development flow.

## Prerequisites

1. **CortexIDE Source**: The main editor codebase must be at `../cortexide` (relative to this builder repo)
2. **Node.js**: v20.18.2 (same as used in CI)
3. **Build Tools**:
   - macOS: Xcode Command Line Tools, Rust
   - Linux: GCC, libkrb5-dev, Rust
   - Windows: Visual Studio Build Tools, Rust
4. **Memory**: At least 16GB RAM recommended (Node will use up to 12GB)

## Quick Start - Local Builds

### Environment Setup
```bash
# Set environment variables for CortexIDE
export APP_NAME="CortexIDE"
export BINARY_NAME="cortexide"
export VSCODE_QUALITY="stable"
export CI_BUILD="no"  # Important: disables CI-specific logic
export SHOULD_BUILD="yes"

# Set architecture (choose one)
export VSCODE_ARCH="x64"     # Intel/AMD 64-bit
# export VSCODE_ARCH="arm64"  # Apple Silicon / ARM 64-bit
```

### macOS Build
```bash
# From the builder repo directory
export OS_NAME="osx"

# Run the build
./build.sh

# Output will be in: ../VSCode-darwin-${VSCODE_ARCH}/
# Application bundle: ../VSCode-darwin-${VSCODE_ARCH}/CortexIDE.app
```

### Linux Build
```bash
# From the builder repo directory  
export OS_NAME="linux"

# Run the build
./build.sh

# Output will be in: ../VSCode-linux-${VSCODE_ARCH}/
# Binary: ../VSCode-linux-${VSCODE_ARCH}/bin/cortexide
```

### Windows Build
```bash
# From the builder repo directory (in Git Bash or WSL)
export OS_NAME="windows"

# Run the build
./build.sh

# Output will be in: ../VSCode-win32-${VSCODE_ARCH}/
# Binary: ../VSCode-win32-${VSCODE_ARCH}/CortexIDE.exe
```

## Build Process Explained

### What the Builder Does

1. **Source Preparation** (`get_repo.sh`):
   - Checks for local `../cortexide` directory
   - If found, copies it to `vscode/` in the builder
   - If not found, clones from GitHub
   - Reads version info from `product.json`

2. **Patching** (`prepare_vscode.sh`):
   - Applies patches from `patches/` directory
   - Handles branding replacements (APP_NAME, BINARY_NAME, etc.)
   - Installs npm dependencies
   - Sets up product configuration

3. **Building** (`build.sh`):
   - **Cleanup**: Kills any running processes, removes stale React builds
   - **React Build**: Runs `npm run buildreact` (CortexIDE's custom UI)
   - **TypeScript Compilation**: Runs `gulp compile-build-without-mangling`
   - **Extension Media**: Compiles extension assets
   - **Extensions**: Compiles built-in extensions
   - **CSS Fixes**: Applies CortexIDE-specific CSS path fixes
   - **Minification**: Bundles and minifies the application
   - **Packaging**: Creates platform-specific packages

4. **Platform Packaging**:
   - macOS: Creates `.app` bundle → DMG
   - Windows: Creates executable → InnoSetup installer
   - Linux: Creates binaries → tar.gz, .deb, .rpm, AppImage

## Key Differences from Vanilla VS Code Build

### Memory Management
- Uses `NODE_OPTIONS="--max-old-space-size=12288"` (12GB)
- Required for CortexIDE's larger codebase with React components

### Cleanup Steps
The builder now includes cleanup steps matching your working local flow:
```bash
# Kill any running editor processes
pkill -f "/path/to/out/main.js" || true

# Remove stale React build artifacts
rm -rf src/vs/workbench/contrib/void/browser/react/out
rm -rf src/vs/workbench/contrib/cortexide/browser/react/out
```

### Build Order
1. Clean up (new in this update)
2. Build React components (`npm run buildreact`)
3. Compile TypeScript (`gulp compile-build-without-mangling`)
4. Compile extension media
5. Compile extensions
6. Fix CSS paths (CortexIDE-specific)
7. Minify and bundle
8. Package for platform

## CI/CD Builds

### GitHub Actions Workflows

The CI builds work differently from local builds:

1. **Check Job**: Determines if a build is needed
2. **Compile Job**: Compiles the TypeScript/React (once)
3. **Build Job**: Packages for each architecture (parallel)

#### Triggering a CI Build

**Manual Dispatch**:
```bash
# Go to GitHub Actions tab
# Select "stable-macos", "stable-linux", or "stable-windows"  
# Click "Run workflow"
# Options:
#   - cortexide_commit: Specific commit to build
#   - cortexide_release: Custom release number
#   - generate_assets: Create downloadable artifacts
```

**Automatic Triggers**:
- Push to `master` branch
- Pull request to `master` branch

### Environment Variables in CI

The workflows automatically set:
- `APP_NAME=CortexIDE`
- `BINARY_NAME=cortexide`
- `VSCODE_QUALITY=stable`
- `CI_BUILD=no` (for compile job) or implicitly true (for package jobs)
- `NODE_OPTIONS=--max-old-space-size=12288`
- Architecture-specific variables per matrix job

## Troubleshooting

### Build Fails with "out of memory"
**Solution**: Increase Node memory limit
```bash
export NODE_OPTIONS="--max-old-space-size=16384"  # 16GB
```

### Patches fail to apply
**Expected**: Some patches may not apply to CortexIDE if the changes are already in the source.

**Check**: Look at `PATCHES_ASSESSMENT.md` for which patches are needed.

**Fix**: The builder will continue with warnings for non-critical patch failures.

### React build fails
**Solution**: Clean and rebuild:
```bash
cd ../cortexide
rm -rf src/vs/workbench/contrib/*/browser/react/out
npm run buildreact
```

### "vscode directory not found"
**Solution**: Ensure you've run `get_repo.sh` first or that `../cortexide` exists:
```bash
./get_repo.sh
```

### Build succeeds but app doesn't run
**Check**:
1. All dependencies installed: `cd vscode && npm ci`
2. React was built: Check for `src/vs/workbench/contrib/cortexide/browser/react/out/`
3. Product branding correct: `cat vscode/product.json | grep -A5 applicationName`

## Advanced Configuration

### Custom Source Location

To use a different CortexIDE source location:
```bash
# Edit get_repo.sh and change:
CORTEXIDE_REPO="../cortexide"
# to your custom path
```

### Skip Patches

To skip specific patches, move them out of the `patches/` directory:
```bash
mkdir patches/disabled
mv patches/some-patch.patch patches/disabled/
```

### Custom Product Configuration

The builder merges `product.json` from the builder repo with the one from CortexIDE:
```bash
# Edit this file to add/override product.json values:
vim product.json
```

## Testing Your Build

### Quick Test
```bash
# macOS
../VSCode-darwin-${VSCODE_ARCH}/CortexIDE.app/Contents/MacOS/Electron

# Linux
../VSCode-linux-${VSCODE_ARCH}/bin/cortexide

# Windows
../VSCode-win32-${VSCODE_ARCH}/CortexIDE.exe
```

### Full Test Suite
```bash
cd ../cortexide
npm test
```

## Creating Installers/Packages

### macOS DMG
```bash
./prepare_assets.sh  # After successful build
# Creates: assets/CortexIDE-darwin-${VSCODE_ARCH}-${VERSION}.dmg
```

### Windows Installer
```bash
./prepare_assets.sh  # After successful build
# Creates: assets/CortexIDESetup-${VSCODE_ARCH}-${VERSION}.exe
```

### Linux Packages
```bash
./prepare_assets.sh  # After successful build
# Creates:
#   assets/cortexide-${VERSION}-${ARCH}.tar.gz
#   assets/cortexide_${VERSION}_${ARCH}.deb
#   assets/cortexide-${VERSION}-${ARCH}.rpm
```

## Directory Structure

```
cortexide-builder/          # This repository
├── .github/workflows/      # CI/CD workflows
├── build/                  # Platform-specific build scripts
│   ├── linux/
│   │   ├── package_bin.sh  # Linux packaging
│   │   └── package_reh.sh  # Remote Extension Host
│   ├── windows/
│   │   └── package.sh      # Windows packaging
│   └── osx/                # macOS-specific configs
├── patches/                # Patches to apply to source
│   ├── *.patch             # Core patches
│   ├── linux/              # Linux-specific
│   ├── windows/            # Windows-specific
│   └── osx/                # macOS-specific
├── build.sh               # Main build script
├── get_repo.sh            # Fetches CortexIDE source
├── prepare_vscode.sh      # Applies patches, sets up
├── utils.sh               # Shared utility functions
├── version.sh             # Version management
└── vscode/                # CortexIDE source (created during build)

../cortexide/              # Main CortexIDE repository
└── (source files)
```

## Next Steps

1. **Test Local Build**: Follow "Quick Start" for your platform
2. **Test CI Build**: Trigger a manual workflow run
3. **Create Release**: Use `./release.sh` after successful build
4. **Update Documentation**: Document any issues you encounter

## Support

For issues with:
- **Builder**: Check `PATCHES_ASSESSMENT.md` and this file
- **CortexIDE Source**: Check the main `../cortexide` repository
- **CI/CD**: Check `.github/workflows/` and GitHub Actions logs

## Changelog - 2025-11-27 Update

### Added
- Cleanup steps (pkill, rm -rf) matching working local flow
- NODE_OPTIONS environment variable (12GB memory limit)
- Better patch tolerance (non-critical patches can fail)
- Comprehensive logging and progress indicators
- Platform-specific build documentation

### Changed
- Updated memory limit from 8GB to 12GB
- Improved error handling in patch application
- Better CI workflow documentation
- Separated compile and package steps in CI

### Fixed
- CSS path fixes for CortexIDE components
- React build integration
- Patch application for 1.106 compatibility
- Source directory handling (uses ../cortexide correctly)

