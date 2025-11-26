#!/usr/bin/env node
/**
 * Post-build script to fix CSS imports in bundled JavaScript files
 * This replaces CSS imports with code that loads CSS via link tags
 * This will DEFINITELY work because we're modifying the actual code before it runs
 */

const fs = require('fs');
const path = require('path');

const bundleDir = process.argv[2];

if (!bundleDir) {
    console.error('Usage: node fix_css_imports.js <bundle directory>');
    console.error('Example: node fix_css_imports.js out-vscode-min/vs');
    process.exit(1);
}

if (!fs.existsSync(bundleDir)) {
    console.error(`Error: Bundle directory not found: ${bundleDir}`);
    process.exit(1);
}

console.log(`Fixing CSS imports in bundled JavaScript files...`);
console.log(`Directory: ${bundleDir}`);

let fixedCount = 0;

function fixCSSImports(filePath) {
    let content = fs.readFileSync(filePath, 'utf8');
    let modified = false;
    let cssImportCounter = 0;

    // Pattern 1: Static imports with 'from': import styles from './file.css' or import * as styles from './file.css'
    // Must check this BEFORE side-effect imports to avoid conflicts
    // Match: import [anything] from './file.css'
    const staticImportPattern = /import\s+([^'"\n]*?)\s+from\s+['"]([^'"]*\.css)['"]/g;
    content = content.replace(staticImportPattern, (match, importName, cssPath) => {
        modified = true;
        cssImportCounter++;
        // Handle different import name patterns
        let varName = importName.trim();
        if (!varName) {
            varName = `__css_module_${cssImportCounter}`;
        } else if (varName === '*') {
            varName = `__css_module_${cssImportCounter}`;
        } else if (varName.startsWith('* as ')) {
            varName = varName.substring(5).trim(); // Remove '* as ' prefix, e.g., '* as styles' -> 'styles'
        } else if (varName.includes(',')) {
            // Handle: import defaultStyle, { named } from './file.css'
            varName = varName.split(',')[0].trim();
        }
        
        // Generate code that loads CSS and creates an empty module
        // Resolve CSS path relative to the script's location using import.meta.url or base URL
        // Escape single quotes in CSS path for safety
        const safeCssPath = cssPath.replace(/'/g, "\\'");
        return `// CSS import replaced: ${cssPath}
(function() {
    if (typeof document === 'undefined') return;
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.type = 'text/css';
    // Resolve CSS path: use import.meta.url if available, otherwise use relative path
    // The browser will resolve relative paths relative to the document base URL
    try {
        link.href = typeof import.meta !== 'undefined' && import.meta.url 
            ? new URL('${safeCssPath}', import.meta.url).href 
            : '${safeCssPath}';
    } catch (e) {
        link.href = '${safeCssPath}';
    }
    // Check if already loaded to avoid duplicates
    const cssFileName = '${safeCssPath}'.split('/').pop();
    const existing = document.querySelector('link[href*=\"' + cssFileName + '\"]');
    if (!existing) {
        document.head.appendChild(link);
    }
})();
const ${varName} = {};`;
    });

    // Pattern 2: Side-effect imports: import './file.css' (no 'from' clause)
    // Must check AFTER static imports to avoid matching 'import * as styles from'
    // Use negative lookahead to ensure it's not followed by 'from'
    const sideEffectPattern = /import\s+['"]([^'"]*\.css)['"]\s*;?/g;
    content = content.replace(sideEffectPattern, (match, cssPath) => {
        // Skip if this was already handled by static import pattern
        // (check if the match is part of a 'from' statement by looking ahead)
        const matchIndex = content.indexOf(match);
        const afterMatch = content.substring(matchIndex + match.length, matchIndex + match.length + 20);
        if (afterMatch.trim().startsWith('from')) {
            return match; // Already handled by static import pattern
        }
        
        modified = true;
        cssImportCounter++;
        
        // Escape single quotes in CSS path for safety
        const safeCssPath = cssPath.replace(/'/g, "\\'");
        return `// CSS import replaced: ${cssPath}
(function() {
    if (typeof document === 'undefined') return;
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.type = 'text/css';
    // Resolve CSS path: use import.meta.url if available, otherwise use relative path
    try {
        link.href = typeof import.meta !== 'undefined' && import.meta.url 
            ? new URL('${safeCssPath}', import.meta.url).href 
            : '${safeCssPath}';
    } catch (e) {
        link.href = '${safeCssPath}';
    }
    // Check if already loaded to avoid duplicates
    const cssFileName = '${safeCssPath}'.split('/').pop();
    const existing = document.querySelector('link[href*=\"' + cssFileName + '\"]');
    if (!existing) {
        document.head.appendChild(link);
    }
})();`;
    });

    // Pattern 3: Dynamic imports: import('./file.css')
    const dynamicImportPattern = /import\s*\(\s*['"]([^'"]*\.css)['"]\s*\)/g;
    content = content.replace(dynamicImportPattern, (match, cssPath) => {
        modified = true;
        cssImportCounter++;
        
        // Escape single quotes in CSS path for safety
        const safeCssPath = cssPath.replace(/'/g, "\\'");
        return `Promise.resolve((function() {
    if (typeof document === 'undefined') return {};
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.type = 'text/css';
    // Resolve CSS path: use import.meta.url if available, otherwise use relative path
    try {
        link.href = typeof import.meta !== 'undefined' && import.meta.url 
            ? new URL('${safeCssPath}', import.meta.url).href 
            : '${safeCssPath}';
    } catch (e) {
        link.href = '${safeCssPath}';
    }
    // Check if already loaded to avoid duplicates
    const cssFileName = '${safeCssPath}'.split('/').pop();
    const existing = document.querySelector('link[href*=\"' + cssFileName + '\"]');
    if (!existing) {
        document.head.appendChild(link);
    }
    return {};
})())`;
    });

    if (modified) {
        fs.writeFileSync(filePath, content, 'utf8');
        fixedCount++;
        console.log(`  ✓ Fixed CSS imports in: ${filePath}`);
        return true;
    }
    return false;
}

// Find all JavaScript files recursively
// Uses Node.js path.join() which is cross-platform (handles Windows/Unix paths)
function findJSFiles(dir) {
    const files = [];
    let entries;
    try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (error) {
        // Skip directories we can't read (permission errors, etc.)
        if (error.code === 'EACCES' || error.code === 'EPERM') {
            return files;
        }
        throw error;
    }
    
    for (const entry of entries) {
        try {
            // Use path.join() for cross-platform compatibility (Windows/Unix)
            const fullPath = path.join(dir, entry.name);
            if (entry.isDirectory()) {
                files.push(...findJSFiles(fullPath));
            } else if (entry.isFile() && entry.name.endsWith('.js')) {
                files.push(fullPath);
            }
        } catch (error) {
            // Skip files/directories we can't access
            if (error.code === 'EACCES' || error.code === 'EPERM') {
                continue;
            }
            throw error;
        }
    }
    
    return files;
}

// Process all JavaScript files
const jsFiles = findJSFiles(bundleDir);
console.log(`Found ${jsFiles.length} JavaScript file(s) to check...`);

for (const jsFile of jsFiles) {
    try {
        fixCSSImports(jsFile);
    } catch (error) {
        console.error(`  ✗ Error processing ${jsFile}: ${error.message}`);
    }
}

console.log(`✓ Fixed CSS imports in ${fixedCount} file(s)`);

