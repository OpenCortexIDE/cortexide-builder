#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

if [[ "${CI_BUILD}" == "no" ]]; then
  exit 1
fi

# include common functions
. ./utils.sh

mkdir -p assets

tar -xzf ./vscode.tar.gz

cd vscode || { echo "'vscode' dir not found"; exit 1; }

GLIBC_VERSION="2.28"
GLIBCXX_VERSION="3.4.26"
NODE_VERSION="20.18.2"

export VSCODE_NODEJS_URLROOT='/download/release'
export VSCODE_NODEJS_URLSUFFIX=''

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  GLIBC_VERSION="2.17"
  GLIBCXX_VERSION="3.4.22"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-x64"

  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLSUFFIX='-glibc-217'

  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  EXPECTED_GLIBC_VERSION="2.30"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-arm64"

  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
  # Unset VSCODE_SYSROOT_DIR to prevent node-gyp from trying to use cross-compilation
  unset VSCODE_SYSROOT_DIR
elif [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  EXPECTED_GLIBC_VERSION="2.30"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-armhf"

  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
  # Unset VSCODE_SYSROOT_DIR to prevent node-gyp from trying to use cross-compilation
  unset VSCODE_SYSROOT_DIR
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-ppc64le"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20240129-253798'
  export USE_GNUPP2A=1
  export VSCODE_SKIP_SYSROOT=1
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-riscv64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLROOT='/download/release'
  export VSCODE_NODEJS_URLSUFFIX=''
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:beige-devtoolset-loong64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLROOT='/download/release'
  export VSCODE_NODEJS_URLSUFFIX=''
elif [[ "${VSCODE_ARCH}" == "s390x" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-s390x"

  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
  # Unset VSCODE_SYSROOT_DIR to prevent node-gyp from trying to use cross-compilation
  unset VSCODE_SYSROOT_DIR
  # Prevent native module builds during npm install (s390x native modules can't build on x86_64 host)
  export npm_config_build_from_source=false
  export npm_config_ignore_scripts=true
fi

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
# Don't override VSCODE_SYSROOT_PREFIX - let setup-env.sh use the correct defaults

EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION:=GLIBC_VERSION}"
VSCODE_HOST_MOUNT="$( pwd )"

export VSCODE_HOST_MOUNT
export VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME

sed -i "/target/s/\"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\"/\"${NODE_VERSION}\"/" remote/.npmrc

if [[ -d "../patches/linux/reh/" ]]; then
  for file in "../patches/linux/reh/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

# Verify and apply fix-reh-empty-dependencies fix if patch didn't work
if [[ -f "build/gulpfile.reh.js" ]] && ! grep -q "dependenciesSrc.length > 0" build/gulpfile.reh.js 2>/dev/null; then
  echo "Applying fix-reh-empty-dependencies fix to gulpfile.reh.js..."
  node -e "
    const fs = require('fs');
    const path = './build/gulpfile.reh.js';
    let content = fs.readFileSync(path, 'utf8');

    // Check if fix is needed
    if (content.includes('const deps = gulp.src(dependenciesSrc,') && !content.includes('dependenciesSrc.length > 0')) {
      // Add filter to dependenciesSrc
      content = content.replace(
        /const dependenciesSrc = productionDependencies\.map\(d => path\.relative\(REPO_ROOT, d\)\)\.map\(d => \[`\${d}\/\*\*`, `!\${d}\/\*\*\/{test,tests}\/\*\*`, `!\${d}\/.bin\/\*\*`\]\)\.flat\(\);/,
        'const dependenciesSrc = productionDependencies.map(d => path.relative(REPO_ROOT, d)).filter(d => d && d.trim() !== \"\").map(d => [`\${d}/**`, `!\${d}/**/{test,tests}/**`, `!\${d}/.bin/**`]).flat();'
      );

      // Replace gulp.src call with conditional
      content = content.replace(
        /const deps = gulp\.src\(dependenciesSrc, { base: 'remote', dot: true }\)/,
        'const deps = dependenciesSrc.length > 0 ? gulp.src(dependenciesSrc, { base: \'remote\', dot: true }) : gulp.src([\'**\'], { base: \'remote\', dot: true, allowEmpty: true })'
      );

      fs.writeFileSync(path, content, 'utf8');
      console.log('✓ fix-reh-empty-dependencies fix applied successfully');
    } else if (content.includes('dependenciesSrc.length > 0')) {
      console.log('✓ fix-reh-empty-dependencies already applied');
    } else {
      console.log('⚠ fix-reh-empty-dependencies fix not needed (code structure different)');
    }
  " || {
    echo "ERROR: Failed to apply fix-reh-empty-dependencies fix!"
    exit 1
  }

  # Verify fix was applied
  if ! grep -q "dependenciesSrc.length > 0" build/gulpfile.reh.js 2>/dev/null; then
    echo "ERROR: fix-reh-empty-dependencies fix verification failed!"
    echo "This is required for REH builds to prevent 'Invalid glob argument' errors."
    exit 1
  fi
fi

if [[ -d "../patches/linux/reh/${VSCODE_ARCH}/" ]]; then
  for file in "../patches/linux/reh/${VSCODE_ARCH}/"*.patch; do
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

  if [ ! -d "${HOME}/.gyp" ]; then
    mkdir -p "${HOME}/.gyp"
  fi

  echo "${INCLUDES}" > "${HOME}/.gyp/include.gypi"
fi

# For alternative architectures, skip postinstall scripts to avoid unsupported platform errors
BUILD_NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "ppc64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]] || [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  BUILD_NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for build dependencies on ${VSCODE_ARCH}"
fi

mv .npmrc .npmrc.bak
cp ../npmrc .npmrc

# For arm64, armhf, and s390x, ensure VSCODE_SYSROOT_DIR is unset before npm install to prevent node-gyp cross-compilation
if [[ "${VSCODE_ARCH}" == "arm64" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]]; then
  unset VSCODE_SYSROOT_DIR
fi

for i in {1..5}; do # try 5 times
  npm ci --prefix build ${BUILD_NPM_CI_OPTS} && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
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
if [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "ppc64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]] || [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for ${VSCODE_ARCH} (unsupported by some packages)"
fi

# For arm64, armhf, and s390x, ensure VSCODE_SYSROOT_DIR is unset before npm install to prevent node-gyp cross-compilation
if [[ "${VSCODE_ARCH}" == "arm64" ]] || [[ "${VSCODE_ARCH}" == "armhf" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]]; then
  unset VSCODE_SYSROOT_DIR
fi

for i in {1..5}; do # try 5 times
  npm ci ${NPM_CI_OPTS} && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# Install extension dependencies (required for TypeScript compilation)
echo "Installing extension dependencies..."
for ext_dir in extensions/*/; do
  if [[ -f "${ext_dir}package.json" ]] && [[ -f "${ext_dir}package-lock.json" ]]; then
    ext_name=$(basename "$ext_dir")
    echo "Installing deps for ${ext_name}..."
    if (cd "$ext_dir" && npm ci --ignore-scripts); then
      echo "✓ Successfully installed dependencies for ${ext_name}"
    else
      echo "⚠ Warning: Failed to install dependencies for ${ext_name}, continuing..."
    fi
  fi
done

mv .npmrc.bak .npmrc

node build/azure-pipelines/distro/mixin-npm

# Fix gulpfile.reh.js to use VSCODE_NODEJS_SITE for alternative architectures
# This MUST be done AFTER mixin-npm, as mixin-npm may regenerate/modify gulpfile.reh.js
# This ensures Node.js is downloaded from unofficial-builds.nodejs.org for loong64, riscv64, etc.
echo "=========================================="
echo "NODEJS URL FIX CHECK FOR ${VSCODE_ARCH} (AFTER MIXIN-NPM)"
echo "=========================================="
echo "DEBUG: VSCODE_ARCH=${VSCODE_ARCH}"
echo "DEBUG: Checking if gulpfile.reh.js exists: $([ -f "build/gulpfile.reh.js" ] && echo "yes" || echo "no")"
echo "DEBUG: Architecture check - loong64: $([[ "${VSCODE_ARCH}" == "loong64" ]] && echo "yes" || echo "no")"
echo "DEBUG: Architecture check - riscv64: $([[ "${VSCODE_ARCH}" == "riscv64" ]] && echo "yes" || echo "no")"
if [[ -f "build/gulpfile.reh.js" ]] && { [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]]; }; then
  echo "=== Checking if gulpfile.reh.js needs Node.js URL fix for ${VSCODE_ARCH} ==="
  echo "Environment variables: VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}, VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}, VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"
  echo "Checking if gulpfile.reh.js exists and is readable..."
  ls -la build/gulpfile.reh.js || echo "WARNING: gulpfile.reh.js not found!"

  if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
    echo "Applying direct fix to gulpfile.reh.js for Node.js download URL..."
    echo "Current gulpfile.reh.js does not contain VSCODE_NODEJS_SITE check"
    echo "Searching for 'case linux' pattern in gulpfile.reh.js..."
    grep -n "case.*linux" build/gulpfile.reh.js | head -3 || echo "No 'case linux' found"
    echo "Searching for 'nodejs.org' pattern in gulpfile.reh.js..."
    grep -n "nodejs.org" build/gulpfile.reh.js | head -3 || echo "No 'nodejs.org' found"
    # Use a temporary Node.js script file to avoid shell escaping issues
    cat > /tmp/fix-nodejs-url-reh.js << 'NODEJS_SCRIPT'
      const fs = require('fs');
      const path = './build/gulpfile.reh.js';
      let content = fs.readFileSync(path, 'utf8');

      // Check if fix is needed - look for the nodejs function with hardcoded nodejs.org
      console.log('Checking if fix is needed...');
      console.log('  - fetchUrls found:', content.includes('fetchUrls'));
      console.log('  - nodejs.org found:', content.includes('https://nodejs.org'));
      console.log('  - VSCODE_NODEJS_SITE already present:', content.includes('process.env.VSCODE_NODEJS_SITE'));

      if (content.includes('fetchUrls') && content.includes('https://nodejs.org') &&
          !content.includes('process.env.VSCODE_NODEJS_SITE')) {
        console.log('Fix is needed, searching for case linux block...');
        // Find the case 'linux': block - look for the return statement with nodejs.org
        // The code structure is: case 'linux': return (product.nodejsRepository !== 'https://nodejs.org' ? ... : fetchUrls(...))
        // We need to insert the VSCODE_NODEJS_SITE check before the return statement

        // Find case 'linux' block - try both single and double quotes
        let caseLinuxIndex = content.indexOf("case 'linux':");
        if (caseLinuxIndex === -1) {
          caseLinuxIndex = content.indexOf('case "linux":');
        }

        // Also try with whitespace variations
        if (caseLinuxIndex === -1) {
          const caseLinuxRegex = /case\s+['"]linux['"]\s*:/;
          const match = content.match(caseLinuxRegex);
          if (match) {
            caseLinuxIndex = content.indexOf(match[0]);
          }
        }

        if (caseLinuxIndex === -1) {
          console.log('⚠ Could not find case "linux" block');
          console.log('Showing lines around potential case statements:');
          const lines = content.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].includes('case') && lines[i].includes('linux')) {
              console.log(`Line ${i + 1}: ${lines[i]}`);
            }
          }
          process.exit(1);
        }

        console.log(`Found case linux at index ${caseLinuxIndex}`);

        // Find the return statement after case 'linux'
        // Look for: return (product.nodejsRepository !== 'https://nodejs.org' ? ... : fetchUrls(...))
        const afterCase = content.substring(caseLinuxIndex);

        // Try to find the return statement - it might be on the same line or next lines
        // Look for the pattern: return (product.nodejsRepository !== 'https://nodejs.org'
        console.log('Searching for return statement with nodejs.org...');
        const returnPattern = /return\s*\(product\.nodejsRepository\s*!==\s*['"]https:\/\/nodejs\.org['"]/;
        const returnMatch = afterCase.match(returnPattern);

        if (!returnMatch) {
          console.log('⚠ Could not find return statement with nodejs.org in case linux block');
          console.log('Showing first 1000 chars after case linux:');
          console.log(afterCase.substring(0, 1000));
          process.exit(1);
        }

        console.log(`Found return statement at index ${returnMatch.index} within case linux block`);

        // Find the end of the return statement - it ends with .pipe(rename('node'))
        const returnStartIndex = caseLinuxIndex + returnMatch.index;
        const returnStartText = returnMatch[0];

        // Find where the return statement ends - look for .pipe(rename('node')) or .pipe(rename("node"))
        const afterReturnStart = content.substring(returnStartIndex);
        const renamePattern = /\.pipe\(rename\(['"]node['"]\)\)/;
        const renameMatch = afterReturnStart.match(renamePattern);

        if (!renameMatch) {
          console.log('⚠ Could not find end of return statement (.pipe(rename))');
          process.exit(1);
        }

        const returnEndIndex = returnStartIndex + renameMatch.index + renameMatch[0].length;
        const fullReturnStatement = content.substring(returnStartIndex, returnEndIndex);

        // Insert the VSCODE_NODEJS_SITE check before the return statement
        const newCode = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			${fullReturnStatement}`;

        content = content.substring(0, returnStartIndex) + newCode + content.substring(returnEndIndex);
        fs.writeFileSync(path, content, 'utf8');
        console.log('✓ gulpfile.reh.js Node.js URL fix applied successfully');
      } else if (content.includes('process.env.VSCODE_NODEJS_SITE')) {
        console.log('✓ gulpfile.reh.js Node.js URL fix already applied');
      } else {
        console.log('⚠ gulpfile.reh.js Node.js URL fix not needed (code structure different)');
        process.exit(1);
      }
NODEJS_SCRIPT

    node /tmp/fix-nodejs-url-reh.js || {
      echo "ERROR: Failed to apply gulpfile.reh.js Node.js URL fix!"
      echo "This is required for alternative architectures (loong64, riscv64)"
      rm -f /tmp/fix-nodejs-url-reh.js
      exit 1
    }
    rm -f /tmp/fix-nodejs-url-reh.js

    # Verify fix was applied
    if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: gulpfile.reh.js Node.js URL fix verification failed!"
      echo "This is required for alternative architectures (loong64, riscv64)"
      echo "The fix script may not have matched the code structure correctly"
      echo "Showing first 50 lines of gulpfile.reh.js around 'case linux':"
      grep -n "case.*linux" build/gulpfile.reh.js | head -5 || echo "No 'case linux' found"
      exit 1
    fi
    echo "✓ Verified gulpfile.reh.js Node.js URL fix is applied"
    echo "Showing the fix in gulpfile.reh.js:"
    grep -A 5 "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js | head -10 || echo "Fix not found in grep output"
  else
    echo "✓ gulpfile.reh.js Node.js URL fix already applied"
    echo "Showing the existing fix in gulpfile.reh.js:"
    grep -A 5 "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js | head -10 || echo "Fix not found in grep output"
  fi
  echo "=== End of Node.js URL fix check ==="
else
  echo "Skipping Node.js URL fix check (not loong64 or riscv64, or gulpfile.reh.js not found)"
  echo "VSCODE_ARCH=${VSCODE_ARCH}"
  echo "gulpfile.reh.js exists: $([ -f "build/gulpfile.reh.js" ] && echo "yes" || echo "no")"
fi
echo "=========================================="

export VSCODE_NODE_GLIBC="-glibc-${GLIBC_VERSION}"

# Ensure environment variables are exported for gulp tasks
# This is critical for alternative architectures that need unofficial Node.js builds
if [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  export VSCODE_NODEJS_SITE="${VSCODE_NODEJS_SITE:-https://unofficial-builds.nodejs.org}"
  export VSCODE_NODEJS_URLROOT="${VSCODE_NODEJS_URLROOT:-/download/release}"
  export VSCODE_NODEJS_URLSUFFIX="${VSCODE_NODEJS_URLSUFFIX:-}"
  echo "DEBUG: Re-exporting Node.js environment variables for gulp tasks:"
  echo "  VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}"
  echo "  VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}"
  echo "  VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"
fi

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  # Skip REH build for s390x if the gulp task doesn't exist
  if [[ "${VSCODE_ARCH}" == "s390x" ]]; then
    echo "Skipping REH build for s390x (gulp task not available)"
  else
    echo "Building REH"
    # Compile extensions before minifying (extensions need their dependencies installed)
    echo "Compiling extensions for REH..."
    npm run gulp compile-extensions-build || echo "Warning: Extension compilation failed, continuing..."
    npm run gulp minify-vscode-reh

    # Fix fetch.js import issues that prevent REH builds
    if [[ -f "build/lib/fetch.js" ]]; then
      echo "Applying direct fix to fetch.js for REH compatibility..."
      node -e "
        const fs = require('fs');
        const path = './build/lib/fetch.js';
        let content = fs.readFileSync(path, 'utf8');
        content = content.replace(
          /return event_stream_1\.default\.readArray\(urls\)\.pipe\(event_stream_1\.default\.map\(/g,
          '// Use a classic CommonJS require for \`event-stream\` to avoid cases where the\n    // transpiled default import does not expose \`readArray\` in some environments.\n    // This mirrors how other build scripts (e.g. \`gulpfile.reh.js\`) consume it.\n    const es = require(\"event-stream\");\n    return es.readArray(urls).pipe(es.map('
        );
        content = content.replace(
          /const ansi_colors_1 = __importDefault\(require\(\"ansi-colors\"\)\);/g,
          '// Use direct require for ansi-colors to avoid default import issues in some environments\nconst ansiColors = require(\"ansi-colors\");'
        );
        content = content.replace(/ansi_colors_1\.default/g, 'ansiColors');
        fs.writeFileSync(path, content, 'utf8');
        console.log('fetch.js fixes applied successfully');
      "
    fi

    # Re-export environment variables right before gulp task to ensure they're available
    if [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
      export VSCODE_NODEJS_SITE="${VSCODE_NODEJS_SITE:-https://unofficial-builds.nodejs.org}"
      export VSCODE_NODEJS_URLROOT="${VSCODE_NODEJS_URLROOT:-/download/release}"
      export VSCODE_NODEJS_URLSUFFIX="${VSCODE_NODEJS_URLSUFFIX:-}"
      echo "DEBUG: Environment variables before gulp task:"
      echo "  VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}"
      echo "  VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}"
      echo "  VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"
      # Pass environment variables explicitly to npm/gulp to ensure they're available
      VSCODE_NODEJS_SITE="${VSCODE_NODEJS_SITE}" \
      VSCODE_NODEJS_URLROOT="${VSCODE_NODEJS_URLROOT}" \
      VSCODE_NODEJS_URLSUFFIX="${VSCODE_NODEJS_URLSUFFIX}" \
      npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
    else
      npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
    fi
  fi

  # Only verify glibc and archive if REH was actually built (directory exists)
  if [[ -d "../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ]]; then
    EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

    pushd "../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

    if [[ -f "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" ]]; then
      bash "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" "node_modules"
    fi

    echo "Archiving REH"
    tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

    popd
  else
    echo "Skipping REH verification and archiving (REH build was skipped or failed)"
  fi
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  # Skip REH-web build for s390x if the gulp task doesn't exist
  # Use case-insensitive comparison to handle S390X vs s390x
  echo "DEBUG: Checking REH-web build for VSCODE_ARCH=${VSCODE_ARCH}, lowercased=${VSCODE_ARCH,,}"
  if [[ "${VSCODE_ARCH,,}" == "s390x" ]]; then
    echo "Skipping REH-web build for s390x (gulp task not available)"
    echo "VSCODE_ARCH=${VSCODE_ARCH} detected as s390x, skipping REH-web build"
  else
    echo "Building REH-web for ${VSCODE_ARCH}"
    # Compile extensions before minifying (extensions need their dependencies installed)
    echo "Compiling extensions for REH-web..."
    npm run gulp compile-extensions-build || echo "Warning: Extension compilation failed, continuing..."
    npm run gulp minify-vscode-reh-web
    npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  # Only verify glibc and archive if REH-web was actually built (directory exists)
  if [[ -d "../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ]]; then
    EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

    pushd "../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

    if [[ -f "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" ]]; then
      bash "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" "node_modules"
    fi

    echo "Archiving REH-web"
    tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

    popd
  else
    echo "Skipping REH-web verification and archiving (REH-web build was skipped or failed)"
  fi
fi

cd ..

npm install -g checksum

sum_file() {
  if [[ -f "${1}" ]]; then
    echo "Calculating checksum for ${1}"
    checksum -a sha256 "${1}" > "${1}".sha256
    checksum "${1}" > "${1}".sha1
  fi
}

cd assets

for FILE in *; do
  if [[ -f "${FILE}" ]]; then
    sum_file "${FILE}"
  fi
done

cd ..
