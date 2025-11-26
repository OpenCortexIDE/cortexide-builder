# How to Build and Release CortexIDE

## 🚀 Quick Start Guide

This guide shows you how to use the new build system to build and release CortexIDE for macOS, Windows, and Linux.

## 📋 Prerequisites

1. **Node.js 20+** installed
2. **Git** installed
3. **GitHub CLI** (`gh`) installed (for releases)
4. **Platform-specific tools**:
   - **macOS**: `hdiutil` (built-in), code signing certificates (for production)
   - **Linux**: `dpkg-deb`, `rpmbuild` (optional, for DEB/RPM)
   - **Windows**: WiX Toolset (optional, for MSI)

## 🏗️ Build Process Overview

The build and release process has 4 main steps:

1. **Build** - Compile the application
2. **Package** - Create distribution packages
3. **Prepare Assets** - Generate checksums and prepare for release
4. **Release** - Upload to GitHub and update version files

## 📦 Step-by-Step: Building Locally

### Option 1: Quick Local Build (Development)

For local development and testing:

```bash
# Navigate to cortexide directory
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide

# Build the application
./scripts/build.sh

# Run the application
./scripts/cortex.sh
```

### Option 2: Full Build with Packaging

For creating distributable packages:

```bash
# Navigate to builder directory
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder

# Set environment variables (optional)
export SKIP_SOURCE=no      # Prepare source (default: no)
export SKIP_PREPARE=no     # Apply patches (default: no)
export SKIP_INSTALL=no     # Install dependencies (default: no)
export SKIP_BUILD=no       # Build application (default: no)
export SKIP_PACKAGE=no     # Package application (default: no)

# Run the build
./build-new.sh
```

This will:
1. Copy cortexide source to `vscode/` directory
2. Apply patches and configuration
3. Install dependencies
4. Build the application
5. Package for your platform

## 🎯 Platform-Specific Builds

### macOS Build

```bash
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder

# Set platform
export OS_NAME=osx
export VSCODE_ARCH=arm64  # or x64

# Build
./build-new.sh

# Package (creates DMG and ZIP)
./build/osx/package.sh
```

**Output:**
- `CortexIDE-{version}-darwin-{arch}.dmg`
- `CortexIDE-{version}-darwin-{arch}.zip`

### Linux Build

```bash
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder

# Set platform
export OS_NAME=linux
export VSCODE_ARCH=x64  # or arm64, armhf, ppc64le, riscv64, loong64

# Build
./build-new.sh

# Package (creates TAR.GZ)
./build/linux/package.sh
```

**Output:**
- `CortexIDE-{version}-linux-{arch}.tar.gz`

### Windows Build

```bash
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder

# Set platform
export OS_NAME=windows
export VSCODE_ARCH=x64  # or arm64

# Build
./build-new.sh

# Package (creates ZIP)
./build/windows/package.sh
```

**Output:**
- `CortexIDE-{version}-win32-{arch}.zip`

## 🚢 Complete Release Process

### Step 1: Prepare Environment

```bash
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder

# Set required environment variables
export APP_NAME="CortexIDE"
export BINARY_NAME="cortexide"
export VSCODE_QUALITY="stable"  # or "insider"
export ASSETS_REPOSITORY="OpenCortexIDE/cortexide-binaries"
export VERSIONS_REPOSITORY="OpenCortexIDE/cortexide-versions"
export GITHUB_TOKEN="your_github_token_here"  # or use RELEASE_GITHUB_TOKEN
```

### Step 2: Build for All Platforms

You'll need to build on each platform (or use CI):

**macOS (ARM64):**
```bash
export OS_NAME=osx
export VSCODE_ARCH=arm64
./build-new.sh
```

**macOS (x64):**
```bash
export OS_NAME=osx
export VSCODE_ARCH=x64
./build-new.sh
```

**Linux (x64):**
```bash
export OS_NAME=linux
export VSCODE_ARCH=x64
./build-new.sh
```

**Windows (x64):**
```bash
export OS_NAME=windows
export VSCODE_ARCH=x64
./build-new.sh
```

### Step 3: Prepare Assets

After building, prepare assets for release:

```bash
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder

# This creates checksums and prepares assets directory
./prepare_assets.sh
```

This will:
- Create checksums (SHA1, SHA256) for all packages
- Prepare assets in `assets/` directory
- Generate build ID

### Step 4: Release to GitHub

Upload packages to GitHub releases:

```bash
# Make sure GITHUB_TOKEN is set
export GITHUB_TOKEN="your_token"

# Release
./release.sh
```

This will:
- Create or update GitHub release
- Upload all packages from `assets/` directory
- Update release notes

### Step 5: Update Version File

Update the version file so CortexIDE knows about the new release:

```bash
./update_version.sh
```

This updates `cortexide-versions` repository with the latest version.

## 🤖 Using GitHub Actions (CI/CD)

The easiest way to build and release is using GitHub Actions:

### Trigger a Build

1. **Manual Trigger:**
   - Go to Actions tab in `cortexide-builder` repository
   - Select workflow (e.g., "stable-macos")
   - Click "Run workflow"
   - Optionally set:
     - `cortexide_commit`: Specific commit to build
     - `cortexide_release`: Custom release number
     - `generate_assets`: Generate assets without deploying

2. **Automatic Trigger:**
   - Push to `main` branch (builds automatically)
   - Create a tag (releases automatically)

### Workflow Steps

The GitHub Actions workflows automatically:
1. Checkout code
2. Setup Node.js, Python, Rust (as needed)
3. Clone CortexIDE repository
4. Build application (`build-new.sh` will be used)
5. Prepare assets
6. Release to GitHub
7. Update version file

## 🔧 Advanced Usage

### Skip Steps for Faster Iteration

```bash
# Skip source preparation (if already done)
SKIP_SOURCE=yes ./build-new.sh

# Skip dependency installation (if node_modules exists)
SKIP_INSTALL=yes ./build-new.sh

# Skip packaging (just build)
SKIP_PACKAGE=yes ./build-new.sh
```

### Clean Build

```bash
# Force clean build
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide
./scripts/build.sh --clean
```

### Incremental Build (Faster)

```bash
# Only rebuilds what changed
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide
./scripts/build.sh  # Automatically detects changes
```

### Build Specific Components

```bash
# Skip React build
./scripts/build.sh --skip-react

# Skip TypeScript compilation
./scripts/build.sh --skip-compile

# Skip extensions
./scripts/build.sh --skip-extensions
```

## 📊 Build Output Locations

### macOS
- **DMG**: `cortexide-builder/CortexIDE-{version}-darwin-{arch}.dmg`
- **ZIP**: `cortexide-builder/CortexIDE-{version}-darwin-{arch}.zip`
- **App**: `cortexide-builder/vscode/.build/electron/CortexIDE.app`

### Linux
- **TAR.GZ**: `cortexide-builder/CortexIDE-{version}-linux-{arch}.tar.gz`
- **Binary**: `cortexide-builder/vscode/.build/electron/cortexide`

### Windows
- **ZIP**: `cortexide-builder/CortexIDE-{version}-win32-{arch}.zip`
- **EXE**: `cortexide-builder/vscode/.build/electron/cortexide.exe`

## 🐛 Troubleshooting

### Build Fails

1. **Check Node.js version:**
   ```bash
   node --version  # Should be 20+
   ```

2. **Install dependencies:**
   ```bash
   cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide
   npm install
   ```

3. **Clean and rebuild:**
   ```bash
   ./scripts/build.sh --clean
   ```

### Packaging Fails

1. **Check Electron app exists:**
   ```bash
   cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide
   npm run electron
   ```

2. **Check platform tools:**
   - macOS: `hdiutil --version`
   - Linux: `tar --version`
   - Windows: `zip --version` or PowerShell

### Release Fails

1. **Check GitHub token:**
   ```bash
   gh auth status
   ```

2. **Check repository access:**
   ```bash
   gh repo view OpenCortexIDE/cortexide-binaries
   ```

3. **Check release exists:**
   ```bash
   gh release view ${RELEASE_VERSION} --repo OpenCortexIDE/cortexide-binaries
   ```

## 📝 Release Checklist

Before releasing:

- [ ] All platforms built successfully
- [ ] Assets prepared (`./prepare_assets.sh`)
- [ ] Checksums generated
- [ ] GitHub token configured
- [ ] Version number correct
- [ ] Release notes updated
- [ ] Tested on target platforms

## 🔗 Related Documentation

- `BUILD_SYSTEM.md` - Detailed build system documentation
- `CHANGELOG_BUILD_SYSTEM.md` - Changes from old system
- `README_NEW_BUILD.md` - New build system overview

## 💡 Tips

1. **Use CI/CD**: GitHub Actions handles most of the complexity
2. **Test locally first**: Build and test before releasing
3. **Incremental builds**: Use `./scripts/build.sh` for faster iteration
4. **Version management**: Let the system handle version numbers automatically
5. **Asset checksums**: Always verify checksums before releasing

## 🎯 Quick Reference

### Simple One-Command Release

```bash
# Build and release for current platform (easiest!)
cd /Users/tajudeentajudeen/CodeBase/cortexide/cortexide-builder
./release-new.sh
```

### Manual Step-by-Step

```bash
# Local development
cd cortexide && ./scripts/build.sh && ./scripts/cortex.sh

# Full build
cd cortexide-builder && ./build-new.sh

# Complete release (build + package + release)
cd cortexide-builder && ./release-new.sh

# Or step by step:
./prepare_assets.sh
./release.sh
./update_version.sh
```

### Platform-Specific Release

```bash
# macOS ARM64
./release-new.sh --platform osx --arch arm64

# Linux x64
./release-new.sh --platform linux --arch x64

# Windows x64
./release-new.sh --platform windows --arch x64
```

---

**Need help?** Check the troubleshooting section or review the detailed documentation in `BUILD_SYSTEM.md`.

