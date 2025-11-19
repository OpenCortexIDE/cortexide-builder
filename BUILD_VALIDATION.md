# Build Process Validation for VS Code 1.106+

## Build Order Summary

The build process has been validated and fixed for VS Code 1.106+. Here's the complete build sequence:

### 1. Pre-Build Phase (`build.sh`)
- ✅ Dependency checks (node, npm, jq, git, Node.js >= 20)
- ✅ Platform-specific tool checks (clang++, gcc, g++, make)
- ✅ Environment variable validation (OS_NAME, VSCODE_ARCH, CI_BUILD)

### 2. Preparation Phase (`prepare_vscode.sh`)
- ✅ Update settings (with error handling for missing files)
- ✅ Apply patches (with non-critical patch handling)
- ✅ Install npm dependencies (with retries and verification)
- ✅ Install extension dependencies (all extensions in extensions/ directory)
- ✅ Fix ESM compatibility in `@vscode/gulp-electron` (permanent fix for @electron/get, @octokit/rest, got)

### 3. Build Phase (`build.sh`)

#### 3.1 React Build
- ✅ Verify `cross-spawn` dependency
- ✅ Run `npm run buildreact`

#### 3.2 **CRITICAL: Webpack ES Module Fix (BEFORE Compilation)**
- ✅ Patch TypeScript source (`build/lib/extensions.ts`) BEFORE compilation:
  - Make `fromLocalWebpack` function async
  - Add `pathToFileURL` imports
  - Replace `require(webpackConfigPath).default` with dynamic `import()`
  - Replace `webpackRootConfig` require with dynamic import
  - Convert `flatMap` to `map` with `Promise.all`
- ✅ Verify `ternary-stream` dependency
- ✅ Run `npm run gulp compile-build-without-mangling`
- ✅ Verify/fallback patch on compiled JavaScript (in case TS patch didn't work)

#### 3.3 Extension Compilation
- ✅ Run `npm run gulp compile-extension-media`
- ✅ Run `npm run gulp compile-extensions-build`
- ✅ Re-apply webpack patch if file was regenerated

#### 3.4 Minification
- ✅ Fix CSS paths in `out-build` directory
- ✅ Run `npm run gulp minify-vscode`

#### 3.5 Platform-Specific Packaging
- ✅ macOS: `npm run gulp vscode-darwin-${VSCODE_ARCH}-min-ci`
- ✅ Windows: `npm run gulp vscode-win32-${VSCODE_ARCH}-min-ci`
- ✅ Linux: `npm run gulp vscode-linux-${VSCODE_ARCH}-min-ci`

#### 3.6 CLI Build
- ✅ Run `../build_cli.sh` for Rust CLI compilation

#### 3.7 REH Builds (if enabled)
- ✅ `npm run gulp minify-vscode-reh`
- ✅ `npm run gulp vscode-reh-${PLATFORM}-${ARCH}-min-ci`
- ✅ `npm run gulp minify-vscode-reh-web`
- ✅ `npm run gulp vscode-reh-web-${PLATFORM}-${ARCH}-min-ci`

### 4. Cleanup Phase
- ✅ Remove all `.bak` backup files created during patching

## Key Fixes for VS Code 1.106+

### 1. Webpack ES Module Loading
**Problem**: Extension webpack configs are ES modules but were being loaded with `require()`
**Solution**: 
- Patch TypeScript source BEFORE compilation to use dynamic `import()` with `pathToFileURL`
- Make functions async to support `await import()`
- Fallback JavaScript patch for verification

### 2. ESM Compatibility in Build Tools
**Problem**: `@vscode/gulp-electron` uses ESM-only modules (`@electron/get`, `@octokit/rest`, `got`) with `require()`
**Solution**: Permanent fix in `prepare_vscode.sh` that converts these to dynamic imports

### 3. Missing Dependencies
**Problem**: `cross-spawn` and `ternary-stream` not always installed
**Solution**: Pre-flight checks and auto-installation before build steps

### 4. Extension Dependencies
**Problem**: Extension dependencies (e.g., `mermaid` for `mermaid-chat-features`) not installed
**Solution**: Auto-install all extension dependencies in `prepare_vscode.sh`

### 5. Patch Compatibility
**Problem**: Some patches failed due to VS Code 1.106 changes
**Solution**: 
- Updated `policies.patch` to remove references to deleted files
- Enhanced `apply_patch` to handle non-critical patches gracefully
- Added compatibility checks for moved files (e.g., `desktop.contribution.ts`)

## Build Process Validation Checklist

- ✅ Pre-build dependency checks
- ✅ Patch application with error handling
- ✅ npm install with retries
- ✅ Extension dependency installation
- ✅ ESM compatibility fixes
- ✅ TypeScript source patching BEFORE compilation
- ✅ React build
- ✅ Build compilation
- ✅ Extension compilation
- ✅ Minification
- ✅ Platform-specific packaging
- ✅ CLI build
- ✅ REH builds (if enabled)
- ✅ Cleanup

## Error Handling

All build steps now have:
- ✅ Detailed error messages
- ✅ Troubleshooting tips
- ✅ Dependency verification
- ✅ Graceful handling of non-critical failures
- ✅ Backup and restore for patching operations

## Compatibility

- ✅ VS Code 1.106+
- ✅ Node.js 20.x+
- ✅ All platforms (macOS, Windows, Linux)
- ✅ All architectures (x64, arm64, etc.)

## Notes

- The build process is now robust and handles edge cases
- TypeScript source patching ensures correct compilation from the start
- JavaScript patching remains as a verification/fallback mechanism
- All temporary files are cleaned up after the build

