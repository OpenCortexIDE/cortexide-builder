# Build Log Checklist: Verifying macOS Blank Screen Fix

This guide helps you verify from the build logs that the blank screen fix has been applied and the build completed successfully.

## ✅ Critical Success Indicators

### 1. **minify-vscode Task Completes Successfully**
Look for:
```
Minifying VS Code...
[gulp] Starting 'minify-vscode'...
[gulp] Finished 'minify-vscode' after X ms
```
**What to check:**
- ✅ No errors during minification
- ✅ Task completes without exit code 1
- ✅ No "ERROR" or "Failed" messages

**If you see errors:**
- ❌ `Error: minify-vscode failed` → Build will fail, blank screen likely
- ❌ `CSS path issues` → Check out-build directory
- ❌ `Memory issues` → May need to increase NODE_OPTIONS

---

### 2. **workbench.html Verification Step**
Look for:
```
Verifying critical files in macOS app bundle...
✓ Critical files verified in app bundle: ../VSCode-darwin-{arch}/{AppName}.app
```

**What to check:**
- ✅ `✓ Critical files verified in app bundle` message appears
- ✅ No `ERROR: workbench.html is missing` messages
- ✅ No `ERROR: main.js is missing` messages

**If you see errors:**
- ❌ `ERROR: workbench.html is missing from app bundle!` → **BLANK SCREEN WILL OCCUR**
  - Check if it says: `workbench.html exists in out-build but wasn't copied`
  - This indicates a packaging issue
- ❌ `workbench.html is also missing from out-build!` → **BLANK SCREEN WILL OCCUR**
  - The minify-vscode task failed silently
  - Rebuild required

---

### 3. **macOS Package Build Completes**
Look for:
```
Building macOS package for {arch}...
[gulp] Starting 'vscode-darwin-{arch}-min-ci'...
[gulp] Finished 'vscode-darwin-{arch}-min-ci' after X ms
```

**What to check:**
- ✅ Task completes successfully
- ✅ No Electron packaging errors
- ✅ App bundle created at expected location

**If you see errors:**
- ❌ `Error: macOS build failed` → Check for:
  - Electron packaging errors
  - Missing build artifacts
  - Code signing issues
  - Architecture mismatch

---

### 4. **Code Changes Compiled**
The window visibility fixes are in TypeScript files that get compiled. Look for:
```
[tsc] Compiling TypeScript...
[tsc] src/vs/platform/windows/electron-main/windowImpl.ts
```

**What to check:**
- ✅ No TypeScript compilation errors in `windowImpl.ts`
- ✅ File compiles successfully
- ✅ No syntax errors related to the fixes

**If you see errors:**
- ❌ TypeScript errors in `windowImpl.ts` → Fixes may not be applied
- ❌ Import errors → Check file paths

---

## 🔍 Detailed Log Search Patterns

### Search for these SUCCESS patterns:
```bash
# In your build logs, search for:
grep -i "critical files verified" build.log
grep -i "workbench.html" build.log | grep -i "verified\|exists"
grep -i "minify-vscode.*finished\|completed" build.log
grep -i "vscode-darwin.*finished\|completed" build.log
```

### Search for these ERROR patterns:
```bash
# These indicate problems:
grep -i "error.*workbench" build.log
grep -i "missing.*workbench" build.log
grep -i "failed.*minify" build.log
grep -i "blank screen" build.log
```

---

## 📋 Complete Build Log Checklist

Use this checklist when reviewing your build logs:

### Pre-Build Phase
- [ ] Dependencies installed successfully
- [ ] No missing npm packages
- [ ] TypeScript compilation starts

### Build Phase
- [ ] `minify-vscode` task starts
- [ ] `minify-vscode` task completes without errors
- [ ] React build files verified (if applicable)
- [ ] No memory errors during minification

### Packaging Phase
- [ ] `vscode-darwin-{arch}-min-ci` task starts
- [ ] App bundle created successfully
- [ ] **CRITICAL: Verification step runs**
- [ ] **CRITICAL: `✓ Critical files verified` message appears**
- [ ] No errors about missing workbench.html
- [ ] No errors about missing main.js

### Post-Build Phase
- [ ] Build completes with exit code 0
- [ ] App bundle exists at expected location
- [ ] No warnings about blank screen issues

---

## 🚨 Red Flags (Build Will Fail or Blank Screen Will Occur)

If you see ANY of these, the blank screen issue is NOT fixed:

1. **❌ `ERROR: workbench.html is missing from app bundle!`**
   - **Action:** Check if file exists in `out-build/` directory
   - **If yes:** Packaging issue - check gulpfile.vscode.js
   - **If no:** minify-vscode failed - rebuild required

2. **❌ `Error: minify-vscode failed`**
   - **Action:** Check error details above this message
   - **Common causes:** Memory issues, CSS path problems, missing source files

3. **❌ `ERROR: App bundle not found`**
   - **Action:** Check if build task completed
   - **Common causes:** Build task failed, wrong architecture

4. **❌ TypeScript errors in `windowImpl.ts`**
   - **Action:** Fix compilation errors
   - **Impact:** Window visibility fixes won't be applied

5. **❌ `workbench.html is also missing from out-build!`**
   - **Action:** Rebuild from scratch
   - **Impact:** File was never generated

---

## ✅ Success Confirmation

Your build is successful and the blank screen fix is applied if you see:

```
✓ Critical files verified in app bundle: ../VSCode-darwin-{arch}/{AppName}.app
```

**AND** all of these are true:
- ✅ No ERROR messages about workbench.html
- ✅ No ERROR messages about main.js
- ✅ minify-vscode task completed
- ✅ macOS package build completed
- ✅ Build exits with code 0

---

## 🔧 If Verification Fails

If the verification step fails, the build script will:
1. Check if workbench.html exists in `out-build/`
2. If found, attempt to manually copy it to app bundle
3. If not found, exit with error code 1

**Check the logs for:**
- `Attempting to manually copy workbench.html...`
- `✓ Manually copied workbench.html to app bundle` (good!)
- `Failed to copy workbench.html!` (bad - build failed)

---

## 📝 Runtime Verification

Even if the build succeeds, you can verify the fix at runtime by checking Console.app logs:

Look for these messages when the app launches:
- `window#load: Loading workbench from: [URL]`
- `window#ready-to-show: window ready, ensuring visibility on macOS`
- `window#load: did-finish-load event, ensuring window visibility`

If you see errors:
- `window#load: Failed to load workbench` → workbench.html issue
- `window#load: Renderer process crashed` → GPU issue
- `window#load: CRITICAL - Window was never shown` → Window visibility issue

---

## 🎯 Quick Reference

**Minimum required for success:**
```
✓ Critical files verified in app bundle
```

**This means:**
- ✅ workbench.html exists in app bundle
- ✅ main.js exists in app bundle
- ✅ App bundle structure is correct
- ✅ Files are in the right location

**If you see this, the build is good!** 🎉

