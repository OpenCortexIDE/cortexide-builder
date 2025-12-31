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

# Verify and apply fix-reh-empty-dependencies fix if patch didn't work
# This prevents "Invalid glob argument" errors when productionDependencies is empty
if [[ -f "build/gulpfile.reh.js" ]]; then
  if ! grep -q "dependenciesSrc.length > 0" build/gulpfile.reh.js 2>/dev/null; then
    echo "Applying fix-reh-empty-dependencies fix to gulpfile.reh.js..."
    node -e "
      const fs = require('fs');
      const path = './build/gulpfile.reh.js';
      let content = fs.readFileSync(path, 'utf8');
      let fixApplied = false;

      console.log('Checking for fix-reh-empty-dependencies patterns...');
      console.log('  - Has dependenciesSrc:', content.includes('dependenciesSrc'));
      console.log('  - Has gulp.src(dependenciesSrc:', content.includes('gulp.src(dependenciesSrc'));
      console.log('  - Has productionDependencies:', content.includes('productionDependencies'));

      // Pattern 1: Standard pattern with exact spacing
      const pattern1 = /const dependenciesSrc = productionDependencies\.map\(d => path\.relative\(REPO_ROOT, d\)\)\.map\(d => \[`\${d}\/\*\*`, `!\${d}\/\*\*\/{test,tests}\/\*\*`, `!\${d}\/.bin\/\*\*`\]\)\.flat\(\);/;
      // Pattern 2: More flexible spacing
      const pattern2 = /const\s+dependenciesSrc\s*=\s*productionDependencies\.map\(d\s*=>\s*path\.relative\(REPO_ROOT,\s*d\)\)\.map\(d\s*=>\s*\[`\${d}\/\*\*`,\s*`!\${d}\/\*\*\/{test,tests}\/\*\*`,\s*`!\${d}\/.bin\/\*\*`\]\)\.flat\(\);/;

      // Pattern for gulp.src call - more flexible
      const gulpPattern1 = /const\s+deps\s*=\s*gulp\.src\(dependenciesSrc,\s*{\s*base:\s*['\"]remote['\"],\s*dot:\s*true\s*}\)/;
      const gulpPattern2 = /const\s+deps\s*=\s*gulp\.src\(dependenciesSrc,/;

      // Check if fix is needed
      if (content.includes('dependenciesSrc') && content.includes('gulp.src') && !content.includes('dependenciesSrc.length > 0')) {
        console.log('Fix is needed, attempting to apply...');

        // Try pattern 1 first
        if (pattern1.test(content)) {
          console.log('  - Matched pattern1 (exact)');
          content = content.replace(
            pattern1,
            'const dependenciesSrc = productionDependencies.map(d => path.relative(REPO_ROOT, d)).filter(d => d && d.trim() !== \"\").map(d => [`\${d}/**`, `!\${d}/**/{test,tests}/**`, `!\${d}/.bin/**`]).flat();'
          );
          fixApplied = true;
        } else if (pattern2.test(content)) {
          console.log('  - Matched pattern2 (flexible)');
          content = content.replace(
            pattern2,
            'const dependenciesSrc = productionDependencies.map(d => path.relative(REPO_ROOT, d)).filter(d => d && d.trim() !== \"\").map(d => [`\${d}/**`, `!\${d}/**/{test,tests}/**`, `!\${d}/.bin/**`]).flat();'
          );
          fixApplied = true;
        } else {
          console.log('  - Could not match dependenciesSrc pattern, trying to find it manually...');
          // Try to find the line and replace it manually
          const lines = content.split('\\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].includes('dependenciesSrc') && lines[i].includes('productionDependencies') && lines[i].includes('map')) {
              console.log(`  - Found potential line ${i + 1}: ${lines[i].substring(0, 100)}`);
              if (!lines[i].includes('filter')) {
                lines[i] = lines[i].replace(
                  /\.map\(d\s*=>\s*\[`\${d}\/\*\*`/,
                  '.filter(d => d && d.trim() !== \"\").map(d => [`\${d}/**`'
                );
                fixApplied = true;
                break;
              }
            }
          }
          if (fixApplied) {
            content = lines.join('\\n');
          }
        }

        // Now fix the gulp.src call
        if (gulpPattern1.test(content)) {
          console.log('  - Matched gulpPattern1 (exact)');
          content = content.replace(
            gulpPattern1,
            'const deps = dependenciesSrc.length > 0 ? gulp.src(dependenciesSrc, { base: \'remote\', dot: true }) : gulp.src([\'**\'], { base: \'remote\', dot: true, allowEmpty: true })'
          );
        } else if (gulpPattern2.test(content)) {
          console.log('  - Matched gulpPattern2 (flexible), replacing...');
          // Find the full line and replace it
          const lines = content.split('\\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].includes('const deps') && lines[i].includes('gulp.src(dependenciesSrc')) {
              console.log(`  - Found gulp.src line ${i + 1}: ${lines[i]}`);
              if (!lines[i].includes('dependenciesSrc.length > 0')) {
                lines[i] = lines[i].replace(
                  /const\s+deps\s*=\s*gulp\.src\(dependenciesSrc,.*?\)/,
                  'const deps = dependenciesSrc.length > 0 ? gulp.src(dependenciesSrc, { base: \'remote\', dot: true }) : gulp.src([\'**\'], { base: \'remote\', dot: true, allowEmpty: true })'
                );
                fixApplied = true;
                break;
              }
            }
          }
          if (fixApplied) {
            content = lines.join('\\n');
          }
        }

        if (fixApplied) {
          fs.writeFileSync(path, content, 'utf8');
          console.log('✓ fix-reh-empty-dependencies fix applied successfully');
        } else {
          console.log('⚠ Could not apply fix - pattern matching failed');
          console.log('Showing relevant code around dependenciesSrc:');
          const lines = content.split('\\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].includes('dependenciesSrc') || (lines[i].includes('gulp.src') && lines[i].includes('dependenciesSrc'))) {
              console.log(`Line ${i + 1}: ${lines[i]}`);
            }
          }
        }
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
      echo "Showing relevant lines from gulpfile.reh.js:"
      grep -n "dependenciesSrc\|gulp.src" build/gulpfile.reh.js | head -20
      exit 1
    else
      echo "✓ fix-reh-empty-dependencies fix verified successfully"
    fi
  else
    echo "✓ fix-reh-empty-dependencies already applied (found in gulpfile.reh.js)"
  fi
fi

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
        console.log('Fix is needed, searching for extractAlpinefromDocker or Alpine download logic...');

        // The code structure has changed - case 'alpine' now only sets expectedName
        // The actual download logic with extractAlpinefromDocker is in a different switch statement
        // Search for extractAlpinefromDocker directly
        let extractIndex = content.indexOf('extractAlpinefromDocker');
        if (extractIndex === -1) {
          console.log('⚠ Could not find extractAlpinefromDocker in file');
          console.log('Searching for Alpine-related download patterns...');

          // Try to find the switch statement that handles platform downloads
          // Look for patterns like: switch (platform) or function nodejs
          const nodejsFunctionMatch = content.match(/function\s+nodejs\s*\([^)]*\)\s*\{/);
          if (nodejsFunctionMatch) {
            const nodejsStart = content.indexOf(nodejsFunctionMatch[0]);
            console.log(`Found nodejs function at index ${nodejsStart}`);

            // Look for the switch(platform) statement within the function
            const switchPlatformMatch = content.substring(nodejsStart).match(/switch\s*\(\s*platform\s*\)\s*\{/);
            if (switchPlatformMatch) {
              const switchStart = nodejsStart + content.substring(nodejsStart).indexOf(switchPlatformMatch[0]);
              console.log(`Found switch(platform) at index ${switchStart}`);

              // Now search for case 'alpine' in this switch
              const caseAlpineMatch = content.substring(switchStart).match(/case\s+['"]alpine['"]\s*:/);
              if (caseAlpineMatch) {
                extractIndex = switchStart + content.substring(switchStart).indexOf(caseAlpineMatch[0]);
                console.log(`Found case 'alpine' in switch(platform) at index ${extractIndex}`);
              }
            }
          }

          if (extractIndex === -1) {
            console.log('⚠ Could not find Alpine download logic');
            console.log('Showing lines with "alpine" or "extractAlpine":');
            const lines = content.split('\n');
            for (let i = 0; i < lines.length; i++) {
              if (lines[i].toLowerCase().includes('alpine') || lines[i].includes('extractalpine')) {
                console.log(`Line ${i + 1}: ${lines[i]}`);
              }
            }
            process.exit(1);
          }
        } else {
          console.log(`Found extractAlpinefromDocker at index ${extractIndex}`);
        }

        // Use extractIndex as the starting point for finding the case block
        let caseAlpineIndex = extractIndex;

        // Look backwards to find the case 'alpine' statement
        const beforeExtract = content.substring(0, extractIndex);
        const caseAlpineMatch = beforeExtract.match(/case\s+['"]alpine['"]\s*:/);
        if (caseAlpineMatch) {
          caseAlpineIndex = beforeExtract.lastIndexOf(caseAlpineMatch[0]);
          console.log(`Found case 'alpine' at index ${caseAlpineIndex} (before extractAlpinefromDocker)`);
        } else {
          console.log('Could not find case "alpine" before extractAlpinefromDocker, using extractAlpinefromDocker position');
        }

        console.log(`Found case alpine or extractAlpinefromDocker at index ${caseAlpineIndex}`);

        // Now find the actual case 'alpine' block that contains extractAlpinefromDocker
        // Look backwards from extractAlpinefromDocker to find the case statement
        let actualCaseAlpineIndex = caseAlpineIndex;
        const beforeExtract = content.substring(0, caseAlpineIndex);

        // Search backwards for the case 'alpine' statement
        const caseAlpineRegex = /case\s+['"]alpine['"]\s*:/g;
        let match;
        let lastMatchIndex = -1;
        while ((match = caseAlpineRegex.exec(beforeExtract)) !== null) {
          lastMatchIndex = match.index;
        }

        if (lastMatchIndex !== -1) {
          // Check if this case block contains extractAlpinefromDocker
          const caseBlockStart = lastMatchIndex;
          // Find the next case or default
          const afterThisCase = content.substring(caseBlockStart);
          const nextCaseMatch = afterThisCase.substring(10).match(/case\s+['"]|default\s*:/);
          const caseBlockEnd = nextCaseMatch ? caseBlockStart + 10 + nextCaseMatch.index : content.length;

          if (caseAlpineIndex >= caseBlockStart && caseAlpineIndex < caseBlockEnd) {
            actualCaseAlpineIndex = caseBlockStart;
            console.log(`Found case 'alpine' block containing extractAlpinefromDocker at index ${actualCaseAlpineIndex}`);
          } else {
            console.log(`Case 'alpine' at ${lastMatchIndex} does not contain extractAlpinefromDocker, searching for another one...`);
            // The extractAlpinefromDocker might be in a different switch statement
            // Look for switch(platform) and find case 'alpine' there
            const switchPlatformMatch = content.match(/switch\s*\(\s*platform\s*\)\s*\{/);
            if (switchPlatformMatch) {
              const switchStart = switchPlatformMatch.index;
              const afterSwitch = content.substring(switchStart);
              const caseAlpineInSwitch = afterSwitch.match(/case\s+['"]alpine['"]\s*:/);
              if (caseAlpineInSwitch) {
                actualCaseAlpineIndex = switchStart + caseAlpineInSwitch.index;
                console.log(`Found case 'alpine' in switch(platform) at index ${actualCaseAlpineIndex}`);
              }
            }
          }
        }

        // Show the actual case statement line
        const caseLineStart = content.lastIndexOf('\n', actualCaseAlpineIndex);
        const caseLineEnd = content.indexOf('\n', actualCaseAlpineIndex);
        if (caseLineStart !== -1 && caseLineEnd !== -1) {
          console.log('Case alpine line:', content.substring(caseLineStart + 1, caseLineEnd));
        }

        // Find where extractAlpinefromDocker is called in the case alpine block
        const afterCase = content.substring(actualCaseAlpineIndex);
        console.log('Searching for extractAlpinefromDocker call...');
        console.log('First 1000 chars after case alpine:');
        console.log(afterCase.substring(0, 1000));

        // Find the next case or end of switch to limit search scope
        // Look for the next case statement (but not the current one)
        let searchEndIndex = content.length;

        // Skip past the current case statement - find the colon and newline
        let caseColonIndex = content.indexOf(':', actualCaseAlpineIndex);
        if (caseColonIndex === -1) {
          console.log('ERROR: Could not find colon after case alpine');
          process.exit(1);
        }

        // Find the start of the actual code (after the colon and any whitespace)
        let codeStartIndex = caseColonIndex + 1;
        while (codeStartIndex < content.length && (content[codeStartIndex] === ' ' || content[codeStartIndex] === '\t' || content[codeStartIndex] === '\n')) {
          codeStartIndex++;
        }

        console.log(`Case colon at ${caseColonIndex}, code starts at ${codeStartIndex}`);

        // Now look for the next case statement AFTER the current one
        const afterCaseCode = content.substring(codeStartIndex);
        const nextCaseMatch = afterCaseCode.match(/case\s+['"]/);
        if (nextCaseMatch) {
          searchEndIndex = codeStartIndex + nextCaseMatch.index;
          console.log(`Found next case at index ${searchEndIndex}`);
        } else {
          // Look for the closing brace of the switch statement or default
          const defaultMatch = afterCaseCode.match(/^\s*default\s*:/);
          if (defaultMatch) {
            searchEndIndex = codeStartIndex + defaultMatch.index;
            console.log(`Found default at index ${searchEndIndex}`);
          } else {
            console.log('No next case or default found, using end of file');
          }
        }

        let alpineCaseContent = content.substring(actualCaseAlpineIndex, searchEndIndex);
        console.log(`Extracted alpine case content: ${caseAlpineIndex} to ${searchEndIndex}, length: ${alpineCaseContent.length}`);

        if (alpineCaseContent.length === 0 || alpineCaseContent.trim().length < 10) {
          console.log('ERROR: Extracted case content is empty or too short!');
          console.log('Trying alternative extraction method...');
          // Try to find the content by looking for the return statement or extractAlpinefromDocker
          const extractIndex = content.indexOf('extractAlpinefromDocker', caseAlpineIndex);
          if (extractIndex !== -1 && extractIndex < searchEndIndex) {
            console.log(`Found extractAlpinefromDocker at index ${extractIndex}`);
            // Look backwards for return, forwards for the end
            let returnIndex = content.lastIndexOf('return', extractIndex);
            if (returnIndex === -1 || returnIndex < caseAlpineIndex) {
              returnIndex = codeStartIndex;
            }
            // Look forwards for the end of the statement - find the closing paren and semicolon
            let endIndex = content.indexOf(';', extractIndex);
            if (endIndex === -1 || endIndex > searchEndIndex) {
              // Look for the end of the pipe chain
              endIndex = content.indexOf('.pipe(rename', extractIndex);
              if (endIndex !== -1) {
                endIndex = content.indexOf(')', endIndex) + 1;
              }
            }
            if (endIndex === -1 || endIndex > searchEndIndex) {
              endIndex = Math.min(searchEndIndex, extractIndex + 1000);
            }
            const altContent = content.substring(returnIndex, endIndex);
            console.log(`Alternative extraction: ${returnIndex} to ${endIndex}, length: ${altContent.length}`);
            if (altContent.length > 0) {
              console.log('Alternative content (first 1000 chars):');
              console.log(altContent.substring(0, 1000));
              // Use this as the alpine case content for pattern matching
              alpineCaseContent = altContent;
            } else {
              console.log('Alternative extraction also failed');
              process.exit(1);
            }
          } else {
            console.log('Could not find extractAlpinefromDocker in case block');
            console.log(`Searched from ${caseAlpineIndex} to ${searchEndIndex}`);
            // Show what we found
            console.log('Content from caseAlpineIndex to searchEndIndex:');
            console.log(content.substring(caseAlpineIndex, Math.min(caseAlpineIndex + 500, searchEndIndex)));
            process.exit(1);
          }
        }

        // Ensure we have valid content
        if (!alpineCaseContent || alpineCaseContent.length === 0) {
          console.log('ERROR: Could not extract alpine case content!');
          console.log('Showing context around case alpine:');
          console.log(content.substring(Math.max(0, caseAlpineIndex - 200), Math.min(content.length, caseAlpineIndex + 1000)));
          process.exit(1);
        }

        console.log('Alpine case content length:', alpineCaseContent.length);
        if (alpineCaseContent.length > 0) {
          console.log('First 1000 chars of case alpine:');
          console.log(alpineCaseContent.substring(0, 1000));
          console.log('Last 500 chars of case alpine:');
          console.log(alpineCaseContent.substring(Math.max(0, alpineCaseContent.length - 500)));
        }
        console.log('Searching for patterns...');

        // Look for various patterns that might exist
        // Pattern 1: Ternary with product.nodejsRepository (exact match)
        const ternaryPattern1 = /return\s*\(\s*product\.nodejsRepository\s*!==\s*['"]https:\/\/nodejs\.org['"]\s*\?/;
        // Pattern 2: Ternary with different spacing (more flexible)
        const ternaryPattern2 = /return\s*\(\s*product\.nodejsRepository\s*!==\s*['"]https:\/\/nodejs\.org['"]/;
        // Pattern 3: Direct extractAlpinefromDocker call
        const extractPattern = /extractAlpinefromDocker\s*\(/;
        // Pattern 4: Any return statement in the case block
        const returnPattern = /return\s*\(/;
        // Pattern 5: Look for the pipe chain after the ternary (more specific)
        const pipePattern = /\.pipe\s*\(\s*flatmap\s*\(/;
        // Pattern 6: Look for fetchGithub in the case block
        const fetchGithubPattern = /fetchGithub\s*\(/;

        const ternaryMatch1 = alpineCaseContent.match(ternaryPattern1);
        const ternaryMatch2 = !ternaryMatch1 ? alpineCaseContent.match(ternaryPattern2) : null;
        const extractMatch = alpineCaseContent.match(extractPattern);
        const returnMatch = alpineCaseContent.match(returnPattern);
        const pipeMatch = alpineCaseContent.match(pipePattern);
        const fetchGithubMatch = alpineCaseContent.match(fetchGithubPattern);

        console.log('Pattern matches:');
        console.log('  - ternaryPattern1 (exact):', ternaryMatch1 ? 'found at ' + ternaryMatch1.index : 'not found');
        console.log('  - ternaryPattern2 (flexible):', ternaryMatch2 ? 'found at ' + ternaryMatch2.index : 'not found');
        console.log('  - extractAlpinefromDocker:', extractMatch ? 'found at ' + extractMatch.index : 'not found');
        console.log('  - return statement:', returnMatch ? 'found at ' + returnMatch.index : 'not found');
        console.log('  - pipe pattern (.pipe(flatmap):', pipeMatch ? 'found at ' + pipeMatch.index : 'not found');
        console.log('  - fetchGithub:', fetchGithubMatch ? 'found at ' + fetchGithubMatch.index : 'not found');

        // Show the actual lines around where we found things
        if (extractMatch) {
          const extractIndex = extractMatch.index;
          const start = Math.max(0, extractIndex - 200);
          const end = Math.min(alpineCaseContent.length, extractIndex + 500);
          console.log('Code around extractAlpinefromDocker:');
          console.log(alpineCaseContent.substring(start, end));
        }
        if (returnMatch) {
          const returnIndex = returnMatch.index;
          const start = Math.max(0, returnIndex - 200);
          const end = Math.min(alpineCaseContent.length, returnIndex + 500);
          console.log('Code around return statement:');
          console.log(alpineCaseContent.substring(start, end));
        }
        if (pipeMatch) {
          const pipeIndex = pipeMatch.index;
          const start = Math.max(0, pipeIndex - 300);
          const end = Math.min(alpineCaseContent.length, pipeIndex + 200);
          console.log('Code around pipe pattern:');
          console.log(alpineCaseContent.substring(start, end));
        }

        let extractStartIndex = -1;
        let useTernary = false;

        if (ternaryMatch1) {
          console.log('Found ternary pattern (exact), will replace entire ternary');
          extractStartIndex = caseAlpineIndex + ternaryMatch1.index;
          useTernary = true;
        } else if (ternaryMatch2) {
          console.log('Found ternary pattern (flexible), will replace entire ternary');
          extractStartIndex = caseAlpineIndex + ternaryMatch2.index;
          useTernary = true;
        } else if (extractMatch) {
          console.log('Found extractAlpinefromDocker call directly');
          extractStartIndex = caseAlpineIndex + extractMatch.index;
        } else if (returnMatch) {
          console.log('Found return statement, checking if it contains nodejs-related code...');
          // Show more context around the return statement
          const returnContext = alpineCaseContent.substring(Math.max(0, returnMatch.index - 100), Math.min(alpineCaseContent.length, returnMatch.index + 500));
          console.log('Context around return statement:');
          console.log(returnContext);

          // Check if the return statement contains nodejs.org or fetchUrls
          if (returnContext.includes('nodejs.org') || returnContext.includes('fetchUrls') || returnContext.includes('fetchGithub')) {
            console.log('Return statement contains nodejs-related code, using it as starting point');
            extractStartIndex = caseAlpineIndex + returnMatch.index;
          } else {
            console.log('ERROR: Return statement found but does not contain nodejs-related code');
            console.log('Full alpine case content:');
            console.log(alpineCaseContent);
            process.exit(1);
          }
        } else {
          console.log('⚠ Could not find any matching pattern in case alpine block');
          console.log('Full alpine case content (first 3000 chars):');
          console.log(alpineCaseContent.substring(0, 3000));
          console.log('Full alpine case content (last 1000 chars):');
          console.log(alpineCaseContent.substring(Math.max(0, alpineCaseContent.length - 1000)));
          console.log('ERROR: Could not find any matching pattern in case alpine block');
          console.log('This suggests the code structure has changed. Please check the actual structure above.');
          process.exit(1);
        }

        // Find the return statement - if we found the ternary pattern, extractStartIndex is already at the return
        let returnStartIndex = extractStartIndex;
        let foundReturn = false;

        if (useTernary) {
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

      set +e  # Don't exit on error, we'll handle it
      node /tmp/fix-nodejs-url-alpine.js > /tmp/fix-nodejs-url-alpine.log 2>&1
      EXIT_CODE=$?
      set -e  # Re-enable exit on error

      if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo "ERROR: Failed to apply gulpfile.reh.js Node.js URL fix for Alpine ARM64!"
        echo "Exit code: ${EXIT_CODE}"
        echo "Script output:"
        cat /tmp/fix-nodejs-url-alpine.log || echo "No log file found"
        rm -f /tmp/fix-nodejs-url-alpine.js /tmp/fix-nodejs-url-alpine.log
        exit 1
      fi

      # Show script output even on success for debugging
      echo "Script output:"
      cat /tmp/fix-nodejs-url-alpine.log 2>/dev/null || echo "No log file found"
      rm -f /tmp/fix-nodejs-url-alpine.js /tmp/fix-nodejs-url-alpine.log

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
