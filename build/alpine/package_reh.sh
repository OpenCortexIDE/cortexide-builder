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

export VSCODE_PLATFORM='alpine'
export VSCODE_SKIP_NODE_VERSION_CHECK=1

# For Alpine ARM64, configure Node.js download to use unofficial builds
# The official nodejs.org doesn't have Alpine ARM64 builds, and Docker fallback fails on AMD64 hosts
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
  export VSCODE_NODEJS_URLROOT='/download/release'
  export VSCODE_NODEJS_URLSUFFIX=''
  echo "Configured Alpine ARM64 to use unofficial Node.js builds"
fi

VSCODE_HOST_MOUNT="$( pwd )"
VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:alpine-${VSCODE_ARCH}"

export VSCODE_HOST_MOUNT VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME

if [[ -d "../patches/alpine/reh/" ]]; then
  for file in "../patches/alpine/reh/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

# For Alpine ARM64, skip native module builds to avoid compiler crashes
# Native modules like kerberos can't be built reliably in the Alpine ARM64 environment
NPM_CI_OPTS=""
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  NPM_CI_OPTS="--ignore-scripts"
  echo "Skipping postinstall scripts for Alpine ARM64 (native modules can't build reliably)"
  # Also prevent node-gyp from trying to build native modules
  export npm_config_build_from_source=false
  export npm_config_ignore_scripts=true
fi

for i in {1..5}; do # try 5 times
  npm ci ${NPM_CI_OPTS} && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

# Fix gulpfile.reh.js to use VSCODE_NODEJS_SITE for Alpine ARM64
# This ensures Node.js is downloaded from unofficial-builds.nodejs.org instead of trying Docker
# This MUST be done AFTER mixin-npm, as mixin-npm may regenerate/modify gulpfile.reh.js
if [[ -f "build/gulpfile.reh.js" ]] && [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  echo "=========================================="
  echo "NODEJS URL FIX CHECK FOR ALPINE ${VSCODE_ARCH} (AFTER MIXIN-NPM)"
  echo "=========================================="
  echo "Environment variables: VSCODE_NODEJS_SITE=${VSCODE_NODEJS_SITE}, VSCODE_NODEJS_URLROOT=${VSCODE_NODEJS_URLROOT}, VSCODE_NODEJS_URLSUFFIX=${VSCODE_NODEJS_URLSUFFIX}"
  
  if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
    echo "Applying direct fix to gulpfile.reh.js for Alpine ARM64 Node.js download URL..."
    # Use the same fix script as Linux REH builds, but search for 'case alpine' instead of 'case linux'
    cat > /tmp/fix-nodejs-url-alpine.js << 'NODEJS_SCRIPT'
      const fs = require('fs');
      const path = './build/gulpfile.reh.js';
      let content = fs.readFileSync(path, 'utf8');

      console.log('Checking if fix is needed for Alpine ARM64...');
      console.log('  - fetchUrls found:', content.includes('fetchUrls'));
      console.log('  - nodejs.org found:', content.includes('https://nodejs.org'));
      console.log('  - VSCODE_NODEJS_SITE already present:', content.includes('process.env.VSCODE_NODEJS_SITE'));
      console.log('  - extractAlpinefromDocker found:', content.includes('extractAlpinefromDocker'));
      
      if (!content.includes('process.env.VSCODE_NODEJS_SITE')) {
        console.log('Fix is needed, searching for case alpine block...');
        
        // Find case 'alpine' block - try both single and double quotes
        let caseAlpineIndex = content.indexOf("case 'alpine':");
        if (caseAlpineIndex === -1) {
          caseAlpineIndex = content.indexOf('case "alpine":');
        }
        
        // Also try with whitespace variations
        if (caseAlpineIndex === -1) {
          const caseAlpineRegex = /case\s+['"]alpine['"]\s*:/;
          const match = content.match(caseAlpineRegex);
          if (match) {
            caseAlpineIndex = content.indexOf(match[0]);
          }
        }

        if (caseAlpineIndex === -1) {
          console.log('⚠ Could not find case "alpine" block');
          console.log('Showing lines around potential case statements:');
          const lines = content.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].includes('case') && lines[i].includes('alpine')) {
              console.log(`Line ${i + 1}: ${lines[i]}`);
            }
          }
          process.exit(1);
        }
        
        console.log(`Found case alpine at index ${caseAlpineIndex}`);

        // Find where extractAlpinefromDocker is called in the case alpine block
        const afterCase = content.substring(caseAlpineIndex);
        console.log('Searching for extractAlpinefromDocker call...');
        
        // Look for the return statement that contains extractAlpinefromDocker
        // The structure is likely: return (condition ? extractAlpinefromDocker(...) : somethingElse)
        // Or: return extractAlpinefromDocker(...)
        const returnPattern = /return\s*\([^)]*extractAlpinefromDocker[^)]*\)/;
        const returnMatch = afterCase.match(returnPattern);
        
        if (returnMatch) {
          console.log('Found return statement with extractAlpinefromDocker');
          const returnStartIndex = caseAlpineIndex + returnMatch.index;
          const returnEndIndex = returnStartIndex + returnMatch[0].length;
          const fullReturnStatement = content.substring(returnStartIndex, returnEndIndex);
          
          console.log('Full return statement:', fullReturnStatement);
          
          // Check if it's a ternary: condition ? extractAlpinefromDocker(...) : something
          if (fullReturnStatement.includes('?') && fullReturnStatement.includes(':')) {
            console.log('Return statement contains ternary operator');
            // Extract the condition, true part, and false part
            const ternaryMatch = fullReturnStatement.match(/return\s*\((.*?)\s*\?\s*(.*?)\s*:\s*(.*?)\)/);
            if (ternaryMatch) {
              const condition = ternaryMatch[1];
              const truePart = ternaryMatch[2]; // This should contain extractAlpinefromDocker
              const falsePart = ternaryMatch[3];
              
              // Replace the ternary with a nested ternary that checks VSCODE_NODEJS_SITE first
              const newReturnStatement = `return (${condition} ? (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT
				? fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'))
				: ${truePart}) : ${falsePart})`;
              
              content = content.substring(0, returnStartIndex) + newReturnStatement + content.substring(returnEndIndex);
            } else {
              console.log('⚠ Could not parse ternary structure, using simple replacement');
              // Fallback: just replace extractAlpinefromDocker with our check
              const newReturnStatement = fullReturnStatement.replace(
                /extractAlpinefromDocker\s*\([^)]+\)/,
                `(process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT
				? fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'))
				: extractAlpinefromDocker(nodeVersion, platform, arch))`
              );
              content = content.substring(0, returnStartIndex) + newReturnStatement + content.substring(returnEndIndex);
            }
          } else {
            // Simple return extractAlpinefromDocker(...)
            console.log('Return statement is simple (no ternary)');
            const newReturnStatement = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			${fullReturnStatement}`;
            content = content.substring(0, returnStartIndex) + newReturnStatement + content.substring(returnEndIndex);
          }
        } else {
          // No return statement found, look for just extractAlpinefromDocker
          const extractPattern = /extractAlpinefromDocker\s*\(/;
          const extractMatch = afterCase.match(extractPattern);
          
          if (!extractMatch) {
            console.log('⚠ Could not find extractAlpinefromDocker call in case alpine block');
            console.log('Showing first 1000 chars after case alpine:');
            console.log(afterCase.substring(0, 1000));
            process.exit(1);
          }
          
          const extractStartIndex = caseAlpineIndex + extractMatch.index;
          const afterExtractStart = content.substring(extractStartIndex);
          const extractCallPattern = /extractAlpinefromDocker\s*\([^)]+\)/;
          const extractCallMatch = afterExtractStart.match(extractCallPattern);
          
          if (!extractCallMatch) {
            console.log('⚠ Could not find complete extractAlpinefromDocker call');
            process.exit(1);
          }
          
          const extractEndIndex = extractStartIndex + extractCallMatch.index + extractCallMatch[0].length;
          const fullExtractCall = extractCallMatch[0];
          
          // Insert if statement before extractAlpinefromDocker
          const newCode = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			return ${fullExtractCall}`;
          content = content.substring(0, extractStartIndex) + newCode + content.substring(extractEndIndex);
        }
        fs.writeFileSync(path, content, 'utf8');
        console.log('✓ gulpfile.reh.js Node.js URL fix applied successfully for Alpine ARM64');
      } else if (content.includes('process.env.VSCODE_NODEJS_SITE')) {
        console.log('✓ gulpfile.reh.js Node.js URL fix already applied');
      } else {
        console.log('⚠ gulpfile.reh.js Node.js URL fix not needed (code structure different)');
        process.exit(1);
      }
NODEJS_SCRIPT

    node /tmp/fix-nodejs-url-alpine.js || {
      echo "ERROR: Failed to apply gulpfile.reh.js Node.js URL fix for Alpine ARM64!"
      rm -f /tmp/fix-nodejs-url-alpine.js
      exit 1
    }
    rm -f /tmp/fix-nodejs-url-alpine.js

    # Verify fix was applied
    if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
      echo "ERROR: gulpfile.reh.js Node.js URL fix verification failed for Alpine ARM64!"
      exit 1
    fi
    echo "✓ Verified gulpfile.reh.js Node.js URL fix is applied for Alpine ARM64"
  else
    echo "✓ gulpfile.reh.js Node.js URL fix already applied for Alpine ARM64"
  fi
  echo "=========================================="
fi

# Install extension dependencies (required for TypeScript compilation)
# This matches the Linux REH build script approach
echo "Installing extension dependencies..."
for ext_dir in extensions/*/; do
  if [[ -f "${ext_dir}package.json" ]] && [[ -f "${ext_dir}package-lock.json" ]]; then
    ext_name=$(basename "$ext_dir")
    echo "Installing deps for ${ext_name}..."
    # Use npm ci with --ignore-scripts (extension dependencies are usually JS packages, not native modules)
    # This is safe even for Alpine ARM64 as most extension deps don't need native compilation
    if (cd "$ext_dir" && npm ci --ignore-scripts); then
      echo "✓ Successfully installed dependencies for ${ext_name}"
    else
      echo "⚠ Warning: Failed to install dependencies for ${ext_name}, continuing..."
    fi
  fi
done

# For Alpine ARM64, ensure ternary-stream is installed in build directory (it might be missing due to --ignore-scripts)
# ternary-stream is required by build/lib/util.js, so it needs to be in build/node_modules
# This must be done BEFORE running any gulp commands
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  echo "Checking for ternary-stream in build directory for Alpine ARM64..."
  # Check if ternary-stream exists in build/node_modules (more reliable than npm list)
  if [[ ! -d "build/node_modules/ternary-stream" ]] && [[ ! -f "build/node_modules/ternary-stream/package.json" ]]; then
    echo "Installing ternary-stream in build directory (required for build/lib/util.js but may be missing due to --ignore-scripts)..."
    # Ensure build directory exists and has a package.json
    if [[ ! -f "build/package.json" ]]; then
      echo "ERROR: build/package.json not found, cannot install ternary-stream"
      exit 1
    fi
    npm install ternary-stream --prefix build --no-save --legacy-peer-deps || {
      echo "ERROR: Failed to install ternary-stream in build directory!"
      echo "This is required for Alpine ARM64 REH builds"
      exit 1
    }
    # Verify installation
    if [[ ! -d "build/node_modules/ternary-stream" ]] && [[ ! -f "build/node_modules/ternary-stream/package.json" ]]; then
      echo "ERROR: ternary-stream installation verification failed!"
      exit 1
    fi
    echo "✓ ternary-stream installed successfully in build directory"
  else
    echo "✓ ternary-stream already present in build directory"
  fi
fi

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  PA_NAME="linux-alpine"
else
  PA_NAME="alpine-arm64"
fi

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
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

  npm run gulp "vscode-reh-${PA_NAME}-min-ci"

  pushd "../vscode-reh-${PA_NAME}"

  echo "Archiving REH"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building REH-web"
  npm run gulp minify-vscode-reh-web
  npm run gulp "vscode-reh-web-${PA_NAME}-min-ci"

  pushd "../vscode-reh-web-${PA_NAME}"

  echo "Archiving REH-web"
  tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
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
