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
    if [[ -f "${file}" ]] && [[ "${file}" != *"fix-nodejs-url.patch" ]]; then
      apply_patch "${file}"
    fi
  done
fi

# For Alpine, skip postinstall scripts to avoid ripgrep download failures (403 errors)
# Alpine builds can have issues downloading ripgrep from GitHub releases
# We'll handle ripgrep replacement after npm install if needed
NPM_CI_OPTS="--ignore-scripts"
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  echo "Skipping postinstall scripts for Alpine ARM64 (native modules can't build reliably)"
  # Also prevent node-gyp from trying to build native modules
  export npm_config_build_from_source=false
  export npm_config_ignore_scripts=true
else
  echo "Skipping postinstall scripts for Alpine ${VSCODE_ARCH} (ripgrep download may fail with 403)"
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
    echo "Applying Node.js URL fix patch for Alpine ARM64..."
    if [[ -f "../patches/alpine/reh/fix-nodejs-url.patch" ]]; then
      apply_patch "../patches/alpine/reh/fix-nodejs-url.patch" || {
        echo "WARNING: Failed to apply Node.js URL fix patch, will try Node.js script fallback..."
        SKIP_PATCH=1
      }

      if [[ "${SKIP_PATCH}" != "1" ]]; then
        # Verify fix was applied
        if ! grep -q "process.env.VSCODE_NODEJS_SITE" build/gulpfile.reh.js 2>/dev/null; then
          echo "WARNING: Node.js URL fix patch verification failed, will try Node.js script fallback..."
          SKIP_PATCH=1
        else
          echo "✓ Node.js URL fix patch applied and verified"
          SKIP_NODEJS_SCRIPT=1
        fi
      fi
    else
      echo "WARNING: Node.js URL fix patch not found, will use Node.js script approach..."
      SKIP_PATCH=1
    fi

    # Only run Node.js script if patch didn't work
    if [[ "${SKIP_NODEJS_SCRIPT}" != "1" ]]; then
      echo "Applying direct fix to gulpfile.reh.js for Alpine ARM64 Node.js download URL (fallback)..."
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

        // Find the next case or end of switch to limit search scope
        const nextCaseMatch = afterCase.match(/case\s+['"]/);
        const searchEndIndex = nextCaseMatch ? caseAlpineIndex + nextCaseMatch.index : content.length;
        const alpineCaseContent = content.substring(caseAlpineIndex, searchEndIndex);

        // Look for the ternary pattern first - this is the most common structure
        // The code is: return (product.nodejsRepository !== 'https://nodejs.org' ? ... : extractAlpinefromDocker(...))
        const ternaryPattern = /return\s*\(\s*product\.nodejsRepository\s*!==\s*['"]https:\/\/nodejs\.org['"]\s*\?/;
        const ternaryMatch = alpineCaseContent.match(ternaryPattern);

        let extractStartIndex = -1;
        let extractMatch = null;

        if (ternaryMatch) {
          console.log('Found ternary pattern, will replace entire ternary');
          // Find the start of the return statement
          extractStartIndex = caseAlpineIndex + ternaryMatch.index;
        } else {
          // Fallback: look for extractAlpinefromDocker directly
          const extractPattern = /extractAlpinefromDocker\s*\(/;
          extractMatch = alpineCaseContent.match(extractPattern);

          if (extractMatch) {
            console.log('Found extractAlpinefromDocker call directly');
            extractStartIndex = caseAlpineIndex + extractMatch.index;
          } else {
            console.log('⚠ Could not find ternary pattern or extractAlpinefromDocker call in case alpine block');
            console.log('Showing first 2000 chars after case alpine:');
            console.log(alpineCaseContent.substring(0, 2000));
            console.log('ERROR: Could not find any matching pattern in case alpine block');
            process.exit(1);
          }
        }

        // Find the return statement - if we found the ternary pattern, extractStartIndex is already at the return
        let returnStartIndex = extractStartIndex;
        let foundReturn = false;

        if (ternaryMatch) {
          // We already found the return statement with the ternary
          foundReturn = true;
        } else {
          // Look backwards from extractStartIndex to find 'return'
          for (let i = extractStartIndex - 1; i >= Math.max(0, caseAlpineIndex - 100); i--) {
            const substr = content.substring(Math.max(0, i - 6), i + 1);
            if (substr === 'return') {
              const beforeChar = i >= 6 ? content.charAt(i - 7) : '';
              if (i < 7 || beforeChar === ' ' || beforeChar === '\t' || beforeChar === '\n' || beforeChar === '{' || beforeChar === ';') {
                returnStartIndex = Math.max(0, i - 6);
                foundReturn = true;
                break;
              }
            }
          }
        }

        if (!foundReturn) {
          console.log('⚠ Could not find return statement');
          console.log('Showing context around start index:');
          console.log(content.substring(Math.max(0, extractStartIndex - 300), Math.min(content.length, extractStartIndex + 100)));
          process.exit(1);
        }

        // Find the end of the return statement - it ends with .pipe(rename('node')) or similar
        const afterReturnStart = content.substring(returnStartIndex);
        const renamePattern = /\.pipe\(rename\(['"]node['"]\)\)/;
        const renameMatch = afterReturnStart.match(renamePattern);

        if (!renameMatch) {
          console.log('⚠ Could not find end of return statement (.pipe(rename))');
          console.log('Showing context around return start:');
          console.log(content.substring(Math.max(0, returnStartIndex - 200), Math.min(content.length, returnStartIndex + 500)));
          process.exit(1);
        }

        const returnEndIndex = returnStartIndex + renameMatch.index + renameMatch[0].length;
        const fullReturnStatement = content.substring(returnStartIndex, returnEndIndex);

        console.log('Found return statement containing extractAlpinefromDocker');
        console.log('Return statement start index:', returnStartIndex);
        console.log('Return statement end index:', returnEndIndex);
        console.log('Return statement length:', fullReturnStatement.length);
        console.log('Return statement (first 400 chars):', fullReturnStatement.substring(0, 400));
        console.log('Return statement (last 150 chars):', fullReturnStatement.substring(Math.max(0, fullReturnStatement.length - 150)));

        // Verify that the return statement contains either extractAlpinefromDocker or the ternary pattern
        if (!fullReturnStatement.includes('extractAlpinefromDocker') && !fullReturnStatement.includes('product.nodejsRepository')) {
          console.log('ERROR: extractAlpinefromDocker or product.nodejsRepository not found in the return statement!');
          console.log('This suggests the return statement was found incorrectly.');
          console.log('return statement is at index:', returnStartIndex, 'to', returnEndIndex);
          console.log('Content before return:', content.substring(Math.max(0, returnStartIndex - 50), returnStartIndex));
          console.log('Content after return end:', content.substring(returnEndIndex, Math.min(content.length, returnEndIndex + 50)));
          process.exit(1);
        }

        // Verify the return statement is complete (starts with 'return' and ends properly)
        if (!fullReturnStatement.trim().startsWith('return')) {
          console.log('ERROR: Return statement does not start with "return"!');
          console.log('First 50 chars:', fullReturnStatement.substring(0, 50));
          process.exit(1);
        }

        // Check if it's a ternary: condition ? extractAlpinefromDocker(...) : something
        if (fullReturnStatement.includes('?') && fullReturnStatement.includes(':')) {
          console.log('Return statement contains ternary operator');
          // Find the ternary condition and parts
          // Pattern: return (condition ? truePart : falsePart)
          const ternaryStart = fullReturnStatement.indexOf('(');
          const ternaryEnd = fullReturnStatement.lastIndexOf(')');
          const ternaryContent = fullReturnStatement.substring(ternaryStart + 1, ternaryEnd);

          // Find the ? and : in the ternary
          let questionIndex = -1;
          let colonIndex = -1;
          let depth = 0;

          for (let i = 0; i < ternaryContent.length; i++) {
            const char = ternaryContent[i];
            if (char === '(') depth++;
            else if (char === ')') depth--;
            else if (char === '?' && depth === 0 && questionIndex === -1) {
              questionIndex = i;
            } else if (char === ':' && depth === 0 && questionIndex !== -1 && colonIndex === -1) {
              colonIndex = i;
              break;
            }
          }

          if (questionIndex !== -1 && colonIndex !== -1) {
            const condition = ternaryContent.substring(0, questionIndex).trim();
            const truePart = ternaryContent.substring(questionIndex + 1, colonIndex).trim();
            const falsePart = ternaryContent.substring(colonIndex + 1).trim();

            console.log('Parsed ternary: condition, truePart, falsePart');

            // Replace with nested ternary that checks VSCODE_NODEJS_SITE first
            const newReturnStatement = `return (${condition} ? (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT
				? fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'))
				: ${truePart}) : ${falsePart})`;

            console.log('Replacing ternary with nested ternary...');
            content = content.substring(0, returnStartIndex) + newReturnStatement + content.substring(returnEndIndex);
          } else {
            console.log('⚠ Could not parse ternary structure, replacing entire return with if statement');
            // Replace entire return with if statement - this is safer than trying to parse complex ternaries
            // Remove 'return' from the original statement since we're wrapping it in an if
            const originalStatement = fullReturnStatement.replace(/^return\s+/, '');
            const newReturnStatement = `if (process.env.VSCODE_NODEJS_SITE && process.env.VSCODE_NODEJS_URLROOT) {
				return fetchUrls(\`\${process.env.VSCODE_NODEJS_URLROOT}/v\${nodeVersion}/node-v\${nodeVersion}-\${platform}-\${arch}\${process.env.VSCODE_NODEJS_URLSUFFIX || ''}.tar.gz\`, { base: process.env.VSCODE_NODEJS_SITE, checksumSha256 })
					.pipe(flatmap(stream => stream.pipe(gunzip()).pipe(untar())))
					.pipe(filter('**/node'))
					.pipe(util.setExecutableBit('**'))
					.pipe(rename('node'));
			}
			return ${originalStatement}`;
            console.log('Replacing entire return statement with if statement wrapper...');
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

        fs.writeFileSync(path, content, 'utf8');
        console.log('✓ gulpfile.reh.js Node.js URL fix applied successfully for Alpine ARM64');

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
      echo "✓ Verified gulpfile.reh.js Node.js URL fix is applied for Alpine ARM64 (fallback script)"
    fi
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

# For Alpine, ensure ternary-stream is installed in build directory (it might be missing due to --ignore-scripts)
# ternary-stream is required by build/lib/util.js, so it needs to be in build/node_modules
# This must be done BEFORE running any gulp commands
# This affects both ARM64 and X64 (X64 also uses --ignore-scripts which can skip postinstall scripts)
echo "Checking for ternary-stream in build directory for Alpine ${VSCODE_ARCH}..."
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
    echo "This is required for Alpine REH builds"
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
