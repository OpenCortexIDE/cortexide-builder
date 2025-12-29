#!/usr/bin/env bash

# microsoft/ripgrep-prebuilt doesn't support riscv64.
# Tracking PR: https://github.com/microsoft/ripgrep-prebuilt/pull/41

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_node_modules>"
    exit 1
fi

RG_PATH="$1/@vscode/ripgrep/bin/rg"
RG_VERSION="14.1.1-3"

echo "Replacing ripgrep binary with riscv64 one"

# Ensure the directory exists before any operations
mkdir -p "$(dirname "${RG_PATH}")"

# Check if the ripgrep binary exists before trying to remove it
if [[ -f "${RG_PATH}" ]]; then
  echo "Removing existing ripgrep binary at ${RG_PATH}"
  rm -f "${RG_PATH}"
else
  echo "Warning: ripgrep binary not found at ${RG_PATH}, will download directly"
fi

# Download the riscv64 ripgrep binary
echo "Downloading riscv64 ripgrep binary..."
if curl --silent --fail -L "https://github.com/riscv-forks/ripgrep-riscv64-prebuilt/releases/download/${RG_VERSION}/rg" -o "${RG_PATH}"; then
  if [[ -f "${RG_PATH}" ]]; then
    chmod +x "${RG_PATH}"
    echo "Successfully replaced ripgrep binary at ${RG_PATH}"
  else
    echo "Error: Downloaded file does not exist at ${RG_PATH}"
    exit 1
  fi
else
  echo "Error: Failed to download ripgrep binary (curl exit code: $?)"
  exit 1
fi
