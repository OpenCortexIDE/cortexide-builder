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
// Look for the specific execSync call that extracts node from Docker
if (functionStartLine >= 0) {
  for (let i = functionStartLine; i < Math.min(functionStartLine + 80, lines.length); i++) {
    // Look for execSync with docker run and which node - this is the one we need to replace
    const line = lines[i];
    if (line.includes('execSync') && line.includes('docker run') && (line.includes('which node') || line.includes('cat'))) {
      execSyncLine = i;
      break;
    }
    // Also check if it's the const contents = cp.execSync line
    if (line.includes('const contents') && line.includes('execSync') && line.includes('docker')) {
      execSyncLine = i;
      break;
    }
  }
  // If not found, look for any execSync with maxBuffer in the function
  if (execSyncLine === -1) {
    for (let i = functionStartLine; i < Math.min(functionStartLine + 80, lines.length); i++) {
      if (lines[i].includes('execSync') && lines[i].includes('maxBuffer')) {
        execSyncLine = i;
        break;
      }
    }
  }
  // Last resort: any execSync in the function
  if (execSyncLine === -1) {
    for (let i = functionStartLine; i < Math.min(functionStartLine + 80, lines.length); i++) {
      if (lines[i].includes('execSync') && lines[i].includes('cp.')) {
        execSyncLine = i;
        break;
      }
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
    
    // Replace the entire execSync block with file-based approach using spawn
    // For ARM64, we need to handle cross-platform with --platform flag
    // Find the full execSync statement (might span multiple lines)
    let execSyncEnd = execSyncLine;
    for (let i = execSyncLine; i < Math.min(execSyncLine + 5, lines.length); i++) {
      if (lines[i].includes(';') || (lines[i].includes(')') && !lines[i].includes('('))) {
        execSyncEnd = i;
        break;
      }
    }
    
    // Replace the execSync line(s) with our fix
    // Fix ARM64 image name - check if imageName already has arm64v8/ prefix
    const replacement = `${indent}// DOCKER_BUFFER_FIX: Use file output instead of execSync to avoid ENOBUFS
${indent}const tmpFile = path.join(os.tmpdir(), \`node-\${nodeVersion || 'unknown'}-\${arch || 'unknown'}-\${Date.now()}\`);
${indent}try {
${indent}	// Use spawn with file redirection to avoid ENOBUFS
${indent}	const { spawnSync } = require('child_process');
${indent}	// For ARM64 on non-ARM64 host, use --platform flag
${indent}	const platformFlag = (arch === 'arm64' && process.platform !== 'darwin') ? '--platform linux/arm64 ' : '';
${indent}	// Fix image name - only add arm64v8/ if imageName doesn't already have it and dockerPlatform is not set
${indent}	let finalImageName = imageName || 'node';
${indent}	if (arch === 'arm64' && !dockerPlatform && !finalImageName.includes('arm64v8/') && !finalImageName.includes('/')) {
${indent}		finalImageName = 'arm64v8/' + finalImageName;
${indent}	}
${indent}	const dockerCmd = \`docker run --rm \${platformFlag}\${dockerPlatform || ''}\${finalImageName}:\${nodeVersion || 'unknown'}-alpine /bin/sh -c 'cat \\\`which node\\\`'\`;
${indent}	const result = spawnSync('sh', ['-c', \`\${dockerCmd} > \${tmpFile}\`], { stdio: 'inherit' });
${indent}	if (result.error || result.status !== 0) {
${indent}		throw result.error || new Error(\`Docker command failed with status \${result.status}\`);
${indent}	}
${indent}	const contents = fs.readFileSync(tmpFile);
${indent}	fs.unlinkSync(tmpFile);
${indent}	return es.readArray([new File({ path: 'node', contents, stat: { mode: parseInt('755', 8) } })]);
${indent}} catch (err) {
${indent}	if (fs.existsSync(tmpFile)) {
${indent}		fs.unlinkSync(tmpFile);
${indent}	}
${indent}	throw err;
${indent}}`;
    
    // Replace the execSync line(s)
    lines.splice(execSyncLine, execSyncEnd - execSyncLine + 1, replacement);
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
${indent}	// Use spawn with file redirection to avoid ENOBUFS
${indent}	const { spawnSync } = require('child_process');
${indent}	// For ARM64 on non-ARM64 host, use --platform flag
${indent}	const platformFlag = (arch === 'arm64' && process.platform !== 'darwin') ? '--platform linux/arm64 ' : '';
${indent}	// Fix image name - only add arm64v8/ if imageName doesn't already have it and dockerPlatform is not set
${indent}	let finalImageName = imageName || 'node';
${indent}	if (arch === 'arm64' && !dockerPlatform && !finalImageName.includes('arm64v8/') && !finalImageName.includes('/')) {
${indent}		finalImageName = 'arm64v8/' + finalImageName;
${indent}	}
${indent}	const dockerCmd = \`docker run --rm \${platformFlag}\${dockerPlatform || ''}\${finalImageName}:\${nodeVersion || 'unknown'}-alpine /bin/sh -c 'cat \\\`which node\\\`'\`;
${indent}	const result = spawnSync('sh', ['-c', \`\${dockerCmd} > \${tmpFile}\`], { stdio: 'inherit' });
${indent}	if (result.error || result.status !== 0) {
${indent}		throw result.error || new Error(\`Docker command failed with status \${result.status}\`);
${indent}	}
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
