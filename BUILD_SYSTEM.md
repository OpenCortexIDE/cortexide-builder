# CortexIDE Build System

## Overview

This is a streamlined, fast, and accurate build system for CortexIDE that works both locally and in CI environments.

## Architecture

### Unified Build Script (`cortexide/scripts/build.sh`)

The core build script that handles:
- React component building
- TypeScript compilation
- Extension compilation
- Build verification

### Platform-Specific Packaging (`cortexide-builder/build/{os}/package.sh`)

Platform-specific scripts that create distribution packages:
- **macOS**: DMG and ZIP
- **Linux**: TAR.GZ, DEB, RPM, AppImage
- **Windows**: ZIP, MSI, EXE

### Builder Wrapper (`cortexide-builder/build-new.sh`)

A thin wrapper that:
- Prepares the source repository
- Applies patches and configuration
- Installs dependencies
- Calls the unified build script
- Packages the application

## Quick Start

### Local Development

```bash
# From cortexide directory
cd /path/to/cortexide

# Build the application
./scripts/build.sh

# Run the application
./scripts/cortex.sh
```

### Full Build and Package

```bash
# From cortexide-builder directory
cd /path/to/cortexide-builder

# Build and package
./build-new.sh
```

## Build Options

### Unified Build Script Options

```bash
./scripts/build.sh [OPTIONS]

Options:
  --skip-react       Skip React component build
  --skip-compile     Skip TypeScript compilation
  --skip-extensions  Skip extension compilation
  --clean            Clean build artifacts before building
  --verbose, -v      Enable verbose output
  --help, -h         Show help message
```

### Builder Script Environment Variables

```bash
# Skip steps
SKIP_SOURCE=yes      # Skip repository preparation
SKIP_PREPARE=yes     # Skip source preparation (patches)
SKIP_INSTALL=yes     # Skip dependency installation
SKIP_BUILD=yes       # Skip application build
SKIP_PACKAGE=yes     # Skip packaging

# Build options
CLEAN_INSTALL=yes    # Force clean npm install
NODE_OPTIONS="..."   # Node.js options (default: --max-old-space-size=8192)
```

## Build Process

1. **Environment Validation**: Checks prerequisites and environment
2. **Repository Preparation**: Copies or clones source repository
3. **Source Preparation**: Applies patches and updates configuration
4. **Dependency Installation**: Installs npm dependencies
5. **Application Build**: 
   - Builds React components
   - Compiles TypeScript
   - Compiles extensions
6. **Build Verification**: Verifies critical build outputs
7. **Packaging**: Creates platform-specific distribution packages

## Caching and Optimization

### Dependency Caching

- `node_modules` are preserved between builds
- Use `CLEAN_INSTALL=yes` to force fresh install

### Build Artifact Caching

- Build outputs are preserved unless `--clean` is used
- Incremental builds are supported

### Performance Tips

1. **Skip unnecessary steps**: Use `--skip-*` flags for faster iteration
2. **Parallel builds**: Build React and TypeScript in parallel (future enhancement)
3. **Incremental builds**: Only rebuild changed components

## Platform-Specific Notes

### macOS

- Requires `hdiutil` for DMG creation
- Code signing and notarization should be configured separately

### Linux

- DEB/RPM creation requires additional setup files
- AppImage creation requires `appimagetool`

### Windows

- MSI creation requires WiX Toolset
- Code signing should be configured separately

## Troubleshooting

### Build Fails

1. Check prerequisites: Node.js 20+, npm, git
2. Verify dependencies: Run `npm install` in cortexide directory
3. Check logs: Use `--verbose` flag for detailed output

### Packaging Fails

1. Verify Electron app exists: Run `npm run electron` first
2. Check platform tools: Ensure platform-specific tools are installed
3. Check permissions: Ensure write permissions in output directory

### Performance Issues

1. Use `--skip-*` flags to skip unnecessary steps
2. Enable build caching (default behavior)
3. Use `--clean` only when necessary

## Migration from Old Build System

The new build system is designed to be a drop-in replacement:

1. **Old**: `./build.sh` → **New**: `./build-new.sh`
2. **Old**: Complex build logic in builder → **New**: Unified build in cortexide
3. **Old**: Many workarounds → **New**: Clean, maintainable code

## Future Enhancements

- [ ] Parallel build execution
- [ ] Advanced caching strategies
- [ ] Build artifact verification
- [ ] Automated testing integration
- [ ] Performance profiling

