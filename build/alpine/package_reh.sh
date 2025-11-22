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

for i in {1..5}; do # try 5 times
  npm ci && break
  if [[ $i == 3 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/azure-pipelines/distro/mixin-npm

if [[ "${VSCODE_ARCH}" == "x64" ]]; then
  PA_NAME="linux-alpine"
else
  PA_NAME="alpine-arm64"
fi

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building REH"
  
  # CRITICAL FIX: Handle empty glob patterns in gulpfile.reh.js (same fix as main build.sh)
  if [[ -f "build/gulpfile.reh.js" ]]; then
    echo "Applying critical fix to gulpfile.reh.js for empty glob patterns..." >&2
    node << 'REHFIX' || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
try {
  let content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  let modified = false;
  
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('const dependenciesSrc =') && lines[i].includes('.flat()')) {
      if (!lines[i].includes('|| [\'**\', \'!**/*\']')) {
        let newLine = lines[i].replace(/const dependenciesSrc =/, 'let dependenciesSrc =');
        newLine = newLine.replace(/\.flat\(\);?$/, ".flat() || ['**', '!**/*'];");
        lines[i] = newLine;
        const indent = lines[i].match(/^\s*/)[0];
        lines.splice(i + 1, 0, `${indent}if (dependenciesSrc.length === 0) { dependenciesSrc = ['**', '!**/*']; }`);
        modified = true;
        console.error(`✓ Fixed dependenciesSrc at line ${i + 1}`);
      }
      break;
    }
  }
  
  if (modified) {
    content = lines.join('\n');
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully applied REH glob fix');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  process.exit(1);
}
REHFIX
      echo "Warning: Failed to patch gulpfile.reh.js, continuing anyway..." >&2
    }
  fi
  
  # CRITICAL FIX: Patch gulpfile.reh.js to fix Docker ENOBUFS error for Alpine builds
  if [[ -f "build/gulpfile.reh.js" ]]; then
    echo "Patching gulpfile.reh.js for Docker extraction buffer fix..." >&2
    node << 'DOCKERBUFFERFIX' || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched for Docker
if (content.includes('// DOCKER_BUFFER_FIX') || (content.includes('fs.readFileSync') && content.includes('tmpFile'))) {
  console.error('gulpfile.reh.js already patched for Docker buffer fix');
  process.exit(0);
}

// Find extractAlpinefromDocker function and replace execSync with file-based approach
// The error occurs at line 171, so try to find the function around that area
const lines = content.split('\n');
let functionStartLine = -1;
let execSyncLine = -1;

// Find the function start
for (let i = 0; i < lines.length; i++) {
  if (lines[i].includes('function') && lines[i].includes('extractAlpinefromDocker')) {
    functionStartLine = i;
    break;
  }
}

// Find the execSync line (should be around line 171, but search from function start)
if (functionStartLine >= 0) {
  for (let i = functionStartLine; i < Math.min(functionStartLine + 50, lines.length); i++) {
    if (lines[i].includes('execSync') && (lines[i].includes('maxBuffer') || lines[i].includes('cp.execSync'))) {
      execSyncLine = i;
      break;
    }
  }
}

// Try multiple patterns to match the function
let functionPattern = /function\s+extractAlpinefromDocker\([^)]*\)\s*\{[\s\S]*?const\s+contents\s*=\s*cp\.execSync\([^;]+;/;
let match = content.match(functionPattern);

// If not found, try matching with maxBuffer
if (!match) {
  functionPattern = /function\s+extractAlpinefromDocker\([^)]*\)\s*\{[\s\S]*?cp\.execSync\([^)]+maxBuffer[^;]+;/;
  match = content.match(functionPattern);
}

// If still not found, try a more general pattern
if (!match) {
  functionPattern = /function\s+extractAlpinefromDocker\([^)]*\)\s*\{[\s\S]*?\}/;
  match = content.match(functionPattern);
}

if (match || execSyncLine >= 0) {
  let replaced = false;
  
  // If we found the exact line, replace it directly
  if (execSyncLine >= 0) {
    const line = lines[execSyncLine];
    const indent = line.match(/^\s*/)[0];
    
    // Replace the line with file-based approach
    lines[execSyncLine] = `${indent}// DOCKER_BUFFER_FIX: Use file output instead of execSync to avoid ENOBUFS
${indent}const tmpFile = path.join(os.tmpdir(), \`node-\${nodeVersion || 'unknown'}-\${arch || 'unknown'}-\${Date.now()}\`);
${indent}try {
${indent}	cp.execSync(\`docker run --rm \${dockerPlatform || ''} \${imageName || 'node'}:\${nodeVersion || 'unknown'}-alpine /bin/sh -c 'cat \\\`which node\\\`' > \${tmpFile}\`, { stdio: 'inherit' });
${indent}	const contents = fs.readFileSync(tmpFile);
${indent}	fs.unlinkSync(tmpFile);
${indent}	return es.readArray([new File({ path: 'node', contents, stat: { mode: parseInt('755', 8) } })]);
${indent}} catch (err) {
${indent}	if (fs.existsSync(tmpFile)) {
${indent}		fs.unlinkSync(tmpFile);
${indent}	}
${indent}	throw err;
${indent}}`;
    content = lines.join('\n');
    replaced = true;
    console.error(`✓ Replaced execSync at line ${execSyncLine + 1} with file-based approach`);
  } else {
    // Fallback to pattern matching
    const execSyncPatterns = [
      /(\s+)(const\s+contents\s*=\s*cp\.execSync\([^)]+maxBuffer[^)]+\)[^;]+;)/,
      /(\s+)(const\s+contents\s*=\s*cp\.execSync\([^)]+\)[^;]+;)/,
      /(\s+)(cp\.execSync\([^)]+maxBuffer[^)]+\)[^;]+;)/
    ];
    
    for (const pattern of execSyncPatterns) {
      if (pattern.test(content)) {
        content = content.replace(pattern, (match, indent, execLine) => {
          replaced = true;
          return `${indent}// DOCKER_BUFFER_FIX: Use file output instead of execSync to avoid ENOBUFS
${indent}const tmpFile = path.join(os.tmpdir(), \`node-\${nodeVersion || 'unknown'}-\${arch || 'unknown'}-\${Date.now()}\`);
${indent}try {
${indent}	cp.execSync(\`docker run --rm \${dockerPlatform || ''} \${imageName || 'node'}:\${nodeVersion || 'unknown'}-alpine /bin/sh -c 'cat \\\`which node\\\`' > \${tmpFile}\`, { stdio: 'inherit' });
${indent}	const contents = fs.readFileSync(tmpFile);
${indent}	fs.unlinkSync(tmpFile);
${indent}	return es.readArray([new File({ path: 'node', contents, stat: { mode: parseInt('755', 8) } })]);
${indent}} catch (err) {
${indent}	if (fs.existsSync(tmpFile)) {
${indent}		fs.unlinkSync(tmpFile);
${indent}	}
${indent}	throw err;
${indent}}`;
        });
        break;
      }
    }
  }
  
  if (replaced) {
    // Ensure path, os, and fs are imported at the top
    const requires = content.match(/const\s+(cp|os|path|fs)\s*=\s*require\([^)]+\);/g) || [];
    const hasPath = requires.some(r => r.includes('path'));
    const hasOs = requires.some(r => r.includes('os'));
    const hasFs = requires.some(r => r.includes('fs'));
    
    // Find where to add imports (after other requires)
    const requireSection = content.match(/(const\s+\w+\s*=\s*require\([^)]+\);[\s\n]*)+/);
    if (requireSection) {
      let importsToAdd = '';
      if (!hasFs) importsToAdd += "const fs = require('fs');\n";
      if (!hasPath) importsToAdd += "const path = require('path');\n";
      if (!hasOs && !content.includes("const os = require('os')")) importsToAdd += "const os = require('os');\n";
      
      if (importsToAdd) {
        content = content.replace(requireSection[0], requireSection[0] + importsToAdd);
      }
    }
    
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully patched gulpfile.reh.js to use file-based Docker extraction');
  } else {
    // Fallback: just increase buffer significantly
    content = content.replace(
      /maxBuffer:\s*\d+\s*\*\s*1024\s*\*\s*1024/g,
      'maxBuffer: 2000 * 1024 * 1024'
    );
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Increased maxBuffer in gulpfile.reh.js (fallback)');
  }
} else {
  // Fallback: just increase buffer
  content = content.replace(
    /maxBuffer:\s*100\s*\*\s*1024\s*\*\s*1024/g,
    'maxBuffer: 1000 * 1024 * 1024'
  );
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Increased maxBuffer in gulpfile.reh.js (fallback)');
}
DOCKERBUFFERFIX
      echo "Warning: Failed to patch gulpfile.reh.js for Docker buffer fix, continuing anyway..." >&2
    }
  fi
  
  npm run gulp minify-vscode-reh
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
