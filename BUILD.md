# CortexIDE Builder - Linux Build Guide

## Linux Build Prerequisites

### System Dependencies

Install the following packages on Ubuntu/Debian-based systems:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  libkrb5-dev \
  libnss3-dev \
  libatk-bridge2.0-dev \
  libdrm2 \
  libxkbcommon-dev \
  libxcomposite-dev \
  libxdamage-dev \
  libxrandr-dev \
  libgbm-dev \
  libxss1 \
  libasound2-dev \
  python3 \
  python3-pip \
  git \
  curl \
  wget
```

For cross-compilation (ARM64, ARMHF, etc.), also install:

```bash
# For ARM64
sudo apt-get install -y \
  gcc-aarch64-linux-gnu \
  g++-aarch64-linux-gnu \
  crossbuild-essential-arm64

# For ARMHF
sudo apt-get install -y \
  gcc-arm-linux-gnueabihf \
  g++-arm-linux-gnueabihf \
  crossbuild-essential-armhf
```

### Node.js and Rust

- **Node.js**: v22.15.1 (matches CI)
- **Rust**: Latest stable (installed via rustup)
- **Python**: 3.11+

Install Node.js:
```bash
# Using nvm (recommended)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
nvm install 22.15.1
nvm use 22.15.1

# Or download from nodejs.org
```

Install Rust:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
```

### Memory Requirements

- **Minimum**: 16GB RAM
- **Recommended**: 32GB RAM
- Node.js will use up to 12GB during build (configured via `NODE_OPTIONS`)

## Local Linux Build

### Quick Start

```bash
# Set environment variables
export APP_NAME="CortexIDE"
export BINARY_NAME="cortexide"
export VSCODE_QUALITY="stable"
export CI_BUILD="no"  # For local builds
export SHOULD_BUILD="yes"
export OS_NAME="linux"
export VSCODE_ARCH="x64"  # or "arm64", "armhf", etc.

# Run the build
./build.sh

# Output will be in: ../VSCode-linux-${VSCODE_ARCH}/
# Binary: ../VSCode-linux-${VSCODE_ARCH}/bin/cortexide
```

### Build Process

The Linux build follows these steps:

1. **Source Preparation**: Fetches CortexIDE source code
2. **Dependency Installation**: Installs npm packages
3. **TypeScript Compilation**: Compiles the codebase
4. **React Build**: Builds CortexIDE's React components
5. **Extension Compilation**: Compiles built-in extensions
6. **Minification**: Bundles and minifies the application
7. **Packaging**: Creates Linux binaries and packages

### Architecture-Specific Builds

#### x64 (Intel/AMD 64-bit)
```bash
export VSCODE_ARCH="x64"
./build.sh
```

#### ARM64
```bash
export VSCODE_ARCH="arm64"
# Ensure cross-compilation tools are installed
./build.sh
```

#### ARMHF (32-bit ARM)
```bash
export VSCODE_ARCH="armhf"
# Ensure cross-compilation tools are installed
./build.sh
```

## CI Build Process

The GitHub Actions workflow (`.github/workflows/stable-linux.yml`) uses a two-stage build:

### Stage 1: Compile Job
- Compiles TypeScript and React components once
- Creates a tarball artifact (`vscode.tar.gz`)
- Runs on `ubuntu-22.04`

### Stage 2: Build Jobs (Matrix)
- Downloads the compiled artifact
- Packages for each architecture in parallel
- Uses Docker containers for cross-compilation
- Creates `.deb`, `.rpm`, `.tar.gz`, and optionally `.AppImage` packages

### CI Environment Variables

The workflow automatically sets:
- `CI_BUILD=yes`
- `OS_NAME=linux`
- `VSCODE_PLATFORM=linux`
- `VSCODE_ARCH` (per matrix job: x64, arm64, armhf, etc.)
- `NODE_OPTIONS=--max-old-space-size=12288`

## Building Packages

After a successful build, create distribution packages:

```bash
# Set packaging options
export SHOULD_BUILD_DEB="yes"    # Create .deb package
export SHOULD_BUILD_RPM="yes"    # Create .rpm package
export SHOULD_BUILD_TAR="yes"    # Create .tar.gz archive
export SHOULD_BUILD_APPIMAGE="yes"  # Create AppImage (x64 only)

# Run packaging
./prepare_assets.sh

# Outputs will be in: assets/
# - cortexide-${VERSION}-${ARCH}.deb
# - cortexide-${VERSION}-${ARCH}.rpm
# - cortexide-linux-${ARCH}-${VERSION}.tar.gz
# - cortexide-${VERSION}-${ARCH}.AppImage (if enabled)
```

## Troubleshooting

### Build Fails with "utils.sh not found"

**Issue**: Script can't find `utils.sh`
**Solution**: Ensure you're running scripts from the builder root directory, or the scripts have been updated to use absolute paths (fixed in recent updates).

### Build Fails with "CI_BUILD is no"

**Issue**: Script exits because `CI_BUILD` is set to "no"
**Solution**: For local builds, set `CI_BUILD="no"` and use `./build.sh` instead of `./build/linux/package_bin.sh`. The `package_bin.sh` script is CI-only.

### Out of Memory Errors

**Issue**: Node.js runs out of memory during build
**Solution**: Increase memory limit:
```bash
export NODE_OPTIONS="--max-old-space-size=16384"  # 16GB
# Or for 32GB systems:
export NODE_OPTIONS="--max-old-space-size=24576"  # 24GB
```

### Cross-Compilation Fails

**Issue**: ARM builds fail with linker errors
**Solution**: Ensure cross-compilation toolchain is installed:
```bash
# For ARM64
sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

# For ARMHF
sudo apt-get install -y gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf
```

### Electron Binary Download Fails

**Issue**: Alternative architectures (riscv64, ppc64le, loong64) can't download Electron
**Solution**: These architectures use custom Electron repositories. The build scripts automatically handle this via environment variables:
- `VSCODE_ELECTRON_REPOSITORY`: Custom repository
- `VSCODE_ELECTRON_TAG`: Specific Electron version

### React Build Fails

**Issue**: `npm run buildreact` fails
**Solution**: Clean and rebuild:
```bash
cd vscode
rm -rf src/vs/workbench/contrib/*/browser/react/out
npm run buildreact
```

## Build Scripts Reference

### Main Scripts

- **`build.sh`**: Main build script (for local builds)
- **`build/linux/package_bin.sh`**: CI packaging script (requires `CI_BUILD=yes`)
- **`build/linux/package_reh.sh`**: Remote Extension Host packaging
- **`build/linux/deps.sh`**: Installs system dependencies
- **`prepare_assets.sh`**: Creates distribution packages

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_NAME` | Application name | `CortexIDE` |
| `BINARY_NAME` | Binary executable name | `cortexide` |
| `VSCODE_ARCH` | Target architecture | `x64` |
| `VSCODE_QUALITY` | Build quality | `stable` |
| `CI_BUILD` | CI mode flag | `no` (local) / `yes` (CI) |
| `OS_NAME` | Operating system | `linux` |
| `VSCODE_PLATFORM` | Platform identifier | `linux` |
| `NODE_OPTIONS` | Node.js options | `--max-old-space-size=12288` |

## Testing Your Build

### Quick Test
```bash
# Run the built binary
../VSCode-linux-${VSCODE_ARCH}/bin/cortexide --version

# Or launch the full application
../VSCode-linux-${VSCODE_ARCH}/bin/cortexide
```

### Install and Test .deb Package
```bash
sudo dpkg -i assets/cortexide-${VERSION}-${ARCH}.deb
sudo apt-get install -f  # Fix dependencies if needed
cortexide --version
```

### Install and Test .rpm Package
```bash
sudo rpm -i assets/cortexide-${VERSION}-${ARCH}.rpm
cortexide --version
```

## Known Limitations

- **AppImage**: Only supported for x64 architecture
- **Alternative Architectures**: riscv64, ppc64le, loong64 require custom Electron builds
- **Snap Package**: Currently disabled in CI (commented out in workflow)
- **Local Builds**: Some alternative architectures may not work locally without proper cross-compilation setup

## Next Steps

1. **Test Local Build**: Follow "Quick Start" section
2. **Test CI Build**: Push to GitHub and check Actions
3. **Create Release**: Use `./release.sh` after successful build
4. **Report Issues**: Check build logs and report any problems

## Additional Resources

- **General Build Instructions**: See `BUILD_INSTRUCTIONS.md`
- **Migration Notes**: See `MIGRATION_SUMMARY.md`
- **CI Workflows**: See `.github/workflows/stable-linux.yml`
