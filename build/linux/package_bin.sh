#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

# include common functions
. ./utils.sh

tar -xzf ./vscode.tar.gz

chown -R root:root vscode

cd vscode || { echo "'vscode' dir not found"; exit 1; }

# CortexIDE-specific: Clean up any stale processes and build artifacts
echo "Cleaning up processes and build artifacts..."
pkill -f "$(pwd)/out/main.js" || true
pkill -f "$(pwd)/out-build/main.js" || true

# Remove React build output to ensure clean state
# Note: React components are rebuilt here even though they may be in the tar.gz
# This ensures consistency across CI environments and handles any platform-specific build requirements
if [[ -d "src/vs/workbench/contrib/void/browser/react/out" ]]; then
  rm -rf src/vs/workbench/contrib/void/browser/react/out
fi
if [[ -d "src/vs/workbench/contrib/cortexide/browser/react/out" ]]; then
  rm -rf src/vs/workbench/contrib/cortexide/browser/react/out
fi

export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
export VSCODE_SYSROOT_PREFIX='-glibc-2.28'
export NODE_OPTIONS="--max-old-space-size=12288"

# Skip sysroot download - CortexIDE doesn't need cross-compilation toolchains
# Standard builds work without sysroot, and it's causing checksum errors
if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  export VSCODE_SKIP_SYSROOT=1
  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "arm64" || "${VSCODE_ARCH}" == "armhf" ]]; then
  export VSCODE_SKIP_SYSROOT=1
  export VSCODE_SKIP_SETUPENV=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20240129-253798'
  export USE_GNUPP2A=1
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_ELECTRON_REPOSITORY='lex-ibm/electron-ppc64le-build-scripts'
  # Check if electron.sh sets a version, otherwise use a known working version
  # The electron.sh script will override VSCODE_ELECTRON_TAG if it exists
  # lex-ibm/electron-ppc64le-build-scripts only has v34.2.0 available
  export VSCODE_ELECTRON_TAG='v34.2.0' # only version available in lex-ibm/electron-ppc64le-build-scripts
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='riscv-forks/electron-riscv-releases'
  # Note: electron.sh will set this to v37.10.3.riscv1 (with .riscv1 suffix)
  export VSCODE_ELECTRON_TAG='v37.10.3.riscv1' # riscv-forks uses .riscv1 suffix
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='darkyzhou/electron-loong64'
  # Check if electron.sh sets a version, otherwise use a known working version
  # The electron.sh script will override VSCODE_ELECTRON_TAG if it exists
  # darkyzhou/electron-loong64 only has v34.2.0 available
  export VSCODE_ELECTRON_TAG='v34.2.0' # only version available in darkyzhou/electron-loong64
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
  # Skip postinstall scripts for unsupported packages on alternative architectures
  export SKIP_POSTINSTALL_SCRIPTS=1
fi

if [[ -f "../build/linux/${VSCODE_ARCH}/electron.sh" ]]; then
  # add newline at the end of the file
  echo "" >> build/checksums/electron.txt

  if [[ -f "../build/linux/${VSCODE_ARCH}/electron.sha256sums" ]]; then
    cat "../build/linux/${VSCODE_ARCH}/electron.sha256sums" >> build/checksums/electron.txt
  fi

  # shellcheck disable=SC1090
  source "../build/linux/${VSCODE_ARCH}/electron.sh"

  TARGET=$( npm config get target )

  # Only fails at different major versions
  # For loong64 and ppc64le, allow v34.x even if target is v37.x since their repositories only have v34.2.0
  if [[ "${ELECTRON_VERSION%%.*}" != "${TARGET%%.*}" ]]; then
    if [[ "${VSCODE_ARCH}" == "loong64" ]] && [[ "${ELECTRON_VERSION%%.*}" == "34" ]] && [[ "${TARGET%%.*}" == "37" ]]; then
      echo "Warning: Using Electron ${ELECTRON_VERSION} for loong64 (target is ${TARGET}) - only v34.2.0 is available in darkyzhou/electron-loong64"
    elif [[ "${VSCODE_ARCH}" == "ppc64le" ]] && [[ "${ELECTRON_VERSION%%.*}" == "34" ]] && [[ "${TARGET%%.*}" == "37" ]]; then
      echo "Warning: Using Electron ${ELECTRON_VERSION} for ppc64le (target is ${TARGET}) - only v34.2.0 is available in lex-ibm/electron-ppc64le-build-scripts"
    else
      # Fail the pipeline if electron target doesn't match what is used.
      echo "Electron ${VSCODE_ARCH} binary version doesn't match target electron version!"
      echo "Releases available at: https://github.com/${VSCODE_ELECTRON_REPOSITORY}/releases"
      exit 1
    fi
  fi

  if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
    # Force version
    replace "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
  fi
fi

if [[ -d "../patches/linux/client/" ]]; then
  for file in "../patches/linux/client/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

if [[ -n "${USE_GNUPP2A}" ]]; then
  INCLUDES=$(cat <<EOF
{
  "target_defaults": {
    "conditions": [
      ["OS=='linux'", {
        'cflags_cc!': [ '-std=gnu++20' ],
        'cflags_cc': [ '-std=gnu++2a' ],
      }]
    ]
  }
}
EOF
)

  if [ ! -d "$HOME/.gyp" ]; then
    mkdir -p "$HOME/.gyp"
  fi

  echo "${INCLUDES}" > "$HOME/.gyp/include.gypi"
fi

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
BUILD_NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  BUILD_NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for build dependencies on ${VSCODE_ARCH}"
fi

for i in {1..5}; do # try 5 times
  npm ci --prefix build ${BUILD_NPM_CI_OPTS} && break
  if [[ $i == 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# Install extension dependencies (same as in main build.sh)
echo "Installing extension dependencies..."
for ext_dir in extensions/*/; do
  if [[ -f "${ext_dir}package.json" ]] && [[ -f "${ext_dir}package-lock.json" ]]; then
    echo "Installing deps for $(basename "$ext_dir")..."
    (cd "$ext_dir" && npm ci --ignore-scripts) || echo "Skipped $(basename "$ext_dir")"
  fi
done

if [[ -z "${VSCODE_SKIP_SETUPENV}" ]]; then
  if [[ -n "${VSCODE_SKIP_SYSROOT}" ]]; then
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
  else
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for ${VSCODE_ARCH} (unsupported by some packages)"
fi

for i in {1..5}; do # try 5 times
  npm ci ${NPM_CI_OPTS} && break
  if [[ $i -eq 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# Apply fixes for alternative architectures after npm install
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  echo "Applying fixes for ${VSCODE_ARCH} architecture support..."
  bash "../build/linux/fix-dependencies-generator.sh" || echo "Warning: Fix script failed, continuing..."
fi

node build/azure-pipelines/distro/mixin-npm

# CortexIDE: Build React components before packaging
echo "Building React components for Linux ${VSCODE_ARCH}..."

# Verify React build dependencies are installed
if [[ ! -d "node_modules/scope-tailwind" ]] || [[ ! -d "node_modules/tsup" ]]; then
  echo "ERROR: React build dependencies missing!"
  echo "  scope-tailwind: $([ -d "node_modules/scope-tailwind" ] && echo "✓" || echo "✗ MISSING")"
  echo "  tsup: $([ -d "node_modules/tsup" ] && echo "✓" || echo "✗ MISSING")"
  echo "This should not happen - npm ci should have installed devDependencies."
  exit 1
fi

# Verify build.js exists
REACT_BUILD_JS="src/vs/workbench/contrib/cortexide/browser/react/build.js"
if [[ ! -f "${REACT_BUILD_JS}" ]]; then
  echo "ERROR: React build.js not found at ${REACT_BUILD_JS}"
  exit 1
fi

# Run React build - fail properly if it errors
npm run buildreact

# Package the Linux application
echo "Packaging Linux ${VSCODE_ARCH} application..."
# Ensure environment variables are exported for Node.js process
export VSCODE_ELECTRON_REPOSITORY
export VSCODE_ELECTRON_TAG

# For alternative architectures, ensure correct Electron versions are used
# This safeguard prevents any override that might happen between initial export and gulp command
if [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  export VSCODE_ELECTRON_TAG='v34.2.0'
  export VSCODE_ELECTRON_REPOSITORY='darkyzhou/electron-loong64'
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  export VSCODE_ELECTRON_TAG='v34.2.0'
  export VSCODE_ELECTRON_REPOSITORY='lex-ibm/electron-ppc64le-build-scripts'
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  # riscv64 uses v37.10.3.riscv1 (note the .riscv1 suffix)
  export VSCODE_ELECTRON_TAG='v37.10.3.riscv1'
  export VSCODE_ELECTRON_REPOSITORY='riscv-forks/electron-riscv-releases'
fi

echo "Environment variables for Electron:"
echo "  VSCODE_ELECTRON_REPOSITORY=${VSCODE_ELECTRON_REPOSITORY}"
echo "  VSCODE_ELECTRON_TAG=${VSCODE_ELECTRON_TAG}"

	# Apply electron-custom-repo patch if it exists
	# This patch allows gulp to use VSCODE_ELECTRON_REPOSITORY and VSCODE_ELECTRON_TAG env vars
	# Only needed for alternative architectures (ppc64le, riscv64, loong64) that use custom Electron builds
	# The patch is idempotent (checks typeof electronOverride === 'undefined'), so it's safe to apply
	if [[ -f "../patches/linux/electron-custom-repo-idempotent.patch" ]] && \
	   { [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]]; }; then
		# Verify the patch is correctly applied - check for the SPECIFIC code structure the patch creates
		# The patch creates: "typeof electronOverride === 'undefined'" check and direct spread
		# We need to verify BOTH: env var reading AND the correct code structure
		if ! grep -q "typeof electronOverride === 'undefined'" build/gulpfile.vscode.js 2>/dev/null || \
		   ! grep -q "process.env.VSCODE_ELECTRON_TAG" build/gulpfile.vscode.js 2>/dev/null || \
		   ! grep -q "{ ...config, ...electronOverride," build/gulpfile.vscode.js 2>/dev/null; then
			echo "Applying electron-custom-repo patch (electronOverride code not found or incorrect structure)..."
			apply_patch "../patches/linux/electron-custom-repo-idempotent.patch" || {
				echo "ERROR: electron-custom-repo patch failed to apply!"
				echo "This is required for alternative architectures (ppc64le, loong64, riscv64)"
				exit 1
			}
			# Verify patch was applied correctly - check for the specific structure
			if ! grep -q "typeof electronOverride === 'undefined'" build/gulpfile.vscode.js 2>/dev/null || \
			   ! grep -q "process.env.VSCODE_ELECTRON_TAG" build/gulpfile.vscode.js 2>/dev/null || \
			   ! grep -q "{ ...config, ...electronOverride," build/gulpfile.vscode.js 2>/dev/null; then
				echo "ERROR: electron-custom-repo patch applied but verification failed!"
				echo "The patch may not match the current gulpfile.vscode.js structure"
				exit 1
			fi
			echo "✓ electron-custom-repo patch applied and verified"
		else
			echo "✓ electron-custom-repo patch already correctly applied"
		fi
	fi

npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
  bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "../VSCode-linux-${VSCODE_ARCH}/resources/app/node_modules"
fi

find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

# Fix Rust unused imports before building CLI
# Note: We're already in the vscode directory (cd vscode at line 17)
if [[ -f "../build/linux/fix-rust-imports.sh" ]]; then
  echo "Applying Rust import fixes..."
  bash "../build/linux/fix-rust-imports.sh"
fi

. ../build_cli.sh

cd ..
