# Linux Build Fix Summary - VS Code 1.106 Migration

## Overview
After migrating to VS Code 1.106, Linux builds were failing while Windows and macOS builds succeeded. This document tracks all issues found and fixed.

## Issues Fixed

### 1. rimraf Import Error (Fixed in commit 543e52a183f)

**Problem**: TypeScript compilation failing with `TS2349: This expression is not callable`

**Root Cause**: The rimraf 2.x package is CommonJS-only with no default export, but was being imported as ESM module.

**Fix**: Changed from `import * as rimrafModule from 'rimraf'` to `const rimrafModule = require('rimraf')` in `build/lib/util.ts`

### 2. Dependency Validation Failure (Fixed in commit 04472600cf9)

**Problem**: Linux builds have a dependencies validation step that compares generated dependencies against a reference list in `build/linux/debian/dep-lists.ts`.

**Root Cause**: VS Code 1.106 introduced new dependencies for the `amd64` architecture:
- `libstdc++6` (multiple versions: >= 4.1.1, 5, 5.2, 6, 9)
- `zlib1g (>= 1:1.2.3.4)`

These were missing from the amd64 reference list, causing build failure.

**Fix**: Updated `build/linux/debian/dep-lists.ts` to match Electron 37.7.0's actual dependencies.

### 3. Electron Custom Repository Support (Fixed in commit b8fa7f5f67d)

**Problem**:
- Initial implementation (543e52a183f) broke the method chain by inserting code in the middle of a pipe chain
- Caused `SyntaxError: Identifier 'electronOverride' has already been declared`

**Root Cause**: The electronOverride declaration was inserted between the `let result = all` and the `.pipe()` chain, breaking JavaScript syntax.

**Fix**:
- Moved electronOverride declaration BEFORE the `let result` statement
- Used `const` instead of `let` (linter requirement)
- Ensured the method chain remains intact

**Implementation**:
```javascript
// Declare variables first
const electronOverride = {};
if (process.env.VSCODE_ELECTRON_REPOSITORY) {
    electronOverride.repo = process.env.VSCODE_ELECTRON_REPOSITORY;
}
if (process.env.VSCODE_ELECTRON_TAG) {
    electronOverride.tag = process.env.VSCODE_ELECTRON_TAG;
}
const hasElectronOverride = electronOverride.repo || electronOverride.tag;

// Then use in method chain
let result = all
    .pipe(util.skipDirectories())
    .pipe(util.fixWin32DirectoryPermissions())
    .pipe(filter(['**', '!**/.github/**'], { dot: true }))
    .pipe(electron({ ...config, ...(hasElectronOverride ? electronOverride : {}), platform, arch: arch === 'armhf' ? 'arm' : arch, ffmpegChromium: false }))
    .pipe(filter(['**', '!LICENSE', '!version'], { dot: true }));
```

This allows custom Electron repositories to be specified via `VSCODE_ELECTRON_REPOSITORY` and `VSCODE_ELECTRON_TAG` environment variables for alternative architectures (riscv64, ppc64le, loong64).

## Why Windows/macOS Didn't Fail
- Windows and macOS builds don't have the Linux-specific dependency validation step
- The dependency checking is only done for Debian/RPM package generation
- This is why the builds succeeded on those platforms despite the same VS Code 1.106 base

## All Commits
1. **cortexide-builder** (fa104b0): Fixed `get_repo.sh` to remove vscode directory before cloning
2. **cortexide** (543e52a183f): Fixed rimraf import and added initial Electron custom repo support
3. **cortexide** (04472600cf9): Updated amd64 dependencies for VS Code 1.106
4. **cortexide** (b8fa7f5f67d): Fixed electronOverride declaration in gulpfile.vscode.js

## Files Changed
- `cortexide/build/lib/util.ts` - Fixed rimraf import
- `cortexide/build/gulpfile.vscode.js` - Added Electron custom repository support
- `cortexide/build/linux/debian/dep-lists.ts` - Updated dependencies
- `cortexide/build/linux/debian/dep-lists.js` - Updated dependencies (generated)

## Patches Created
- `patches/fix-rimraf-import.patch` - Backup for rimraf fix (applied directly to source)
- `patches/linux/fix-electron-custom-repo.patch` - Backup for Electron repo override (applied directly to source)
- `patches/linux/fix-dependencies-generator.patch` - Enhanced dependency validation error messages

## Testing
The Linux CI build should now pass with all fixes applied. The build will:
1. Compile TypeScript successfully with correct rimraf import
2. Support custom Electron repositories for alternative architectures
3. Pass dependency validation with updated reference lists
