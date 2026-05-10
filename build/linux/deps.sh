#!/usr/bin/env bash

set -ex

sudo apt-get update -y

# patch is required by preinstall.ts to apply v8-source-location.patch to Electron headers
sudo apt-get install -y libkrb5-dev patch

if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu crossbuild-essential-arm64
elif [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  sudo apt-get install -y gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf crossbuild-essential-armhf
fi
