#!/usr/bin/env bash

set -ex

# Use 37.10.3 as v37.7.0 may not be available in riscv-forks/electron-riscv-releases
export ELECTRON_VERSION="37.10.3"
export VSCODE_ELECTRON_TAG="v${ELECTRON_VERSION}.riscv1"
