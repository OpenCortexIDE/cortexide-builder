#!/usr/bin/env bash
# Test script to verify TypeScript fix patterns

set -e

TEST_FILE="test_cortexideCommandBarService.ts"

# Create a test file based on the patch structure
cat > "${TEST_FILE}" << 'EOF'
	private readonly _onDidChangeCommandBar = this._register(new Emitter<void>());

	private mountVoidCommandBar: Promise<
		(rootElement: any, accessor: any, props: any) => { rerender: (props2: any) => void; dispose: () => void; } | undefined
	> | undefined;
EOF

echo "=== Testing TypeScript Fix Patterns ==="
echo ""
echo "Original file content:"
cat "${TEST_FILE}"
echo ""

# Test Fix 1: Property type declaration
echo "Testing Fix 1: Property type declaration..."
if perl -i.test -0pe 's/(\t\t)\(rootElement: any, accessor: any, props: any\) => \{ rerender: \(props2: any\) => void; dispose: \(\) => void; \} \| undefined/$1((rootElement: any, accessor: any, props: any) => { rerender: (props2: any) => void; dispose: () => void; } | undefined) | (() => void)/s' "${TEST_FILE}" 2>&1; then
  echo "✓ Fix 1 applied successfully"
  echo "Modified content:"
  cat "${TEST_FILE}"
else
  echo "✗ Fix 1 failed"
fi

# Restore and test Fix 3
cat > "${TEST_FILE}" << 'EOF'
		if (!this.shouldShowCommandBar()) {
			return;
		}

		mountVoidCommandBar(rootElement, accessor, props);
	}
EOF

echo ""
echo "Testing Fix 3: Function call..."
if perl -i.test2 -0pe 's/(\t+)mountVoidCommandBar\(rootElement, accessor, props\);/$1if (this.mountVoidCommandBar) {\n$1\t(await this.mountVoidCommandBar)(rootElement, accessor, props);\n$1}/' "${TEST_FILE}" 2>&1; then
  echo "✓ Fix 3 applied successfully"
  echo "Modified content:"
  cat "${TEST_FILE}"
else
  echo "✗ Fix 3 failed"
fi

# Cleanup
rm -f "${TEST_FILE}" "${TEST_FILE}.test" "${TEST_FILE}.test2"
echo ""
echo "=== Test Complete ==="

