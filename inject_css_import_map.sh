#!/usr/bin/env bash
# Post-build script to inject CSS import map into workbench.html
# This ensures the import map is present before any module scripts run

set -e

WORKBENCH_HTML="$1"

if [[ -z "$WORKBENCH_HTML" ]]; then
    echo "Usage: $0 <workbench.html path>"
    exit 1
fi

if [[ ! -f "$WORKBENCH_HTML" ]]; then
    echo "Error: workbench.html not found at: $WORKBENCH_HTML"
    exit 1
fi

# Check if import map is already present
if grep -q 'type="importmap"' "$WORKBENCH_HTML"; then
    echo "Import map already present in: $WORKBENCH_HTML"
    exit 0
fi

# Create temporary file with import map
TEMP_IMPORT_MAP=$(mktemp)
cat > "$TEMP_IMPORT_MAP" << 'EOF'
		<script type="importmap" nonce="0c6a828f1297">
			{"imports": {}}
		</script>
EOF

# Insert import map right after <head> tag
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    sed -i '' '/<head>/r '"$TEMP_IMPORT_MAP" "$WORKBENCH_HTML"
else
    # Linux
    sed -i '/<head>/r '"$TEMP_IMPORT_MAP" "$WORKBENCH_HTML"
fi

rm -f "$TEMP_IMPORT_MAP"

echo "✓ Injected CSS import map placeholder into: $WORKBENCH_HTML"

