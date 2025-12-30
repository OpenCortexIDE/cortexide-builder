#!/usr/bin/env bash
# Fix unused imports in Rust CLI files
# This script directly modifies the files to avoid patch application issues
# Should be run from the vscode directory

set -e

# Determine if we're in vscode directory or need to cd
if [[ -d "cli" ]]; then
  CLI_DIR="cli"
elif [[ -d "vscode/cli" ]]; then
  CLI_DIR="vscode/cli"
  cd vscode || exit 1
else
  echo "Error: Could not find cli directory"
  exit 1
fi

# Fix code_server.rs
if [[ -f "${CLI_DIR}/src/tunnels/code_server.rs" ]]; then
  echo "Fixing unused imports in ${CLI_DIR}/src/tunnels/code_server.rs"
  # Check if the problematic import exists (with flexible whitespace matching)
  if grep -q "use crate::.*debug.*info.*log.*spanf.*trace.*warning" "${CLI_DIR}/src/tunnels/code_server.rs" 2>/dev/null; then
    if sed --version >/dev/null 2>&1; then
      # GNU sed - match with flexible whitespace
      sed -i 's/use crate::{debug, info, log, spanf, trace, warning};/use crate::log;/' "${CLI_DIR}/src/tunnels/code_server.rs"
    else
      # BSD sed
      sed -i '' 's/use crate::{debug, info, log, spanf, trace, warning};/use crate::log;/' "${CLI_DIR}/src/tunnels/code_server.rs"
    fi
    # Verify fix was applied
    if grep -q "use crate::{debug, info, log, spanf, trace, warning};" "${CLI_DIR}/src/tunnels/code_server.rs" 2>/dev/null; then
      echo "  ERROR: Fix failed for code_server.rs - import still present!"
      exit 1
    fi
    echo "  ✓ Fixed code_server.rs"
  else
    echo "  ✓ No fix needed for code_server.rs (import not found or already fixed)"
  fi
else
  echo "  WARNING: ${CLI_DIR}/src/tunnels/code_server.rs not found"
fi

# Fix dev_tunnels.rs
if [[ -f "${CLI_DIR}/src/tunnels/dev_tunnels.rs" ]]; then
  echo "Fixing unused imports in ${CLI_DIR}/src/tunnels/dev_tunnels.rs"
  if grep -q "use crate::.*debug.*info.*log.*spanf.*trace.*warning" "${CLI_DIR}/src/tunnels/dev_tunnels.rs" 2>/dev/null; then
    if sed --version >/dev/null 2>&1; then
      sed -i 's/use crate::{debug, info, log, spanf, trace, warning};/use crate::log;/' "${CLI_DIR}/src/tunnels/dev_tunnels.rs"
    else
      sed -i '' 's/use crate::{debug, info, log, spanf, trace, warning};/use crate::log;/' "${CLI_DIR}/src/tunnels/dev_tunnels.rs"
    fi
    # Verify fix was applied
    if grep -q "use crate::{debug, info, log, spanf, trace, warning};" "${CLI_DIR}/src/tunnels/dev_tunnels.rs" 2>/dev/null; then
      echo "  ERROR: Fix failed for dev_tunnels.rs - import still present!"
      exit 1
    fi
    echo "  ✓ Fixed dev_tunnels.rs"
  else
    echo "  ✓ No fix needed for dev_tunnels.rs (import not found or already fixed)"
  fi
else
  echo "  WARNING: ${CLI_DIR}/src/tunnels/dev_tunnels.rs not found"
fi

# Fix update_service.rs
if [[ -f "${CLI_DIR}/src/update_service.rs" ]]; then
  echo "Fixing unused imports in ${CLI_DIR}/src/update_service.rs"
  # Check for the problematic import pattern (debug and spanf need to be removed)
  if grep -q "debug.*log.*options.*spanf" "${CLI_DIR}/src/update_service.rs" 2>/dev/null; then
    if sed --version >/dev/null 2>&1; then
      sed -i 's/debug, log, options, spanf,/log, options,/' "${CLI_DIR}/src/update_service.rs"
    else
      sed -i '' 's/debug, log, options, spanf,/log, options,/' "${CLI_DIR}/src/update_service.rs"
    fi
    # Verify fix was applied
    if grep -q "debug, log, options, spanf," "${CLI_DIR}/src/update_service.rs" 2>/dev/null; then
      echo "  ERROR: Fix failed for update_service.rs - import still present!"
      exit 1
    fi
    echo "  ✓ Fixed update_service.rs"
  else
    echo "  ✓ No fix needed for update_service.rs (import not found or already fixed)"
  fi
else
  echo "  WARNING: ${CLI_DIR}/src/update_service.rs not found"
fi

echo "Rust import fixes applied"

