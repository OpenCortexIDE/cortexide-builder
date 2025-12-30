#!/usr/bin/env bash

# When installing @vscode/ripgrep, it will try to download prebuilt ripgrep binary from https://github.com/microsoft/ripgrep-prebuilt,
# however, loong64 is not a supported architecture and x86 will be picked as fallback, so we need to replace it with a native one.

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_node_modules>"
    exit 1
fi

RG_PATH="$1/@vscode/ripgrep/bin/rg"
RG_VERSION="14.1.1"

echo "Replacing ripgrep binary with loong64 one"

# Ensure the directory exists before any operations
mkdir -p "$(dirname "${RG_PATH}")"

# Check if the ripgrep binary exists before trying to remove it
if [[ -f "${RG_PATH}" ]]; then
  echo "Removing existing ripgrep binary at ${RG_PATH}"
  rm -f "${RG_PATH}"
else
  echo "Warning: ripgrep binary not found at ${RG_PATH}, will download directly"
fi

# Download the loong64 ripgrep binary
echo "Downloading loong64 ripgrep binary..."
if curl --silent --fail -L "https://github.com/darkyzhou/ripgrep-loongarch64-musl/releases/download/${RG_VERSION}/rg" -o "${RG_PATH}"; then
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
