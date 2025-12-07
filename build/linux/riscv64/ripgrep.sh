#!/usr/bin/env bash

# microsoft/ripgrep-prebuilt doesn't support riscv64.
# Tracking PR: https://github.com/microsoft/ripgrep-prebuilt/pull/41

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_node_modules>"
    exit 1
fi

RG_PATH="$1/@vscode/ripgrep/bin/rg"
RG_VERSION="14.1.1-3"

echo "Replacing ripgrep binary with riscv64 one"

# Ensure the directory exists
mkdir -p "$(dirname "${RG_PATH}")"

# Remove existing binary if it exists
if [[ -f "${RG_PATH}" ]]; then
  rm "${RG_PATH}"
elif [[ -f "${RG_PATH}.exe" ]]; then
  # Handle Windows-style .exe extension
  rm "${RG_PATH}.exe"
fi

# Download and install the riscv64 ripgrep binary
curl --silent --fail -L https://github.com/riscv-forks/ripgrep-riscv64-prebuilt/releases/download/${RG_VERSION}/rg -o "${RG_PATH}"
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to download riscv64 ripgrep binary"
  exit 1
fi

chmod +x "${RG_PATH}"

# Verify the binary was installed correctly
if [[ ! -f "${RG_PATH}" ]]; then
  echo "ERROR: ripgrep binary was not installed at ${RG_PATH}"
  exit 1
fi

echo "Successfully installed riscv64 ripgrep binary"
