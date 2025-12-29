#!/usr/bin/env bash

set -ex

# Use 37.10.3 as v37.7.0 may not be available in lex-ibm/electron-ppc64le-build-scripts
export ELECTRON_VERSION="37.10.3"
export VSCODE_ELECTRON_TAG="v${ELECTRON_VERSION}"
