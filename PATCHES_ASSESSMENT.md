# Patches Assessment for CortexIDE 1.106

## Overview
This document assesses which patches from the VSCodium-style builder are still needed for the CortexIDE 1.106 fork.

## Assessment Status: IN PROGRESS
Date: 2025-11-27

## Key Finding
The CortexIDE repository at `../cortexide` already has significant branding and customization built-in via its `product.json` and source code. Many patches that were necessary for VSCodium may no longer be needed or may conflict with existing CortexIDE code.

## Patch Categories

### Category 1: Likely NOT Needed (Already in CortexIDE Source)
These patches modify things that are likely already customized in the CortexIDE fork:

1. **brand.patch** - Changes "VS Code" to "CortexIDE" in UI text
   - Status: LIKELY NOT NEEDED
   - Reason: CortexIDE product.json already has correct branding
   - Action: Test build without this patch first

2. **version-0-release.patch** / **version-1-update.patch**
   - Status: CHECK NEEDED  
   - Reason: CortexIDE has its own versioning (cortexVersion/cortexRelease)
   - Action: Verify version handling works correctly

### Category 2: Still Needed (Infrastructure/Build Changes)
These patches modify build infrastructure that isn't product-specific:

1. **binary-name.patch** - Changes binary from "code" to application name
   - Status: NEEDED
   - Reason: Build system needs to output correct binary name
   - Action: Keep and verify applies cleanly to 1.106

2. **cli.patch** - CLI-related changes
   - Status: NEEDED
   - Reason: CLI naming and behavior
   - Action: Keep and verify

3. **disable-signature-verification.patch**
   - Status: NEEDED
   - Reason: Allows loading non-marketplace extensions
   - Action: Keep and verify

4. **extensions-disable-mangler.patch**
   - Status: NEEDED
   - Reason: Build process customization
   - Action: Keep and verify

### Category 3: Optional (Feature Disabling)
These patches disable Microsoft-specific features:

1. **disable-cloud.patch** - Disables cloud sync features
   - Status: OPTIONAL
   - Reason: May want to keep sync features
   - Action: Decide based on product requirements

2. **feat-announcements.patch**
   - Status: OPTIONAL
   - Reason: CortexIDE may have its own announcements
   - Action: Review and decide

### Category 4: Platform-Specific
These are needed for specific platforms:

1. **linux/*** - Linux-specific patches
   - Status: NEEDED FOR LINUX BUILDS
   - Action: Keep all, verify they apply

2. **windows/*** - Windows-specific patches  
   - Status: NEEDED FOR WINDOWS BUILDS
   - Action: Keep all, verify they apply

3. **osx/*** - macOS-specific patches
   - Status: NEEDED FOR MACOS BUILDS
   - Action: Keep all, verify they apply

### Category 5: Fix Patches (Always Review)
These fix specific bugs or issues:

1. **fix-eol-banner.patch**
2. **fix-node-gyp-env-paths.patch**
3. **fix-remote-libs.patch**
   - Status: REVIEW EACH
   - Reason: May still be needed, may be fixed upstream
   - Action: Test with and without each patch

## Recommended Patch Testing Strategy

### Phase 1: Minimal Patches (Test First)
Start with only critical patches:
- binary-name.patch
- cli.patch  
- Platform-specific patches for your target OS

### Phase 2: Add Infrastructure Patches
If Phase 1 succeeds, add:
- disable-signature-verification.patch
- extensions-disable-mangler.patch

### Phase 3: Add Optional Patches
Based on requirements, add:
- disable-cloud.patch (if you don't want cloud features)
- Custom patches as needed

### Phase 4: Branding Patches (Last)
Only if branding isn't correct after Phases 1-3:
- brand.patch (but verify it doesn't conflict with CortexIDE's existing branding)

## Implementation Plan

1. **Update prepare_vscode.sh** to:
   - Apply patches with error tolerance
   - Log which patches fail (don't abort on all failures)
   - Skip patches that fail due to "already applied" or "file not found"

2. **Test each platform build** with minimal patches first

3. **Document which patches are actually needed** after successful builds

4. **Remove unnecessary patches** from the repo to reduce maintenance burden

## Notes for 1.106 Compatibility

VS Code 1.106 may have structural changes that affect patches:
- File paths may have moved
- Code structure may have changed
- Some issues patches fixed may be resolved upstream

**IMPORTANT**: Don't force-apply all patches blindly. Many may no longer be needed or may conflict with CortexIDE's existing customizations.

## Action Items
- [ ] Test build with minimal patches
- [ ] Document which patches are actually needed
- [ ] Update patch list in prepare_vscode.sh
- [ ] Remove or archive unnecessary patches
- [ ] Create new patches if needed for 1.106-specific issues

