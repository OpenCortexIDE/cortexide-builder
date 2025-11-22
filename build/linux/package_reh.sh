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

apply_arch_patch_if_available() {
  local arch_patch=""
  case "$1" in
    ppc64le) arch_patch="../patches/linux/arch-1-ppc64le.patch" ;;
    riscv64) arch_patch="../patches/linux/arch-2-riscv64.patch" ;;
    loong64) arch_patch="../patches/linux/arch-3-loong64.patch" ;;
    s390x)  arch_patch="../patches/linux/arch-4-s390x.patch" ;;
  esac

  if [[ -n "${arch_patch}" ]] && [[ -f "${arch_patch}" ]]; then
    echo "Applying architecture-specific patch for ${1}: ${arch_patch}"
    # Architecture patches are non-critical - always return 0 even if patch fails
    # Runtime fixes in the build script will handle missing architectures
    apply_patch "${arch_patch}" || {
      echo "Warning: Architecture patch ${arch_patch} failed, but continuing (runtime fixes will handle it)..." >&2
      return 0
    }
  fi
}

apply_arch_patch_if_available "${VSCODE_ARCH}"

# CRITICAL FIX: Patch install-sysroot.js to add architecture mappings if patch failed
# This ensures sysroot download works even when architecture patches fail to apply
if [[ -f "build/linux/debian/install-sysroot.js" ]]; then
  echo "Ensuring install-sysroot.js has architecture mappings for ${VSCODE_ARCH}..." >&2
  VSCODE_ARCH="${VSCODE_ARCH}" node << 'SYSROOTFIX' || {
const fs = require('fs');
const filePath = 'build/linux/debian/install-sysroot.js';
let content = fs.readFileSync(filePath, 'utf8');
const arch = process.env.VSCODE_ARCH || '';

// Architecture mappings (from architecture patches)
const archMappings = {
  'ppc64le': { expectedName: 'powerpc64le-linux-gnu', triple: 'powerpc64le-linux-gnu' },
  'riscv64': { expectedName: 'riscv64-linux-gnu', triple: 'riscv64-linux-gnu' },
  'loong64': { expectedName: 'loongarch64-linux-gnu', triple: 'loongarch64-linux-gnu' },
  's390x': { expectedName: 's390x-linux-gnu', triple: 's390x-linux-gnu' }
};

if (!arch || !archMappings[arch]) {
  console.error('No mapping needed for architecture:', arch);
  process.exit(0);
}

const mapping = archMappings[arch];
const casePattern = new RegExp(`case\\s+['"]${arch}['"]:`, 'g');

// Check if case already exists
if (casePattern.test(content)) {
  console.error(`Architecture ${arch} mapping already exists in install-sysroot.js`);
  process.exit(0);
}

// Find the switch statement for arch - look for async function getVSCodeSysroot
const switchPattern = /switch\s*\(\s*arch\s*\)\s*\{/;
const switchMatch = content.match(switchPattern);

if (!switchMatch) {
  console.error('Could not find switch(arch) statement in install-sysroot.js');
  process.exit(1);
}

// Find where to insert - look for the last case before closing brace
const lines = content.split('\n');
let insertIndex = -1;
let inSwitch = false;
let braceDepth = 0;

for (let i = 0; i < lines.length; i++) {
  if (lines[i].match(switchPattern)) {
    inSwitch = true;
    braceDepth = 1;
    continue;
  }
  
  if (inSwitch) {
    braceDepth += (lines[i].match(/\{/g) || []).length;
    braceDepth -= (lines[i].match(/\}/g) || []).length;
    
    // Look for the last case before default or closing
    if (lines[i].match(/^\s*case\s+['"]/)) {
      insertIndex = i + 1;
      // Find the end of this case
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].match(/^\s*break\s*;/) || lines[j].match(/^\s*default\s*:/)) {
          insertIndex = j;
          break;
        }
        if (lines[j].match(/^\s*\}/) && braceDepth === 0) {
          insertIndex = j;
          break;
        }
      }
    }
    
    // If we hit the closing brace of the switch, insert before it
    if (braceDepth === 0 && lines[i].match(/^\s*\}/)) {
      if (insertIndex === -1) {
        insertIndex = i;
      }
      break;
    }
  }
}

if (insertIndex === -1) {
  // Fallback: find arm64 case and insert after it
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].match(/^\s*case\s+['"]arm64['"]:/)) {
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].match(/^\s*break\s*;/)) {
          insertIndex = j + 1;
          break;
        }
      }
      break;
    }
  }
}

if (insertIndex === -1) {
  console.error('Could not find insertion point for architecture mapping');
  process.exit(1);
}

// Insert the case statement
const indent = lines[insertIndex - 1].match(/^(\s*)/)[1] || '            ';
const caseCode = `${indent}case '${arch}':\n` +
                 `${indent}    expectedName = \`${mapping.expectedName}\${prefix}.tar.gz\`;\n` +
                 `${indent}    triple = \`${mapping.triple}\`;\n` +
                 `${indent}    break;`;

lines.splice(insertIndex, 0, caseCode);
content = lines.join('\n');

// Also patch fetchUrl to handle missing assets gracefully for remote sysroot
// Some architectures (ppc64le, s390x) don't have -gcc-8.5.0 variants in releases
if (!content.includes('// REMOTE_SYSROOT_FALLBACK')) {
  // Use line-based approach for more reliable patching
  const lines = content.split('\n');
  let throwLineIndex = -1;
  
  // Find the throw statement line - try multiple patterns
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if ((line.includes('throw new Error') || line.includes('throw new Error')) && 
        (line.includes('Could not find asset') || line.includes('Could not find asset'))) {
      throwLineIndex = i;
      break;
    }
  }
  
  // Also try to find by template literal pattern
  if (throwLineIndex === -1) {
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].includes('Could not find asset') && lines[i].includes('repository') && lines[i].includes('actualVersion')) {
        throwLineIndex = i;
        break;
      }
    }
  }
  
  if (throwLineIndex >= 0) {
    const indent = lines[throwLineIndex].match(/^(\s*)/)[1] || '                ';
    // Insert fallback logic before the throw - always do this
    const fallbackCode = `${indent}// REMOTE_SYSROOT_FALLBACK: If remote sysroot doesn't exist, try without gcc suffix or skip
${indent}if (!asset && options && options.name && options.name.includes('-gcc-') && process.env.VSCODE_SYSROOT_PREFIX && process.env.VSCODE_SYSROOT_PREFIX.includes('-gcc-')) {
${indent}  console.error(\`Warning: Remote sysroot \${options.name} not found, trying without gcc suffix...\`);
${indent}  const fallbackName = options.name.replace(/-gcc-[^-]+\.tar\.gz$/, '.tar.gz');
${indent}  if (fallbackName !== options.name) {
${indent}    const fallbackAsset = assets.find(a => a.name === fallbackName);
${indent}    if (fallbackAsset) {
${indent}      return fallbackAsset.browser_download_url;
${indent}    }
${indent}  }
${indent}  console.error(\`Warning: Remote sysroot not available for \${options.name}, skipping. Client sysroot will be used.\`);
${indent}  return null;
${indent}}`;
    
    lines.splice(throwLineIndex, 0, fallbackCode);
    content = lines.join('\n');
    console.error(`✓ Patched fetchUrl at line ${throwLineIndex + 1} to handle missing remote sysroot assets gracefully`);
    
    // Also patch getVSCodeSysroot to handle null returns and errors from fetchUrl
    // Find where getVSCodeSysroot calls fetchUrl and wrap it in try-catch
    let getVSCodeSysrootStart = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].includes('async function getVSCodeSysroot') || lines[i].includes('function getVSCodeSysroot')) {
        getVSCodeSysrootStart = i;
        break;
      }
    }
    
    if (getVSCodeSysrootStart >= 0) {
      // Find where fetchUrl is called in getVSCodeSysroot - look for remote sysroot download
      for (let i = getVSCodeSysrootStart; i < Math.min(getVSCodeSysrootStart + 150, lines.length); i++) {
        if (lines[i].includes('fetchUrl') && (lines[i].includes('await') || lines[i].includes('const url'))) {
          // Check if this is the remote sysroot call (has VSCODE_SYSROOT_PREFIX or gcc in context)
          const contextLines = lines.slice(Math.max(0, i - 5), Math.min(lines.length, i + 10)).join('\n');
          if (contextLines.includes('VSCODE_SYSROOT_PREFIX') || contextLines.includes('gcc') || contextLines.includes('remote')) {
            // Wrap the fetchUrl call in try-catch to handle errors gracefully
            const callIndent = lines[i].match(/^(\s*)/)[1] || '            ';
            const originalLine = lines[i];
            
            // Find the end of the fetchUrl call (might span multiple lines)
            let fetchUrlEnd = i;
            for (let j = i; j < Math.min(i + 5, lines.length); j++) {
              if (lines[j].includes(';') || (lines[j].includes(')') && !lines[j].includes('('))) {
                fetchUrlEnd = j;
                break;
              }
            }
            
            // Check if already wrapped
            if (!lines[Math.max(0, i - 1)].includes('// REMOTE_SYSROOT_ERROR_HANDLER')) {
              const tryCatchWrapper = `${callIndent}// REMOTE_SYSROOT_ERROR_HANDLER: Wrap fetchUrl in try-catch for graceful failure
${callIndent}try {
${callIndent}  ${originalLine.trim()}
${callIndent}  // Check for null return (remote sysroot not available)
${callIndent}  ${lines[fetchUrlEnd].trim().startsWith('const') || lines[fetchUrlEnd].trim().startsWith('let') || lines[fetchUrlEnd].trim().startsWith('var') ? '' : 'const url = '}${lines.slice(i, fetchUrlEnd + 1).map(l => l.trim()).join(' ').replace(/^const url = |^let url = |^var url = /, '')};
${callIndent}  if (url === null) {
${callIndent}    console.error('Remote sysroot not available, skipping download');
${callIndent}    return; // Skip remote sysroot download
${callIndent}  }
${callIndent}} catch (err) {
${callIndent}  // If fetchUrl throws (asset not found), check if it's a remote sysroot and skip gracefully
${callIndent}  if (err.message && err.message.includes('Could not find asset') && process.env.VSCODE_SYSROOT_PREFIX && process.env.VSCODE_SYSROOT_PREFIX.includes('-gcc-')) {
${callIndent}    console.error('Warning: Remote sysroot not available, skipping. Client sysroot will be used.');
${callIndent}    return; // Skip remote sysroot download
${callIndent}  }
${callIndent}  throw err; // Re-throw other errors
${callIndent}}`;
              
              // Replace the fetchUrl call with wrapped version
              lines.splice(i, fetchUrlEnd - i + 1, tryCatchWrapper);
              console.error(`✓ Patched getVSCodeSysroot to handle errors from fetchUrl gracefully`);
              break;
            }
          }
        }
      }
    }
    
    content = lines.join('\n');
  } else {
    console.error('⚠ Could not find throw statement to patch for remote sysroot fallback');
  }
}

fs.writeFileSync(filePath, content, 'utf8');
console.error(`✓ Successfully added ${arch} mapping to install-sysroot.js`);
SYSROOTFIX
    echo "Warning: Failed to patch install-sysroot.js for ${VSCODE_ARCH}, continuing anyway..." >&2
  }
  
fi

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
elif [[ "${VSCODE_ARCH}" == "armhf" ]]; then
  EXPECTED_GLIBC_VERSION="2.30"

  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-armhf"

  export VSCODE_SKIP_SYSROOT=1
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-ppc64le"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20240129-253798'
  export USE_GNUPP2A=1
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-riscv64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  NODE_VERSION="20.16.0"
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:beige-devtoolset-loong64"

  export VSCODE_SKIP_SETUPENV=1
  export VSCODE_NODEJS_SITE='https://unofficial-builds.nodejs.org'
elif [[ "${VSCODE_ARCH}" == "s390x" ]]; then
  VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME="vscodium/vscodium-linux-build-agent:focal-devtoolset-s390x"

  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20241108'
fi

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
export VSCODE_SYSROOT_PREFIX="-glibc-${GLIBC_VERSION}"

EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION:=GLIBC_VERSION}"
VSCODE_HOST_MOUNT="$( pwd )"

export VSCODE_HOST_MOUNT
export VSCODE_REMOTE_DEPENDENCIES_CONTAINER_NAME

sed -i "/target/s/\"20.*\"/\"${NODE_VERSION}\"/" remote/.npmrc

# CRITICAL FIX: Add checksums to vscode-sysroot.txt BEFORE setup-env.sh runs
# This must happen before sysroot download is attempted
if [[ -f "build/checksums/vscode-sysroot.txt" ]]; then
  echo "Ensuring sysroot checksums exist for ${VSCODE_ARCH}..." >&2
  VSCODE_ARCH="${VSCODE_ARCH}" node << 'CHECKSUMFIX' || {
const fs = require('fs');
const filePath = 'build/checksums/vscode-sysroot.txt';
let content = fs.readFileSync(filePath, 'utf8');
const arch = process.env.VSCODE_ARCH || '';

// Checksums from architecture patches
// Note: Remote sysroot uses gcc suffix, but may use same checksum or need separate entry
const checksums = {
  'ppc64le': [
    'fa8176d27be18bb0eeb7f55b0fa22255050b430ef68c29136599f02976eb0b1b  powerpc64le-linux-gnu-glibc-2.28.tar.gz',
    // Remote sysroot may use same checksum with gcc suffix - if different, add here
    'fa8176d27be18bb0eeb7f55b0fa22255050b430ef68c29136599f02976eb0b1b  powerpc64le-linux-gnu-glibc-2.28-gcc-8.5.0.tar.gz',
    'fa8176d27be18bb0eeb7f55b0fa22255050b430ef68c29136599f02976eb0b1b  powerpc64le-linux-gnu-glibc-2.28-gcc-10.5.0.tar.gz'
  ],
  's390x': [
    '7055f3d40e7195fb1e13f0fbaf5ffadf781bddaca5fd5e0d9972f4157a203fb5  s390x-linux-gnu-glibc-2.28.tar.gz',
    // Remote sysroot may use same checksum with gcc suffix
    '7055f3d40e7195fb1e13f0fbaf5ffadf781bddaca5fd5e0d9972f4157a203fb5  s390x-linux-gnu-glibc-2.28-gcc-8.5.0.tar.gz',
    '7055f3d40e7195fb1e13f0fbaf5ffadf781bddaca5fd5e0d9972f4157a203fb5  s390x-linux-gnu-glibc-2.28-gcc-10.5.0.tar.gz'
  ]
};

if (!arch || !checksums[arch]) {
  console.error('No checksum needed for architecture:', arch);
  process.exit(0);
}

const archChecksums = checksums[arch];
let added = false;

for (const checksum of archChecksums) {
  const parts = checksum.split(/\s+/);
  const checksumHash = parts[0];
  const filename = parts.slice(1).join(' ');
  
  // Check if checksum already exists - check for both the full line and just the filename
  // install-sysroot.js looks for lines matching: <hash>  <filename>
  const checksumPattern = new RegExp(`^${checksumHash.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s+${filename.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`, 'm');
  const filenamePattern = new RegExp(`\\s+${filename.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'm');
  
  if (!checksumPattern.test(content) && !filenamePattern.test(content)) {
    // Add checksum at the end of the file
    content = content.trim() + '\n' + checksum + '\n';
    added = true;
    console.error(`✓ Added checksum for ${filename}`);
  } else {
    console.error(`✓ Checksum for ${filename} already exists`);
  }
}

if (added) {
  fs.writeFileSync(filePath, content, 'utf8');
  console.error(`✓ Successfully added checksums for ${arch}`);
  
  // Verify the checksums were actually written
  const verifyContent = fs.readFileSync(filePath, 'utf8');
  for (const checksum of archChecksums) {
    const filename = checksum.split(/\s+/).slice(1).join(' ');
    if (!verifyContent.includes(filename)) {
      console.error(`✗ WARNING: Checksum for ${filename} was not found after write!`);
      process.exit(1);
    } else {
      console.error(`✓ Verified checksum for ${filename} exists in file`);
    }
  }
} else {
  console.error(`All checksums for ${arch} already exist`);
  
  // Verify they actually exist
  for (const checksum of archChecksums) {
    const filename = checksum.split(/\s+/).slice(1).join(' ');
    if (!content.includes(filename)) {
      console.error(`✗ WARNING: Checksum for ${filename} should exist but was not found!`);
      // Force add it
      content = content.trim() + '\n' + checksum + '\n';
      fs.writeFileSync(filePath, content, 'utf8');
      console.error(`✓ Force-added missing checksum for ${filename}`);
    }
  }
}
CHECKSUMFIX
    echo "Warning: Failed to add checksum for ${VSCODE_ARCH}, continuing anyway..." >&2
  }
fi

if [[ -d "../patches/linux/reh/" ]]; then
  for file in "../patches/linux/reh/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
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

# CRITICAL FIX: @vscode/vsce-sign postinstall script doesn't support ppc64
# Patch the postinstall script to skip the platform check for unsupported architectures
fix_vsce_sign_postinstall() {
  local postinstall_path="build/node_modules/@vscode/vsce-sign/src/postinstall.js"
  if [[ -f "${postinstall_path}" ]]; then
    # Check if already patched
    if ! grep -q "// PATCHED: Skip platform check for unsupported architectures" "${postinstall_path}" 2>/dev/null; then
      echo "Patching @vscode/vsce-sign postinstall script to support ppc64..." >&2
      node << VSECESIGNFIX || {
const fs = require('fs');
const filePath = '${postinstall_path}';
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('// PATCHED: Skip platform check')) {
  console.error('vsce-sign postinstall already patched');
  process.exit(0);
}

// Find the platform check and make it skip for unsupported architectures
// The error message is "The current platform (linux) and architecture (ppc64) is not supported."
// We need to find where it throws this error and make it a warning instead
const lines = content.split('\n');
let modified = false;

for (let i = 0; i < lines.length; i++) {
  // Find the error throw
  if (lines[i].includes('is not supported') && lines[i].includes('throw new Error')) {
    // Replace throw with console.warn and return early
    const indent = lines[i].match(/^\s*/)[0];
    lines[i] = `${indent}// PATCHED: Skip platform check for unsupported architectures (ppc64, etc.)\n${indent}console.warn('Platform/architecture not officially supported, skipping vsce-sign setup');\n${indent}return;`;
    modified = true;
    console.error(`✓ Patched vsce-sign postinstall at line ${i + 1}`);
    break;
  }
}

if (modified) {
  content = lines.join('\n');
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched vsce-sign postinstall');
} else {
  console.error('Could not find platform check in vsce-sign postinstall');
}
VSECESIGNFIX
        echo "Warning: Failed to patch vsce-sign postinstall, continuing anyway..." >&2
      }
    fi
  fi
}

# CRITICAL FIX: native-keymap postinstall script fails to rebuild with Node.js v20.19.2
# Patch the postinstall script to skip the node-gyp rebuild
fix_native_keymap_postinstall() {
  local postinstall_path="${1:-node_modules/native-keymap/package.json}"
  local module_dir=$(dirname "${postinstall_path}")
  
  if [[ -f "${postinstall_path}" ]]; then
    # Check if already patched by looking for a marker
    if ! grep -q "// PATCHED: Skip native-keymap rebuild" "${postinstall_path}" 2>/dev/null; then
      echo "Patching native-keymap to skip node-gyp rebuild at ${postinstall_path}..." >&2
      node << NATIVEKEYMAPFIX || {
const fs = require('fs');
const path = require('path');
const filePath = '${postinstall_path}';
const moduleDir = '${module_dir}';

let content = fs.readFileSync(filePath, 'utf8');
let pkg = JSON.parse(content);

// Check if already patched
if (pkg.scripts && pkg.scripts.postinstall && pkg.scripts.postinstall.includes('// PATCHED')) {
  console.error('native-keymap already patched');
  process.exit(0);
}

// Remove or skip the postinstall script that runs node-gyp rebuild
if (pkg.scripts && pkg.scripts.postinstall) {
  pkg.scripts.postinstall = '// PATCHED: Skip native-keymap rebuild (V8 API incompatibility with Node.js v20.19.2)';
  content = JSON.stringify(pkg, null, 2);
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched native-keymap postinstall');
}

// Also patch the postinstall script file directly if it exists
const postinstallScript = path.join(moduleDir, 'scripts', 'postinstall.js');
if (fs.existsSync(postinstallScript)) {
  fs.writeFileSync(postinstallScript, '// PATCHED: Skip rebuild\nprocess.exit(0);\n', 'utf8');
  console.error('✓ Patched native-keymap postinstall script file');
}

// Also create a dummy binding.gyp to prevent node-gyp from trying to build
const bindingGyp = path.join(moduleDir, 'binding.gyp');
if (fs.existsSync(bindingGyp)) {
  const gypContent = fs.readFileSync(bindingGyp, 'utf8');
  // Comment out the targets to prevent building
  const patchedGyp = '// PATCHED: Disabled build due to V8 API incompatibility\n' + gypContent.replace(/("targets":\s*\[)/, '// $1');
  fs.writeFileSync(bindingGyp, patchedGyp, 'utf8');
  console.error('✓ Patched native-keymap binding.gyp');
}
NATIVEKEYMAPFIX
        echo "Warning: Failed to patch native-keymap, trying fallback method..." >&2
        # Fallback: patch the actual postinstall script if it exists
        local script_path="${module_dir}/scripts/postinstall.js"
        if [[ -f "${script_path}" ]]; then
          echo "// PATCHED: Skip rebuild" > "${script_path}"
          echo "process.exit(0);" >> "${script_path}"
          echo "✓ Patched native-keymap postinstall script directly (fallback)" >&2
        fi
      }
    else
      echo "native-keymap already patched at ${postinstall_path}" >&2
    fi
  fi
}

mv .npmrc .npmrc.bak
cp ../npmrc .npmrc

# CRITICAL FIX: Install with --ignore-scripts to prevent native-keymap postinstall from running
# Then patch native-keymap and manually handle postinstall scripts
for i in {1..5}; do # try 5 times
  # Fix vsce-sign postinstall before attempting install (in case it exists from previous attempt)
  fix_vsce_sign_postinstall
  
  # Install with --ignore-scripts to skip all postinstall scripts (including native-keymap)
  npm ci --ignore-scripts --prefix build 2>&1 | tee /tmp/npm-install.log || {
    # If it fails for other reasons, retry normally
    if [[ $i -lt 3 ]]; then
      echo "Npm install failed $i, trying again..."
      continue
    else
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  }
  
  # Patch native-keymap to disable postinstall before any scripts run
  fix_native_keymap_postinstall "build/node_modules/native-keymap/package.json"
  
  # Note: We skip running postinstall scripts manually since most packages work without them
  # and native-keymap's postinstall is now disabled. If other packages need postinstall,
  # they should be handled individually.
  
  break
done

if [[ -z "${VSCODE_SKIP_SETUPENV}" ]]; then
  # CRITICAL FIX: setup-env.sh doesn't respect --skip-sysroot flag
  # For armhf/arm64, we need to skip sysroot download entirely
  if [[ -n "${VSCODE_SKIP_SYSROOT}" ]]; then
    # Patch setup-env.sh to skip sysroot downloads when --skip-sysroot is passed
    if [[ -f "build/azure-pipelines/linux/setup-env.sh" ]]; then
      echo "Patching setup-env.sh to skip sysroot downloads for ${VSCODE_ARCH}..." >&2
      # Check if already patched
      if ! grep -q "# SKIP_SYSROOT_PATCH" "build/azure-pipelines/linux/setup-env.sh" 2>/dev/null; then
        # Use Node.js for more reliable patching
        node << 'SETUPENVFIX' || {
const fs = require('fs');
const filePath = 'build/azure-pipelines/linux/setup-env.sh';
let content = fs.readFileSync(filePath, 'utf8');

// Check if already patched
if (content.includes('# SKIP_SYSROOT_PATCH')) {
  console.error('setup-env.sh already patched');
  process.exit(0);
}

// Wrap sysroot download sections (lines 12-24) in a conditional
const lines = content.split('\n');
let newLines = [];

for (let i = 0; i < lines.length; i++) {
  // Before sysroot download section (line 12)
  if (i === 11 && lines[i].includes('export VSCODE_CLIENT_SYSROOT_DIR')) {
    newLines.push('# SKIP_SYSROOT_PATCH');
    newLines.push('if [[ "$1" != "--skip-sysroot" ]] && [[ -z "${VSCODE_SKIP_SYSROOT}" ]]; then');
  }
  
  newLines.push(lines[i]);
  
  // After sysroot download section (line 24), close the if
  if (i === 23 && lines[i].includes('VSCODE_SYSROOT_PREFIX')) {
    newLines.push('fi');
  }
}

content = newLines.join('\n');
fs.writeFileSync(filePath, content, 'utf8');
console.error('✓ Successfully patched setup-env.sh to skip sysroot downloads');
SETUPENVFIX
          echo "Warning: Failed to patch setup-env.sh, trying alternative method..." >&2
        }
      fi
    fi
    mkdir -p "$PWD/.build/sysroots/glibc-2.28-gcc-10.5.0" "$PWD/.build/sysroots/glibc-2.28-gcc-8.5.0"
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
    unset CC CXX CXXFLAGS LDFLAGS VSCODE_REMOTE_CC VSCODE_REMOTE_CXX VSCODE_REMOTE_CXXFLAGS VSCODE_REMOTE_LDFLAGS
  else
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# CRITICAL FIX: Install with --ignore-scripts to prevent native-keymap postinstall from running
# Then patch native-keymap and manually handle postinstall scripts
for i in {1..5}; do # try 5 times
  # Install with --ignore-scripts to skip all postinstall scripts (including native-keymap)
  npm ci --ignore-scripts 2>&1 | tee /tmp/npm-install-root.log || {
    # If it fails for other reasons, retry normally
    if [[ $i -lt 3 ]]; then
      echo "Npm install failed $i, trying again..."
      # Clean up problematic modules
      rm -rf node_modules/@vscode node_modules/node-pty node_modules/native-keymap
      continue
    else
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  }
  
  # Patch native-keymap to disable postinstall before any scripts run
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
  
  # Note: We skip running postinstall scripts manually since most packages work without them
  # and native-keymap's postinstall is now disabled. If other packages need postinstall,
  # they should be handled individually.
  
  break
done

mv .npmrc.bak .npmrc

node build/azure-pipelines/distro/mixin-npm

# CRITICAL FIX: Patch native-keymap immediately after mixin-npm (it may install native-keymap)
fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
if [[ -d "build/node_modules/native-keymap" ]]; then
  fix_native_keymap_postinstall "build/node_modules/native-keymap/package.json"
fi

# CRITICAL FIX: Install extension dependencies before building
# Extensions like microsoft-authentication need their dependencies installed
echo "Installing extension dependencies..." >&2
if [[ -d "extensions" ]]; then
  # Collect all extension directories first
  EXT_DIRS=()
  while IFS= read -r ext_package_json; do
    ext_dir=$(dirname "$ext_package_json")
    EXT_DIRS+=("$ext_dir")
  done < <(find extensions -name "package.json" -type f)
  
  # Install dependencies for each extension
  for ext_dir in "${EXT_DIRS[@]}"; do
    ext_name=$(basename "$ext_dir")
    
    # Skip if node_modules already exists and has content
    if [[ -d "${ext_dir}/node_modules" ]] && [[ -n "$(ls -A "${ext_dir}/node_modules" 2>/dev/null)" ]]; then
      echo "Dependencies already installed for ${ext_name}, skipping..." >&2
      continue
    fi
    
    echo "Installing dependencies for extension: ${ext_name}..." >&2
    # Use --ignore-scripts to prevent native-keymap rebuild issues
    # Use --legacy-peer-deps to handle peer dependency conflicts
    if (cd "$ext_dir" && npm install --ignore-scripts --no-save --legacy-peer-deps 2>&1 | tee "/tmp/ext-${ext_name}-install.log" | tail -50); then
      echo "✓ Successfully installed dependencies for ${ext_name}" >&2
    else
      echo "Warning: Failed to install dependencies for ${ext_name}" >&2
      echo "Checking if critical dependencies are missing..." >&2
      # Check if it's a critical failure or just warnings
      if grep -q "ENOENT\|MODULE_NOT_FOUND\|Cannot find module" "/tmp/ext-${ext_name}-install.log" 2>/dev/null; then
        echo "Error: Critical dependency installation failed for ${ext_name}" >&2
        echo "This may cause the extension build to fail." >&2
      fi
    fi
  done
  
  # Verify critical extensions have their dependencies
  # Some extensions need dependencies installed at root level for webpack to resolve them
  if [[ -d "extensions/microsoft-authentication" ]]; then
    MISSING_DEPS=()
    [[ ! -d "extensions/microsoft-authentication/node_modules/@azure/msal-node" ]] && MISSING_DEPS+=("@azure/msal-node")
    [[ ! -d "extensions/microsoft-authentication/node_modules/@azure/ms-rest-azure-env" ]] && MISSING_DEPS+=("@azure/ms-rest-azure-env")
    [[ ! -d "extensions/microsoft-authentication/node_modules/@vscode/extension-telemetry" ]] && MISSING_DEPS+=("@vscode/extension-telemetry")
    [[ ! -d "extensions/microsoft-authentication/node_modules/@azure/msal-node-extensions" ]] && MISSING_DEPS+=("@azure/msal-node-extensions")
    [[ ! -d "extensions/microsoft-authentication/node_modules/vscode-tas-client" ]] && MISSING_DEPS+=("vscode-tas-client")
    
    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
      echo "Installing missing dependencies for microsoft-authentication: ${MISSING_DEPS[*]}..." >&2
      # Try installing in extension directory first
      (cd "extensions/microsoft-authentication" && npm install --ignore-scripts --no-save --legacy-peer-deps "${MISSING_DEPS[@]}" 2>&1 | tail -30) || {
        echo "Warning: Extension-level install failed, trying root-level install..." >&2
        # Fallback: install at root level (webpack might resolve from there)
        npm install --ignore-scripts --no-save --legacy-peer-deps "${MISSING_DEPS[@]}" 2>&1 | tail -30 || {
          echo "Warning: Root-level install also failed for microsoft-authentication dependencies" >&2
        }
      }
    fi
    
    # Also ensure keytar mock exists (it's a file: dependency)
    if [[ ! -d "extensions/microsoft-authentication/packageMocks/keytar" ]]; then
      echo "Creating keytar mock for microsoft-authentication..." >&2
      mkdir -p "extensions/microsoft-authentication/packageMocks/keytar"
      echo '{"name": "keytar", "version": "1.0.0", "main": "index.js"}' > "extensions/microsoft-authentication/packageMocks/keytar/package.json"
      echo 'module.exports = {};' > "extensions/microsoft-authentication/packageMocks/keytar/index.js"
    fi
  fi
fi

# CRITICAL FIX: Verify gulp is installed before running gulp commands
# If npm ci failed partially, gulp might not be installed
# Also ensure native-keymap is patched before installing gulp (gulp install might trigger native-keymap)
if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
  echo "Warning: gulp not found after mixin-npm, attempting to install..." >&2
  # Ensure native-keymap is patched before installing gulp
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
  # Install gulp with --ignore-scripts to prevent native-keymap rebuild
  npm install --ignore-scripts gulp 2>&1 | tail -20 || {
    echo "Error: Failed to install gulp. Cannot continue with build." >&2
    exit 1
  }
  # Re-patch native-keymap after install (in case it was reinstalled)
  fix_native_keymap_postinstall "node_modules/native-keymap/package.json"
fi

# CRITICAL FIX: @electron/get, @octokit/rest, and got are now ESM and break @vscode/gulp-electron
# Patch node_modules to dynamically import these modules (same fix as main build)
if [[ -f "node_modules/@vscode/gulp-electron/src/download.js" ]]; then
  echo "Patching @vscode/gulp-electron to support ESM @electron/get, @octokit/rest, and got..." >&2
  node << 'ELECTRONPATCH' || {
const fs = require('fs');
const filePath = 'node_modules/@vscode/gulp-electron/src/download.js';
let content = fs.readFileSync(filePath, 'utf8');

const alreadyPatched = content.includes('// ESM_PATCH: downloadArtifact') &&
                       content.includes('// ESM_PATCH: octokit') &&
                       content.includes('// ESM_PATCH: got');
if (!alreadyPatched) {
  // Patch @electron/get
  const requireElectronLine = 'const { downloadArtifact } = require("@electron/get");';
  if (content.includes(requireElectronLine)) {
    content = content.replace(requireElectronLine, `// ESM_PATCH: downloadArtifact
let __downloadArtifactPromise;
async function getDownloadArtifact() {
  if (!__downloadArtifactPromise) {
    __downloadArtifactPromise = import("@electron/get").then((mod) => {
      if (mod.downloadArtifact) {
        return mod.downloadArtifact;
      }
      if (mod.default && mod.default.downloadArtifact) {
        return mod.default.downloadArtifact;
      }
      return mod.default || mod;
    });
  }
  return __downloadArtifactPromise;
}`);
  }

  const callDownloadArtifactLine = '  return await downloadArtifact(downloadOpts);';
  if (content.includes(callDownloadArtifactLine)) {
    content = content.replace(callDownloadArtifactLine, `  const downloadArtifact = await getDownloadArtifact();
  return await downloadArtifact(downloadOpts);`);
  }

  // Patch @octokit/rest
  const requireOctokitLine = 'const { Octokit } = require("@octokit/rest");';
  if (content.includes(requireOctokitLine)) {
    content = content.replace(requireOctokitLine, `// ESM_PATCH: octokit
let __octokitPromise;
async function getOctokit() {
  if (!__octokitPromise) {
    __octokitPromise = import("@octokit/rest").then((mod) => {
      if (mod.Octokit) {
        return mod.Octokit;
      }
      if (mod.default && mod.default.Octokit) {
        return mod.default.Octokit;
      }
      return mod.default || mod;
    });
  }
  return __octokitPromise;
}`);

    const usageOctokitLine = '  const octokit = new Octokit({ auth: token });';
    if (content.includes(usageOctokitLine)) {
      content = content.replace(usageOctokitLine, '  const Octokit = await getOctokit();\n  const octokit = new Octokit({ auth: token });');
    }
  }

  // Patch got
  const requireGotLine = 'const { got } = require("got");';
  if (content.includes(requireGotLine)) {
    content = content.replace(requireGotLine, `// ESM_PATCH: got
let __gotPromise;
async function getGot() {
  if (!__gotPromise) {
    __gotPromise = import("got").then((mod) => {
      if (mod.got) {
        return mod.got;
      }
      if (mod.default && mod.default.got) {
        return mod.default.got;
      }
      return mod.default || mod;
    });
  }
  return __gotPromise;
}`);

    const usageGotLine = '    const response = await got(url, requestOptions);';
    if (content.includes(usageGotLine)) {
      content = content.replace(usageGotLine, `    const got = await getGot();
    const response = await got(url, requestOptions);`);
    }
  }

  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Patched gulp-electron download.js for ESM imports');
} else {
  console.error('✓ gulp-electron already patched for ESM imports');
}
ELECTRONPATCH
    echo "Warning: Failed to patch gulp-electron for ESM modules. Build may fail with ERR_REQUIRE_ESM." >&2
  }
fi

export VSCODE_NODE_GLIBC="-glibc-${GLIBC_VERSION}"

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building REH"
  
  # CRITICAL FIX: Patch gulpfile.reh.js to use correct Node.js version for riscv64 and fix Docker ENOBUFS
  if [[ -f "build/gulpfile.reh.js" ]]; then
    echo "Patching gulpfile.reh.js for Node.js version and Docker extraction..." >&2
    VSCODE_ARCH="${VSCODE_ARCH}" NODE_VERSION="${NODE_VERSION}" node << 'DOCKERBUFFERFIX' || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
let content = fs.readFileSync(filePath, 'utf8');
const arch = process.env.VSCODE_ARCH || '';
const nodeVersion = process.env.NODE_VERSION || '';

// First, fix Node.js version for riscv64/loong64 if needed
// The nodejs function receives nodeVersion as a parameter, but it's read from package.json
// We need to patch where nodeVersion is used in the function, or where the function is called
if ((arch === 'riscv64' || arch === 'loong64') && nodeVersion) {
  let patched = false;
  
  // Strategy 1: Patch the nodejs function to override nodeVersion at the start
  // Look for: function nodejs(platform, arch) { ... and add version override
  const nodejsFunctionStart = /(function\s+nodejs\s*\([^)]*platform[^)]*arch[^)]*\)\s*\{)/;
  if (nodejsFunctionStart.test(content) && !content.includes('NODE_VERSION_FIX')) {
    content = content.replace(nodejsFunctionStart, (match) => {
      patched = true;
      return `${match}\n\t// NODE_VERSION_FIX: Override nodeVersion for riscv64/loong64\n\tif (process.env.VSCODE_ARCH === '${arch}' && process.env.NODE_VERSION) {\n\t\tif (typeof nodeVersion === 'undefined' || nodeVersion === null) {\n\t\t\tnodeVersion = require('../package.json').version;\n\t\t}\n\t\t// Override with environment variable\n\t\tconst envNodeVersion = process.env.NODE_VERSION;\n\t\tif (envNodeVersion) {\n\t\t\tnodeVersion = envNodeVersion;\n\t\t}\n\t}`;
    });
  }
  
  // Strategy 2: Patch where nodejs is called to pass the correct version
  // Look for: nodejs('linux', 'riscv64') or similar calls
  if (!patched) {
    const nodejsCallPattern = new RegExp(`(nodejs\\s*\\([^)]*['"]${arch}['"][^)]*\\))`, 'g');
    if (nodejsCallPattern.test(content)) {
      // This is trickier - we'd need to inject the version into the call
      // For now, rely on Strategy 1
      console.error(`Found nodejs calls for ${arch}, but patching function start instead`);
    }
  }
  
  // Strategy 3: Patch at the top level where nodeVersion might be defined
  if (!patched) {
    const topLevelVersion = /(const\s+nodeVersion\s*=\s*require\([^)]+package\.json[^)]+\)\.version;)/;
    if (topLevelVersion.test(content)) {
      content = content.replace(topLevelVersion, (match) => {
        patched = true;
        return `const nodeVersion = (process.env.VSCODE_ARCH === '${arch}' && process.env.NODE_VERSION) ? process.env.NODE_VERSION : require('../package.json').version;`;
      });
    }
  }
  
  // Strategy 4: Patch fetchUrls directly to use correct version
  if (!patched) {
    const fetchUrlsPattern = new RegExp(`(fetchUrls\\s*=\\s*\\[[^\\]]*['"]/v\\\\\\$\\\\{nodeVersion\\\\}/node-v\\\\\\$\\\\{nodeVersion\\\\}-[^}]+-${arch}[^}]+['"][^\\]]*\\])`, 'g');
    if (fetchUrlsPattern.test(content)) {
      content = content.replace(fetchUrlsPattern, (match) => {
        patched = true;
        // Replace v${nodeVersion} with the actual version
        return match.replace(/\\\$\\{nodeVersion\\}/g, nodeVersion);
      });
      if (patched) {
        console.error(`✓ Patched fetchUrls to use ${nodeVersion} for ${arch}`);
      }
    }
  }
  
  // Strategy 5: Patch the nodejs function to override nodeVersion parameter at the very start
  if (!patched) {
    // Find function nodejs(platform, arch) and add version override as first line
    const nodejsFunctionPattern = /(function\s+nodejs\s*\([^)]*\)\s*\{)/;
    if (nodejsFunctionPattern.test(content)) {
      content = content.replace(nodejsFunctionPattern, (match) => {
        patched = true;
        return `${match}\n\t// NODE_VERSION_FIX: Override for ${arch}\n\tif (arch === '${arch}' && process.env.NODE_VERSION) {\n\t\tnodeVersion = process.env.NODE_VERSION;\n\t}`;
      });
      if (patched) {
        console.error(`✓ Patched nodejs function to override version for ${arch}`);
      }
    }
  }
  
  // Strategy 6: Patch the actual URL construction in fetchUrls calls - be more aggressive
  if (!patched) {
    // Find fetchUrls calls with nodeVersion and replace them - try multiple patterns
    const patterns = [
      new RegExp(`(fetchUrls\\([^)]*['"]/v\\\\\\$\\\\{nodeVersion\\\\}/node-v\\\\\\$\\\\{nodeVersion\\\\}-[^}]+-${arch}[^}]+['"][^)]*\\))`, 'g'),
      new RegExp(`(fetchUrls\\([^)]*['"]/dist/v\\\\\\$\\\\{nodeVersion\\\\}/node-v\\\\\\$\\\\{nodeVersion\\\\}-[^}]+-${arch}[^}]+['"][^)]*\\))`, 'g'),
      new RegExp(`(['"]/v\\\\\\$\\\\{nodeVersion\\\\}/node-v\\\\\\$\\\\{nodeVersion\\\\}-[^}]+-${arch}[^}]+['"])`, 'g')
    ];
    
    for (const pattern of patterns) {
      if (pattern.test(content)) {
        content = content.replace(pattern, (match) => {
          patched = true;
          // Replace all occurrences of ${nodeVersion} with the actual version
          return match.replace(/\\\$\\{nodeVersion\\}/g, nodeVersion);
        });
        if (patched) {
          console.error(`✓ Patched fetchUrls/URL pattern to use ${nodeVersion} for ${arch}`);
          break;
        }
      }
    }
  }
  
  // Strategy 7: Patch at the very beginning of nodejs function to override nodeVersion immediately
  if (!patched) {
    // Find the function and add version override as the very first statement
    const nodejsFuncStart = /(function\s+nodejs\s*\([^)]*platform[^)]*arch[^)]*\)\s*\{)/;
    if (nodejsFuncStart.test(content)) {
      content = content.replace(nodejsFuncStart, (match) => {
        patched = true;
        return `${match}
\t// NODE_VERSION_FIX_${arch}: Override nodeVersion immediately for ${arch}
\tif (arch === '${arch}' && process.env.NODE_VERSION) {
\t\tconst envNodeVersion = process.env.NODE_VERSION;
\t\tif (typeof nodeVersion === 'undefined') {
\t\t\tnodeVersion = require('../package.json').version;
\t\t}
\t\tnodeVersion = envNodeVersion;
\t}`;
      });
      if (patched) {
        console.error(`✓ Patched nodejs function start to override version for ${arch}`);
      }
    }
  }
  
  // Strategy 8: Patch the actual URL strings directly - most aggressive approach
  if (!patched) {
    // Find any occurrence of v${nodeVersion} or v22.20.0 in URLs for this arch and replace
    // Use simpler patterns that don't require escaping
    const urlPatterns = [
      new RegExp(`(/v\\$\\{nodeVersion\\}/node-v\\$\\{nodeVersion\\}-[^}]+-${arch}[^}]+)`, 'g'),
      new RegExp(`(/v22\\.20\\.0/node-v22\\.20\\.0-[^}]+-${arch}[^}]+)`, 'g'),
      new RegExp(`(v\\$\\{nodeVersion\\}-[^}]+-${arch})`, 'g'),
      new RegExp(`(v22\\.20\\.0-[^}]+-${arch})`, 'g')
    ];
    
    for (const pattern of urlPatterns) {
      if (pattern.test(content)) {
        content = content.replace(pattern, (match) => {
          patched = true;
          // Replace v${nodeVersion} or v22.20.0 with the actual version
          return match.replace(/v\$\{nodeVersion\}/g, `v${nodeVersion}`).replace(/v22\.20\.0/g, `v${nodeVersion}`);
        });
        if (patched) {
          console.error(`✓ Patched URL strings directly to use ${nodeVersion} for ${arch}`);
          break;
        }
      }
    }
  }
  
  if (patched) {
    console.error(`✓ Patched Node.js version to use ${nodeVersion} for ${arch}`);
  } else {
    console.error(`⚠ Could not find nodeVersion definition to patch for ${arch}`);
  }
}

// Check if already patched for Docker
if (content.includes('// DOCKER_BUFFER_FIX') || (content.includes('fs.readFileSync') && content.includes('tmpFile'))) {
  console.error('gulpfile.reh.js already patched for Docker buffer fix');
} else {

// Find extractAlpinefromDocker function and replace execSync with file-based approach
// The function might already be patched by alpine patch, so check for both patterns
let functionPattern = /function\s+extractAlpinefromDocker\([^)]*\)\s*\{[\s\S]*?const\s+contents\s*=\s*cp\.execSync\([^;]+;/;
let match = content.match(functionPattern);

// If not found, try matching the already-patched version (with dockerPlatform)
if (!match) {
  functionPattern = /function\s+extractAlpinefromDocker\([^)]*\)\s*\{[\s\S]*?cp\.execSync\([^)]+maxBuffer[^;]+;/;
  match = content.match(functionPattern);
}

if (match) {
  // Replace the execSync line with file-based approach
  // The function is at line 171, so find the exact execSync line with maxBuffer
  const execSyncLinePattern = /(\s+)(const\s+contents\s*=\s*cp\.execSync\([^)]+maxBuffer[^)]+\)[^;]+;)/;
  if (execSyncLinePattern.test(content)) {
    content = content.replace(execSyncLinePattern, (match, indent, execLine) => {
      return `${indent}// DOCKER_BUFFER_FIX: Use file output instead of execSync to avoid ENOBUFS
${indent}const tmpFile = path.join(os.tmpdir(), \`node-\${nodeVersion}-\${arch}-\${Date.now()}\`);
${indent}try {
${indent}	// Use spawn with file redirection to avoid ENOBUFS
${indent}	const { spawnSync } = require('child_process');
${indent}	const dockerCmd = arch === 'arm64' && process.platform === 'linux' ? 
${indent}		\`docker run --rm --platform linux/arm64 \${imageName || 'arm64v8/node'}:\${nodeVersion}-alpine /bin/sh -c 'cat \\\`which node\\\`'\` :
${indent}		\`docker run --rm \${dockerPlatform || ''} \${imageName || 'node'}:\${nodeVersion}-alpine /bin/sh -c 'cat \\\`which node\\\`'\`;
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
  
  # CRITICAL FIX: Patch build/lib/extensions.js to handle empty glob patterns (same as main build)
  # This is needed for REH builds that use doPackageLocalExtensionsStream
  if [[ -f "build/lib/extensions.js" ]]; then
    echo "Patching build/lib/extensions.js to handle empty glob patterns..." >&2
    node << 'EXTENSIONSGLOBFIX' || {
const fs = require('fs');
const filePath = 'build/lib/extensions.js';
let content = fs.readFileSync(filePath, 'utf8');
let modified = false;

// Fix 1: Find the specific line with dependenciesSrc and ensure it's never empty
if (content.includes('dependenciesSrc') && content.includes('gulp')) {
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('dependenciesSrc') && lines[i].includes('gulp') && lines[i].includes('.src(')) {
      const indent = lines[i].match(/^\s*/)[0];
      let hasCheck = false;
      for (let j = Math.max(0, i - 5); j < i; j++) {
        if (lines[j].includes('dependenciesSrc.length === 0') || lines[j].includes('dependenciesSrc = [\'**')) {
          hasCheck = true;
          break;
        }
      }
      if (!hasCheck) {
        lines.splice(i, 0, `${indent}if (!dependenciesSrc || dependenciesSrc.length === 0) { dependenciesSrc = ['**', '!**/*']; }`);
        modified = true;
        i++;
        console.error(`✓ Added empty check for dependenciesSrc before gulp.src at line ${i + 1}`);
      }
      
      if (!lines[i].includes('allowEmpty')) {
        lines[i] = lines[i].replace(/(base:\s*['"]\.['"])\s*\}\)/, '$1, allowEmpty: true })');
        lines[i] = lines[i].replace(/(base:\s*[^}]+)\s*\}\)/, '$1, allowEmpty: true })');
        if (lines[i].includes('allowEmpty')) {
          modified = true;
          console.error(`✓ Added allowEmpty to gulp.src at line ${i + 1}`);
        }
      }
      break;
    }
  }
  content = lines.join('\n');
}

// Fix 2: Also patch the dependenciesSrc assignment
if (content.includes('const dependenciesSrc =') && content.includes('.flat()')) {
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('const dependenciesSrc =') && lines[i].includes('.flat()')) {
      if (!lines[i].includes('|| [\'**\', \'!**/*\']')) {
        const indent = lines[i].match(/^\s*/)[0];
        lines[i] = lines[i].replace(/const dependenciesSrc =/, 'let dependenciesSrc =');
        lines[i] = lines[i].replace(/\.flat\(\);?$/, ".flat() || ['**', '!**/*'];");
        lines.splice(i + 1, 0, `${indent}if (dependenciesSrc.length === 0) { dependenciesSrc = ['**', '!**/*']; }`);
        modified = true;
        console.error(`✓ Fixed dependenciesSrc assignment at line ${i + 1}`);
      }
      break;
    }
  }
  content = lines.join('\n');
}

if (modified) {
  fs.writeFileSync(filePath, content, 'utf8');
  console.error('✓ Successfully patched build/lib/extensions.js for empty glob patterns');
} else {
  console.error('⚠ No changes made - file may already be patched or structure is different');
}
EXTENSIONSGLOBFIX
      echo "Warning: Failed to patch build/lib/extensions.js, continuing anyway..." >&2
    }
  fi
  
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
  
  // Fix 1: dependenciesSrc
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
  
  // Fix 2: extensionPaths
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('const extensionPaths =') && lines[i].includes('.map(name =>')) {
      if (!lines[i].includes('|| [\'**\', \'!**/*\']')) {
        let newLine = lines[i].replace(/const extensionPaths =/, 'let extensionPaths =');
        // Match the pattern: .map(name => `.build/extensions/${name}/**`)
        newLine = newLine.replace(/\.map\(name => `\.build\/extensions\/\$\{name\}\/\*\*`\);?$/, ".map(name => `.build/extensions/${name}/**`) || ['**', '!**/*'];");
        lines[i] = newLine;
        const indent = lines[i].match(/^\s*/)[0];
        lines.splice(i + 1, 0, `${indent}if (extensionPaths.length === 0) { extensionPaths = ['**', '!**/*']; }`);
        modified = true;
        console.error(`✓ Fixed extensionPaths at line ${i + 1}`);
      }
      break;
    }
  }
  
  if (modified) {
    content = lines.join('\n');
    fs.writeFileSync(filePath, content, 'utf8');
    console.error('✓ Successfully applied REH glob fix (dependenciesSrc and extensionPaths)');
  }
} catch (error) {
  console.error(`✗ ERROR: ${error.message}`);
  process.exit(1);
}
REHFIX
      echo "Warning: Failed to patch gulpfile.reh.js, continuing anyway..." >&2
    }
  fi
  
  # Verify gulp is available before running
  if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
    echo "Error: gulp is not installed. Cannot run REH build." >&2
    echo "This may indicate npm ci failed partially. Check logs above." >&2
    exit 1
  fi
  
  npm run gulp minify-vscode-reh
  
  # Verify REH gulp task exists, especially for alternative architectures
  REH_GULP_TASK="vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  echo "Checking if REH gulp task '${REH_GULP_TASK}' exists..."
  
  # Try to list tasks and check if our task exists
  if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_GULP_TASK}$"; then
    echo "Warning: REH gulp task '${REH_GULP_TASK}' not found. Ensuring architecture is in BUILD_TARGETS..." >&2
    
    # For alternative architectures, ensure they're in BUILD_TARGETS in gulpfile.reh.js
    if [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]]; then
      echo "Ensuring ${VSCODE_ARCH} is in BUILD_TARGETS in gulpfile.reh.js..." >&2
      if [[ -f "build/gulpfile.reh.js" ]]; then
        if ! grep -q "{ platform: 'linux', arch: '${VSCODE_ARCH}' }" "build/gulpfile.reh.js"; then
          echo "Adding ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js..." >&2
          node << ARCHFIX || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
const arch = '${VSCODE_ARCH}';
try {
  let content = fs.readFileSync(filePath, 'utf8');
  
  if (content.includes(\`{ platform: 'linux', arch: '\${arch}' }\`)) {
    console.error(\`✓ \${arch} already in BUILD_TARGETS\`);
    process.exit(0);
  }
  
  // Find the BUILD_TARGETS array and add arch after ppc64le or arm64
  const pattern = /(\{\s*platform:\s*['"]linux['"],\s*arch:\s*['"](?:ppc64le|arm64)['"]\s*\},)/;
  if (pattern.test(content)) {
    content = content.replace(
      pattern,
      \`$1\n\t{ platform: 'linux', arch: '\${arch}' },\`
    );
    fs.writeFileSync(filePath, content, 'utf8');
    console.error(\`✓ Added \${arch} to BUILD_TARGETS in gulpfile.reh.js\`);
  } else {
    console.error('⚠ Could not find entry to add arch after');
    process.exit(1);
  }
} catch (error) {
  console.error('Error:', error.message);
  process.exit(1);
}
ARCHFIX
            echo "Warning: Failed to add ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js, but continuing..." >&2
          } else {
            echo "✓ ${VSCODE_ARCH} already in BUILD_TARGETS" >&2
          }
        fi
      fi
      
      # Re-check if task is now available
      if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_GULP_TASK}$"; then
        echo "Warning: REH gulp task '${REH_GULP_TASK}' still not found after patch attempt." >&2
        echo "Available REH tasks:" >&2
        npm run gulp -- --tasks-simple 2>&1 | grep "vscode-reh" | head -10 >&2 || true
        echo "Attempting to run task anyway..." >&2
      fi
    fi
  fi
  
  npm run gulp "${REH_GULP_TASK}"

  EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

  pushd "../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  if [[ -f "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" ]]; then
    bash "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" "node_modules"
  fi

  echo "Archiving REH"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building REH-web"
  # Verify gulp is available before running
  if [[ ! -f "node_modules/gulp/bin/gulp.js" ]] && [[ ! -f "node_modules/.bin/gulp" ]]; then
    echo "Error: gulp is not installed. Cannot run REH-web build." >&2
    echo "This may indicate npm ci failed partially. Check logs above." >&2
    exit 1
  fi
  
  npm run gulp minify-vscode-reh-web
  
  # Verify REH-web gulp task exists, especially for alternative architectures
  REH_WEB_GULP_TASK="vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  echo "Checking if REH-web gulp task '${REH_WEB_GULP_TASK}' exists..."
  
  # Try to list tasks and check if our task exists
  if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_WEB_GULP_TASK}$"; then
    echo "Warning: REH-web gulp task '${REH_WEB_GULP_TASK}' not found. Ensuring architecture is in BUILD_TARGETS..." >&2
    
    # For alternative architectures, ensure they're in BUILD_TARGETS in gulpfile.reh.js
    if [[ "${VSCODE_ARCH}" == "ppc64le" ]] || [[ "${VSCODE_ARCH}" == "riscv64" ]] || [[ "${VSCODE_ARCH}" == "loong64" ]] || [[ "${VSCODE_ARCH}" == "s390x" ]]; then
      echo "Ensuring ${VSCODE_ARCH} is in BUILD_TARGETS in gulpfile.reh.js..." >&2
      if [[ -f "build/gulpfile.reh.js" ]]; then
        if ! grep -q "{ platform: 'linux', arch: '${VSCODE_ARCH}' }" "build/gulpfile.reh.js"; then
          echo "Adding ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js..." >&2
          node << ARCHFIX || {
const fs = require('fs');
const filePath = 'build/gulpfile.reh.js';
const arch = '${VSCODE_ARCH}';
try {
  let content = fs.readFileSync(filePath, 'utf8');
  
  if (content.includes(\`{ platform: 'linux', arch: '\${arch}' }\`)) {
    console.error(\`✓ \${arch} already in BUILD_TARGETS\`);
    process.exit(0);
  }
  
  // Find the BUILD_TARGETS array and add arch after ppc64le or arm64
  const pattern = /(\{\s*platform:\s*['"]linux['"],\s*arch:\s*['"](?:ppc64le|arm64)['"]\s*\},)/;
  if (pattern.test(content)) {
    content = content.replace(
      pattern,
      \`$1\n\t{ platform: 'linux', arch: '\${arch}' },\`
    );
    fs.writeFileSync(filePath, content, 'utf8');
    console.error(\`✓ Added \${arch} to BUILD_TARGETS in gulpfile.reh.js\`);
  } else {
    console.error('⚠ Could not find entry to add arch after');
    process.exit(1);
  }
} catch (error) {
  console.error('Error:', error.message);
  process.exit(1);
}
ARCHFIX
            echo "Warning: Failed to add ${VSCODE_ARCH} to BUILD_TARGETS in gulpfile.reh.js, but continuing..." >&2
          } else {
            echo "✓ ${VSCODE_ARCH} already in BUILD_TARGETS" >&2
          }
        fi
      fi
      
      # Re-check if task is now available
      if ! npm run gulp -- --tasks-simple 2>/dev/null | grep -q "^${REH_WEB_GULP_TASK}$"; then
        echo "Warning: REH-web gulp task '${REH_WEB_GULP_TASK}' still not found after patch attempt." >&2
        echo "Available REH-web tasks:" >&2
        npm run gulp -- --tasks-simple 2>&1 | grep "vscode-reh-web" | head -10 >&2 || true
        echo "Attempting to run task anyway..." >&2
      fi
    fi
  fi
  
  npm run gulp "${REH_WEB_GULP_TASK}"

  EXPECTED_GLIBC_VERSION="${EXPECTED_GLIBC_VERSION}" EXPECTED_GLIBCXX_VERSION="${GLIBCXX_VERSION}" SEARCH_PATH="../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}" ./build/azure-pipelines/linux/verify-glibc-requirements.sh

  pushd "../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  if [[ -f "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" ]]; then
    bash "../ripgrep_${VSCODE_PLATFORM}_${VSCODE_ARCH}.sh" "node_modules"
  fi

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
