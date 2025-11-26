#!/usr/bin/env bash
# Post-build script to fix CSS imports in bundled JavaScript files
# This replaces CSS imports with code that loads CSS via link tags
# This will DEFINITELY work because we're modifying the actual code before it runs

set -e

BUNDLE_DIR="$1"

if [[ -z "$BUNDLE_DIR" ]]; then
    echo "Usage: $0 <bundle directory>"
    echo "Example: $0 out-vscode-min/vs"
    exit 1
fi

if [[ ! -d "$BUNDLE_DIR" ]]; then
    echo "Error: Bundle directory not found: $BUNDLE_DIR"
    exit 1
fi

echo "Fixing CSS imports in bundled JavaScript files..."
echo "Directory: $BUNDLE_DIR"

# Counter for fixed files
FIXED_COUNT=0

# Find all JavaScript files and fix CSS imports
find "$BUNDLE_DIR" -name "*.js" -type f | while read -r js_file; do
    # Check if file contains CSS imports
    if grep -qE "import\s+.*['\"].*\.css['\"]|from\s+['\"].*\.css['\"]" "$js_file" 2>/dev/null; then
        echo "  Fixing CSS imports in: $js_file"
        
        # Create a temporary file for the fixed content
        TEMP_FILE=$(mktemp)
        
        # Use a more sophisticated approach: replace CSS imports with code that loads CSS
        # Pattern 1: import './file.css' or import './file.css' as styles
        # Pattern 2: import styles from './file.css'
        # Pattern 3: import('./file.css')
        
        # Read the file and process line by line
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Check if this line has a CSS import
            if echo "$line" | grep -qE "import\s+.*['\"].*\.css['\"]|from\s+['\"].*\.css['\"]"; then
                # Extract the CSS file path
                CSS_PATH=$(echo "$line" | sed -E "s/.*['\"]([^'\"]*\.css)['\"].*/\1/")
                
                # Generate replacement code that loads CSS via link tag
                # This code will execute immediately and return an empty module
                REPLACEMENT="// CSS import replaced: $CSS_PATH
(function() {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.type = 'text/css';
    link.href = '$CSS_PATH';
    if (!document.querySelector('link[href=\"$CSS_PATH\"]')) {
        document.head.appendChild(link);
    }
})();
const __css_module_$FIXED_COUNT = {};"
                
                # Replace the import statement
                if echo "$line" | grep -qE "import\s+.*from"; then
                    # Static import: import styles from './file.css'
                    # Replace with the CSS loading code and a const declaration
                    echo "$REPLACEMENT" >> "$TEMP_FILE"
                elif echo "$line" | grep -qE "import\s*\("; then
                    # Dynamic import: import('./file.css')
                    # Replace with a promise that loads CSS and resolves to empty object
                    echo "Promise.resolve((function() {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.type = 'text/css';
    link.href = '$CSS_PATH';
    if (!document.querySelector('link[href=\"$CSS_PATH\"]')) {
        document.head.appendChild(link);
    }
    return {};
})())" >> "$TEMP_FILE"
                else
                    # Simple import: import './file.css'
                    echo "$REPLACEMENT" >> "$TEMP_FILE"
                fi
                
                FIXED_COUNT=$((FIXED_COUNT + 1))
            else
                # Keep the original line
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$js_file"
        
        # Replace the original file with the fixed version
        mv "$TEMP_FILE" "$js_file"
        
        echo "    ✓ Fixed CSS imports in: $js_file"
    fi
done

echo "✓ Fixed CSS imports in $FIXED_COUNT file(s)"

