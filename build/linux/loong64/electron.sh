#!/usr/bin/env bash

set -ex

# darkyzhou/electron-loong64 only has v34.2.0 available
# This will cause a major version mismatch warning, but is the only available version
export ELECTRON_VERSION="34.2.0"
export VSCODE_ELECTRON_TAG="v${ELECTRON_VERSION}"
