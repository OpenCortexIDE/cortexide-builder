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
    if [[ -f "${file}" ]] && [[ "${file}" != *"fix-nodejs-url.patch" ]]; then
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

# Apply Node.js URL fix patch for alternative architectures (loong64, riscv64)
# This MUST be done AFTER mixin-npm, as mixin-npm may regenerate/modify gulpfile.reh.js
# This ensures Node.js is downloaded from unofficial-builds.nodejs.org for loong64, riscv64, etc.
echo "=========================================="
echo "CHECKING NODEJS URL FIX FOR ${VSCODE_ARCH} (AFTER MIXIN-NPM)"
echo "=========================================="
echo "VSCODE_ARCH=${VSCODE_ARCH}"
echo "gulpfile.reh.js exists: $([ -f "build/gulpfile.reh.js" ] && echo "yes" || echo "no")"
echo "Architecture check - loong64: $([[ "${VSCODE_ARCH}" == "loong64" ]] && echo "yes" || echo "no")"
echo "Architecture check - riscv64: $([[ "${VSCODE_ARCH}" == "riscv64" ]] && echo "yes" || echo "no")"

if [[ -f "build/gulpfile.reh.js" ]] && { [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]]; }; then
  echo "=========================================="
  echo "APPLYING NODEJS URL FIX PATCH FOR ${VSCODE_ARCH} (AFTER MIXIN-NPM)"
  echo "=========================================="
  echo "Environment variables: VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}, VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}, VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"

  if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
    echo "Applying Node.js URL fix patch..."
    echo "Checking if patch file exists..."
    if [[ -f "../patches/linux/reh/fix-nodejs-url.patch" ]]; then
      echo "Patch file found, applying..."
      if apply_patch "../patches/linux/reh/fix-nodejs-url.patch"; then
        echo "Patch applied successfully, verifying..."
        # Verify fix was applied
        if grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
          echo "✓ Node.js URL fix patch applied and verified"
          SKIP_NODEJS_SCRIPT=1
        else
          echo "ERROR: Node.js URL fix patch verification failed!"
          echo "This is required for alternative architectures (loong64, riscv64)"
          echo "Will try Node.js script fallback..."
          SKIP_PATCH=1
        fi
      else
        echo "ERROR: Failed to apply Node.js URL fix patch!"
        echo "This is required for alternative architectures (loong64, riscv64)"
        echo "Will try Node.js script fallback..."
        SKIP_PATCH=1
      fi
    else
      echo "ERROR: Node.js URL fix patch not found at ../patches/linux/reh/fix-nodejs-url.patch"
      echo "This is required for alternative architectures (loong64, riscv64)"
      echo "Will use Node.js script approach..."
      SKIP_PATCH=1
    fi
  else
    echo "✓ Node.js URL fix already applied"
    SKIP_NODEJS_SCRIPT=1
  fi

  # Only run Node.js script if patch didn't work
  if [[ "${SKIP_NODEJS_SCRIPT}" != "1" ]]; then
  echo "=========================================="
  echo "NODEJS URL FIX FOR ${VSCODE_ARCH} (AFTER MIXIN-NPM)"
  echo "=========================================="
  echo "Environment variables: VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}, VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}, VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"

  if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
    echo "Applying Node.js URL fix using sed (simple and reliable)..."
    echo "=========================================="
    echo "APPLYING NODE.JS URL FIX FOR ${VSCODE_ARCH}"
    echo "=========================================="
    echo "Current gulpfile.reh.js does not contain VSCODE_NODEJS_SITE check"
    echo "Searching for 'case linux' pattern in gulpfile.reh.js..."
    grep -n "case.*linux" build/gulpfile.reh.js | head -3 || echo "No 'case linux' found"
    echo "Searching for 'nodejs.org' pattern in gulpfile.reh.js..."
    grep -n "nodejs.org" build/gulpfile.reh.js | head -3 || echo "No 'nodejs.org' found"
    echo "Searching for 'fetchUrls' pattern in gulpfile.reh.js..."
    grep -n "fetchUrls" build/gulpfile.reh.js | head -5 || echo "No 'fetchUrls' found"
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
        console.log('Fix is needed, searching for fetchUrls with nodejs.org...');

        // Find case 'linux' block first to limit search scope
        let caseLinuxIndex = content.indexOf("case 'linux':");
        if (caseLinuxIndex === -1) {
          caseLinuxIndex = content.indexOf('case "linux":');
        }
        if (caseLinuxIndex === -1) {
          const caseLinuxRegex = /case\s+['"]linux['"]\s*:/;
          const match = content.match(caseLinuxRegex);
          if (match) {
            caseLinuxIndex = content.indexOf(match[0]);
          }
        }

        if (caseLinuxIndex === -1) {
          console.log('⚠ Could not find case "linux" block');
          process.exit(1);
        }

        console.log(`Found case linux at index ${caseLinuxIndex}`);

        // Find the next case or end of switch to limit search scope
        const afterCaseLinux = content.substring(caseLinuxIndex);
        const nextCaseMatch = afterCaseLinux.match(/case\s+['"]/);
        const searchEndIndex = nextCaseMatch ? caseLinuxIndex + nextCaseMatch.index : content.length;
        const linuxCaseContent = content.substring(caseLinuxIndex, searchEndIndex);

        console.log('Searching for fetchUrls with base: https://nodejs.org in case linux block...');
        console.log('Linux case content length:', linuxCaseContent.length);
        console.log('First 500 chars of case linux:', linuxCaseContent.substring(0, 500));

        // Look for the exact pattern from the patch file:
        // return (product.nodejsRepository !== 'https://nodejs.org' ?
        //     fetchGithub(...) :
        //     fetchUrls(`/dist/v${nodeVersion}/node-v${nodeVersion}-${platform}-${arch}.tar.gz`, { base: 'https://nodejs.org', checksumSha256 })
        // ).pipe(...)
        console.log('Searching for the exact return statement pattern...');

        // Try to find the ternary pattern: return (product.nodejsRepository !== 'https://nodejs.org' ? ... : fetchUrls(...))
        const ternaryPattern = /return\s*\(\s*product\.nodejsRepository\s*!==\s*['"]https:\/\/nodejs\.org['"]\s*\?/;
        let ternaryMatch = linuxCaseContent.match(ternaryPattern);

        if (ternaryMatch) {
          console.log('Found ternary pattern at index', ternaryMatch.index);
          // Find the end of this return statement - it ends with .pipe(rename('node'))
          const ternaryStartIndex = caseLinuxIndex + ternaryMatch.index;
          const afterTernary = content.substring(ternaryStartIndex);
          const renamePattern = /\.pipe\(rename\(['"]node['"]\)\)/;
          const renameMatch = afterTernary.match(renamePattern);

          if (renameMatch) {
            const ternaryEndIndex = ternaryStartIndex + renameMatch.index + renameMatch[0].length;
            const fullReturnStatement = content.substring(ternaryStartIndex, ternaryEndIndex);

            console.log('Found complete return statement, replacing with environment variable check...');

            // Replace with the new structure from the patch
            const newCode = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			if (product.nodejsRepository !== 'https://nodejs.org') {
				return fetchGithub(product.nodejsRepository, { version: \`\${nodeVersion}-\${internalNodeVersion}\`, name: expectedName, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			else {
				return fetchUrls(\`/dist/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}.tar.gz\`, { base: 'https://nodejs.org', checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}`;

            content = content.substring(0, ternaryStartIndex) + newCode + content.substring(ternaryEndIndex);
            fs.writeFileSync(path, content, 'utf8');
            console.log('✓ gulpfile.reh.js Node.js URL fix applied successfully (ternary replacement)');

            // Verify the fix was applied
            const verifyContent = fs.readFileSync(path, 'utf8');
            if (!verifyContent.includes('process.env.VSCODE_NODEJS_SITE')) {
              console.log('ERROR: Fix was applied but verification failed!');
              process.exit(1);
            }
            console.log('✓ Fix verified successfully');
            process.exit(0);
          }
        }

        // Fallback: try to find fetchUrls with base: 'https://nodejs.org'
        console.log('Ternary pattern not found, trying fallback approach...');
        let fetchUrlsMatch = linuxCaseContent.match(/fetchUrls\([^,]+,\s*\{\s*base:\s*['"]https:\/\/nodejs\.org['"]/);
        if (!fetchUrlsMatch) {
          fetchUrlsMatch = linuxCaseContent.match(/fetchUrls\([^)]+base:\s*['"]https:\/\/nodejs\.org['"]/);
        }
        if (!fetchUrlsMatch) {
          fetchUrlsMatch = linuxCaseContent.match(/fetchUrls\([^)]*nodejs\.org[^)]*\)/);
        }

        if (!fetchUrlsMatch) {
          console.log('⚠ Could not find fetchUrls with base: https://nodejs.org');
          console.log('Showing first 2000 chars of case linux block:');
          console.log(linuxCaseContent.substring(0, 2000));
          console.log('ERROR: Could not find any matching pattern in case linux block');
          process.exit(1);
        }

        console.log(`Found fetchUrls call at index ${fetchUrlsMatch.index} within case linux block`);
        const fetchUrlsStartIndex = caseLinuxIndex + fetchUrlsMatch.index;

        // Find the entire fetchUrls call - it ends with .pipe(rename('node'))
        const afterFetchUrls = content.substring(fetchUrlsStartIndex);
        const renamePattern = /\.pipe\(rename\(['"]node['"]\)\)/;
        const renameMatch = afterFetchUrls.match(renamePattern);

        if (!renameMatch) {
          console.log('⚠ Could not find end of fetchUrls call (.pipe(rename))');
          process.exit(1);
        }

        const fetchUrlsEndIndex = fetchUrlsStartIndex + renameMatch.index + renameMatch[0].length;
        const fullFetchUrlsCall = content.substring(fetchUrlsStartIndex, fetchUrlsEndIndex);

        // Find the return statement that contains this fetchUrls call
        // Look backwards from fetchUrlsStartIndex to find the return statement
        let returnStartIndex = fetchUrlsStartIndex;
        let parenDepth = 0;
        let foundReturn = false;

        // Search backwards for 'return' keyword
        for (let i = fetchUrlsStartIndex - 1; i >= Math.max(0, caseLinuxIndex); i--) {
          const char = content.charAt(i);
          if (char === ')') parenDepth++;
          else if (char === '(') parenDepth--;
          else if (content.substring(Math.max(0, i - 6), i + 1) === 'return' && parenDepth === 0) {
            returnStartIndex = i - 6;
            foundReturn = true;
            break;
          }
        }

        if (!foundReturn) {
          console.log('⚠ Could not find return statement before fetchUrls');
          // Try to insert if statement before fetchUrls directly
          const newCode = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			return ${fullFetchUrlsCall}`;
          content = content.substring(0, fetchUrlsStartIndex) + newCode + content.substring(fetchUrlsEndIndex);
        } else {
          // Replace the entire return statement with our check
          const newCode = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			return ${fullFetchUrlsCall}`;
          content = content.substring(0, returnStartIndex) + newCode + content.substring(fetchUrlsEndIndex);
        }

        fs.writeFileSync(path, content, 'utf8');
        console.log('✓ gulpfile.reh.js Node.js URL fix applied successfully');

        // Verify the fix was applied
        const verifyContent = fs.readFileSync(path, 'utf8');
        if (!verifyContent.includes('process.env.VSCODE_NODEJS_SITE')) {
          console.log('ERROR: Fix was applied but verification failed!');
          process.exit(1);
        }
        console.log('✓ Fix verified successfully');
      } else if (content.includes('process.env.VSCODE_NODEJS_SITE')) {
        console.log('✓ gulpfile.reh.js Node.js URL fix already applied');
      } else {
        console.log('⚠ gulpfile.reh.js Node.js URL fix not needed (code structure different)');
        console.log('This might indicate the code structure has changed. Showing relevant code:');
        const lines = content.split('\n');
        for (let i = 0; i < lines.length; i++) {
          if (lines[i].includes('case') && lines[i].includes('linux')) {
            console.log(`Line ${i + 1}: ${lines[i]}`);
            // Show next 20 lines
            for (let j = i + 1; j < Math.min(i + 21, lines.length); j++) {
              console.log(`Line ${j + 1}: ${lines[j]}`);
            }
            break;
          }
        }
        process.exit(1);
      }
NODEJS_SCRIPT

    echo "=========================================="
    echo "RUNNING NODE.JS URL FIX SCRIPT FOR ${VSCODE_ARCH}"
    echo "=========================================="
    echo "Script location: /tmp/fix-nodejs-url-reh.js"
    echo "Checking if script file exists..."
    ls -la /tmp/fix-nodejs-url-reh.js || echo "WARNING: Script file not found!"
    echo "Running fix script now..."
    set +e  # Don't exit on error, we'll handle it
    if node /tmp/fix-nodejs-url-reh.js > /tmp/fix-nodejs-url-reh.log 2>&1; then
      EXIT_CODE=0
    else
      EXIT_CODE=$?
    fi
    set -e  # Re-enable exit on error
    echo "Fix script exit code: ${EXIT_CODE}"
    echo "Fix script output (first 200 lines):"
    head -200 /tmp/fix-nodejs-url-reh.log 2>/dev/null || echo "No log file found or error reading log"
    echo "Fix script output (last 50 lines):"
    tail -50 /tmp/fix-nodejs-url-reh.log 2>/dev/null || echo "No log file found or error reading log"

    if [[ ${EXIT_CODE} -ne 0 ]]; then
      echo "=========================================="
      echo "ERROR: Node.js URL fix script failed!"
      echo "Exit code: ${EXIT_CODE}"
      echo "=========================================="
      echo "This is required for alternative architectures (loong64, riscv64)"
      echo "Showing 'case linux' in gulpfile.reh.js:"
      grep -n "case.*linux" build/gulpfile.reh.js | head -5 || echo "No 'case linux' found"
      if grep -q "case.*linux" build/gulpfile.reh.js; then
        echo "Showing context around 'case linux':"
        grep -A 30 "case.*linux" build/gulpfile.reh.js | head -50 || echo "Could not show context"
      fi
      rm -f /tmp/fix-nodejs-url-reh.js /tmp/fix-nodejs-url-reh.log
      exit 1
    fi
    echo "✓ Node.js URL fix script completed successfully"
    rm -f /tmp/fix-nodejs-url-reh.js /tmp/fix-nodejs-url-reh.log

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
  fi
  fi
  echo "=========================================="
else
  echo "Skipping Node.js URL fix (not loong64 or riscv64, or gulpfile.reh.js not found)"
  echo "VSCODE_ARCH=${VSCODE_ARCH}"
  echo "gulpfile.reh.js exists: $([ -f "build/gulpfile.reh.js" ] && echo "yes" || echo "no")"
fi

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
