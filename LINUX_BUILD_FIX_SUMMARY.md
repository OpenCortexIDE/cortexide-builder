# Linux Build Fix Summary - VS Code 1.106 Migration

## Problem
After migrating to VS Code 1.106, Linux builds were failing while Windows and macOS builds succeeded.

## Root Cause
The Linux build has a **dependencies validation step** that Windows and macOS don't have. This step compares generated dependencies against a reference list in `build/linux/debian/dep-lists.ts`.

VS Code 1.106 introduced new dependencies for the `amd64` architecture:
- `libstdc++6` (multiple versions: >= 4.1.1, 5, 5.2, 6, 9)
- `zlib1g (>= 1:1.2.3.4)`

These dependencies were already present in `armhf` and `arm64` architectures but were missing from the `amd64` reference list.

The build script `dependencies-generator.js` has `FAIL_BUILD_FOR_NEW_DEPENDENCIES = true`, which causes the build to fail when dependencies don't match the reference list.

## Error Details
```
Error: The dependencies list has changed.
Old: [reference list without libstdc++6 and zlib1g]
New: [generated list with libstdc++6 and zlib1g]
    at Object.getDependencies (dependencies-generator.js:91:19)
```

## Fix Applied
Updated `build/linux/debian/dep-lists.ts` and `build/linux/debian/dep-lists.js` to add the missing dependencies to the `amd64` architecture:

```typescript
'amd64': [
  // ... existing dependencies ...
  'libstdc++6 (>= 4.1.1)',
  'libstdc++6 (>= 5)',
  'libstdc++6 (>= 5.2)',
  'libstdc++6 (>= 6)',
  'libstdc++6 (>= 9)',
  // ... existing dependencies ...
  'zlib1g (>= 1:1.2.3.4)'
],
```

## Why Windows/macOS Didn't Fail
- Windows and macOS builds don't have the Linux-specific dependency validation step
- The dependency checking is only done for Debian/RPM package generation
- This is why the builds succeeded on those platforms despite the same VS Code 1.106 base

## Commits
1. **cortexide-builder** (fa104b0): Fixed `get_repo.sh` to remove vscode directory before cloning
2. **cortexide** (2579ddf1ef4): Updated amd64 dependencies for VS Code 1.106

## Files Changed
- `cortexide/build/linux/debian/dep-lists.ts`
- `cortexide/build/linux/debian/dep-lists.js`

## Testing
The Linux CI build should now pass with the updated dependency reference list.
