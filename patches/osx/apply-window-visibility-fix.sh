#!/usr/bin/env bash
# Script to apply window visibility fix for macOS blank screen issue
# This is a runtime fix that can be applied during the build process
# This script handles both old and new codebase structures

# Don't use set -e - we want to try all strategies even if one fails
set +e

# Try new file path first (current codebase structure)
WINDOW_TS_FILE_NEW="src/vs/platform/windows/electron-main/windowImpl.ts"
# Fallback to old file path (legacy codebase structure)
WINDOW_TS_FILE_OLD="src/vs/code/electron-main/window.ts"

# Use provided file path or try to find the correct one
WINDOW_TS_FILE="${1:-}"

if [[ -z "${WINDOW_TS_FILE}" ]]; then
  # Auto-detect which file exists
  if [[ -f "${WINDOW_TS_FILE_NEW}" ]]; then
    WINDOW_TS_FILE="${WINDOW_TS_FILE_NEW}"
    echo "Using new codebase structure: ${WINDOW_TS_FILE}" >&2
  elif [[ -f "${WINDOW_TS_FILE_OLD}" ]]; then
    WINDOW_TS_FILE="${WINDOW_TS_FILE_OLD}"
    echo "Using old codebase structure: ${WINDOW_TS_FILE}" >&2
  else
    echo "Error: Could not find window.ts file at either:" >&2
    echo "  ${WINDOW_TS_FILE_NEW}" >&2
    echo "  ${WINDOW_TS_FILE_OLD}" >&2
    exit 1
  fi
fi

if [[ ! -f "${WINDOW_TS_FILE}" ]]; then
  echo "Error: window.ts not found at ${WINDOW_TS_FILE}" >&2
  exit 1
fi

# Check if fix is already applied
if grep -q "Fix for macOS blank screen" "${WINDOW_TS_FILE}"; then
  echo "Window visibility fix already applied to ${WINDOW_TS_FILE}"
  exit 0
fi

echo "Applying window visibility fix to ${WINDOW_TS_FILE}..."

# Detect which codebase structure we're using
if [[ "${WINDOW_TS_FILE}" == *"windowImpl.ts"* ]] || grep -q "this\._win\.loadURL" "${WINDOW_TS_FILE}" 2>/dev/null; then
  # New codebase structure: use this._win
  echo "Detected new codebase structure (windowImpl.ts)" >&2
  FIX_CODE='		// Fix for macOS blank screen: Ensure window is visible and has valid bounds
		if (isMacintosh && this._win) {
			// Force window to be shown if it is not visible
			if (!this._win.isVisible()) {
				this._win.showInactive();
			}
			// Ensure window is not minimized
			if (this._win.isMinimized()) {
				this._win.restore();
			}
			// Validate and fix window bounds if invalid (0x0 or off-screen)
			const bounds = this._win.getBounds();
			if (bounds && (bounds.width === 0 || bounds.height === 0)) {
				// Reset to default size if invalid
				this._win.setSize(1024, 768);
				this._win.center();
			}
			// Ensure window is focused to prevent blank screen
			this._win.focus();
		}
'
  INSERTION_PATTERN="this\._win\.loadURL"
else
  # Old codebase structure: use this.win
  echo "Detected old codebase structure (window.ts)" >&2
  FIX_CODE='		// Fix for macOS blank screen: Ensure window is visible and has valid bounds
		if (isMacintosh && this.win) {
			// Force window to be shown if it is not visible
			if (!this.win.isVisible()) {
				this.win.showInactive();
			}
			// Ensure window is not minimized
			if (this.win.isMinimized()) {
				this.win.restore();
			}
			// Validate and fix window bounds if invalid (0x0 or off-screen)
			const bounds = this.win.getBounds();
			if (bounds && (bounds.width === 0 || bounds.height === 0)) {
				// Reset to default size if invalid
				this.win.setSize(1024, 768);
				this.win.center();
			}
			// Ensure window is focused to prevent blank screen
			this.win.focus();
		}
'
  INSERTION_PATTERN="vscode:windowConfiguration"
fi

# Strategy 1: Use Python for robust matching (preferred)
if command -v python3 >/dev/null 2>&1; then
python3 << PYTHON_SCRIPT
import sys
import re

file_path = sys.argv[1]
fix_code = sys.argv[2]
insertion_pattern = sys.argv[3]

try:
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check if already applied (check for any macOS fix comment)
    if "Fix for macOS blank screen" in content or "macOS: Comprehensive fix for blank screen" in content or "macOS: Ensure window is visible" in content:
        print("Fix already applied")
        sys.exit(0)
    
    # Pattern 1: After loadURL (new structure) or windowConfiguration (old structure)
    if insertion_pattern == "this\\._win\\.loadURL":
        # New structure: Insert after loadURL line, before any existing macOS fix or "Remember that we did load"
        pattern1 = r'(this\._win\.loadURL\([^)]+\);\s*)(\n\s*(?:// (?:macOS|Remember that we did load)|macOS:))'
        if re.search(pattern1, content, re.MULTILINE | re.DOTALL):
            content = re.sub(pattern1, r'\1\n' + fix_code + r'\n\2', content, flags=re.MULTILINE | re.DOTALL)
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(content)
            print("✓ Applied using pattern 1 (new structure: after loadURL)")
            sys.exit(0)
        
        # Fallback: Just after loadURL line
        pattern2 = r'(this\._win\.loadURL\([^)]+\);)(\s*\n)'
        if re.search(pattern2, content):
            content = re.sub(pattern2, r'\1\n' + fix_code + r'\2', content)
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(content)
            print("✓ Applied using pattern 2 (new structure: after loadURL)")
            sys.exit(0)
    else:
        # Old structure: After windowConfiguration send, before return
        pattern1 = r'(this\.win\.webContents\.send\([\'"]vscode:windowConfiguration[\'"],\s*configuration\);\s*\}\s*)(\n\s*return\s+this\.win;)'
        if re.search(pattern1, content, re.MULTILINE | re.DOTALL):
            content = re.sub(pattern1, r'\1\n' + fix_code + r'\2', content, flags=re.MULTILINE | re.DOTALL)
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(content)
            print("✓ Applied using pattern 1 (old structure: after windowConfiguration)")
            sys.exit(0)
        
        # Old structure: Just before return this.win
        pattern2 = r'(\n\s*)(return\s+this\.win;)'
        match = re.search(pattern2, content)
        if match:
            lines = content.split('\n')
            for i in range(len(lines) - 1, -1, -1):
                if 'return this.win' in lines[i]:
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    fix_lines = fix_code.split('\n')
                    fix_with_indent = '\n'.join([' ' * indent + line.lstrip() if line.strip() else '' for line in fix_lines])
                    lines.insert(i, fix_with_indent)
                    content = '\n'.join(lines)
                    with open(file_path, 'w', encoding='utf-8') as f:
                        f.write(content)
                    print("✓ Applied using pattern 2 (old structure: before return)")
                    sys.exit(0)
    
    print("✗ Could not find insertion point", file=sys.stderr)
    print(f"  Looking for pattern: {insertion_pattern}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"✗ Error: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
"${WINDOW_TS_FILE}" "${FIX_CODE}" "${INSERTION_PATTERN}"
  if grep -q "Fix for macOS blank screen" "${WINDOW_TS_FILE}"; then
    echo "✓ Window visibility fix applied successfully (Python strategy)"
    exit 0
  fi
fi

# Strategy 2: Use perl with flexible pattern matching (skip - use Python or sed instead)
# Perl has escaping issues with backticks in bash, so we skip this strategy
# Python (Strategy 1) and sed (Strategy 3) are more reliable
# Strategy 3: Use sed as final fallback
if [[ "${INSERTION_PATTERN}" == "this\._win\.loadURL" ]]; then
  # New structure: Insert after loadURL line
  if grep -q "this._win.loadURL" "${WINDOW_TS_FILE}"; then
    sed -i.bak2 "/this\._win\.loadURL/a\\
${FIX_CODE}
" "${WINDOW_TS_FILE}" 2>/dev/null
    if grep -q "Fix for macOS blank screen" "${WINDOW_TS_FILE}"; then
      echo "✓ Window visibility fix applied successfully (sed fallback - new structure)"
      rm -f "${WINDOW_TS_FILE}.bak2"
      exit 0
    fi
  fi
else
  # Old structure: Insert before return this.win
  if grep -q "return this.win" "${WINDOW_TS_FILE}"; then
    sed -i.bak2 '/return this\.win/i\
'"${FIX_CODE}"'
' "${WINDOW_TS_FILE}" 2>/dev/null
    if grep -q "Fix for macOS blank screen" "${WINDOW_TS_FILE}"; then
      echo "✓ Window visibility fix applied successfully (sed fallback - old structure)"
      rm -f "${WINDOW_TS_FILE}.bak2"
      exit 0
    fi
  fi
fi

# Final verification
if grep -q "Fix for macOS blank screen" "${WINDOW_TS_FILE}"; then
  echo "✓ Window visibility fix applied successfully"
  exit 0
fi

# If we still failed, this is a critical error
echo "✗ CRITICAL: All strategies failed to apply window visibility fix" >&2
echo "  File: ${WINDOW_TS_FILE}" >&2
echo "  This will cause blank screen on macOS!" >&2
echo "  Please check the file structure manually" >&2
echo "" >&2
echo "  Looking for pattern: '${INSERTION_PATTERN}'" >&2
grep -n "${INSERTION_PATTERN}" "${WINDOW_TS_FILE}" | head -5 >&2 || echo "  Pattern not found!" >&2
exit 1
