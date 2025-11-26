# Root Cause: CSS Import MIME Type Errors

## The Problem

When CortexIDE launches, you see errors like:
```
Failed to load module script: Expected a JavaScript-or-Wasm module script but the server responded with a MIME type of "text/css"
```

This causes a blank screen because CSS files can't be loaded as JavaScript modules.

## Root Cause Analysis

### 1. **TypeScript Source Files Have CSS Imports**

VS Code source files (TypeScript) contain CSS import statements:
```typescript
// Example from cortexide.contribution.ts
import './media/cortexide.css'
```

### 2. **esbuild Configuration Doesn't Handle CSS**

The bundler (esbuild) is configured in `vscode/build/lib/optimize.js`:

```javascript
loader: {
    '.ttf': 'file',
    '.svg': 'file',
    '.png': 'file',
    '.sh': 'file',
    // ❌ NO '.css' loader!
}
```

**Key issue:** esbuild has loaders for fonts, images, and shell scripts, but **NOT for CSS files**.

### 3. **What Happens During Build**

1. TypeScript compiles to JavaScript, preserving `import './file.css'` statements
2. esbuild bundles the JavaScript files
3. When esbuild encounters `import './file.css'`:
   - It has no CSS loader configured
   - It doesn't treat CSS as an external package
   - **It leaves the import statement as-is in the output**
4. The bundled JavaScript file contains: `import './file.css'`

### 4. **What Happens at Runtime**

1. Browser loads the JavaScript file as an ES module
2. JavaScript file executes: `import './file.css'`
3. Browser tries to fetch `./file.css` as a JavaScript module
4. Server responds with CSS content (MIME type: `text/css`)
5. Browser rejects it: "Expected JavaScript but got CSS"
6. **Result: Blank screen, CSS never loads**

## Why This Design?

VS Code was originally designed for a different architecture:
- It uses **import maps** to handle CSS imports at runtime
- The original VS Code expects CSS imports to be resolved via import maps in `workbench.html`
- However, the import map approach is fragile and doesn't work reliably in Electron

## The Fix

We use a **build-time transformation** to replace CSS imports with code that injects `<link>` tags:

**Before (broken):**
```javascript
import './file.css'
```

**After (fixed):**
```javascript
// CSS import replaced: ./file.css
(function() {
    if (typeof document === 'undefined') return;
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.type = 'text/css';
    link.href = './file.css';
    document.head.appendChild(link);
})();
```

This works because:
- ✅ No CSS loader needed
- ✅ Works in Electron (no import maps required)
- ✅ CSS loads via standard `<link>` tags
- ✅ No MIME type errors

## Why Not Fix esbuild Configuration?

Adding a CSS loader to esbuild would require:
1. Understanding how VS Code's build system handles CSS
2. Ensuring CSS files are properly extracted/bundled
3. Potentially breaking other parts of the build
4. More complex than the current workaround

The build-time transformation is simpler and more reliable.

## Gatekeeper "Damaged" App Issue

Separate issue: macOS Gatekeeper adds a quarantine attribute to apps downloaded from the internet, even if they're code-signed and notarized. This is a macOS security feature, not a build issue.

**Fix:** Remove quarantine attribute with `xattr -rd com.apple.quarantine` or use the included fix script.

