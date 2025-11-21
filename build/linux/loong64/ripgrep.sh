#!/usr/bin/env bash

# When installing @vscode/ripgrep, it will try to download prebuilt ripgrep binary from https://github.com/microsoft/ripgrep-prebuilt,
# however, loong64 is not a supported architecture and x86 will be picked as fallback, so we need to replace it with a native one.

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_node_modules>"
    exit 1
fi

RG_DIR="$1/@vscode/ripgrep/bin"
RG_PATH="${RG_DIR}/rg"
RG_VERSION="14.1.1"

echo "Replacing ripgrep binary with loong64 one"

mkdir -p "${RG_DIR}" # Ensure directory exists
rm -f "${RG_PATH}" # Remove if exists, ignore if not

if ! curl --silent --fail -L "https://github.com/darkyzhou/ripgrep-loongarch64-musl/releases/download/${RG_VERSION}/rg" -o "${RG_PATH}"; then
    echo "Error: Failed to download loong64 ripgrep binary." >&2
    exit 1
fi

if ! chmod +x "${RG_PATH}"; then
    echo "Error: Failed to make loong64 ripgrep binary executable." >&2
    exit 1
fi
