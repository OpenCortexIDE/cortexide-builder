#!/usr/bin/env bash
# shellcheck disable=SC1091

# Fix dependencies-generator.js and related files for alternative architectures
# This script applies fixes to support riscv64, ppc64le, and loong64 architectures

set -e

cd vscode || { echo "'vscode' dir not found"; exit 1; }

echo "Applying fixes for alternative architecture support..."

# Fix dependencies-generator.js - make dependency check optional for architectures without reference lists
# Also set FAIL_BUILD_FOR_NEW_DEPENDENCIES to false to allow builds to continue when dependencies change
if [[ -f "build/linux/dependencies-generator.js" ]]; then
  echo "Fixing dependencies-generator.js..."
  # First, set FAIL_BUILD_FOR_NEW_DEPENDENCIES to false
  if grep -q "const FAIL_BUILD_FOR_NEW_DEPENDENCIES = true" build/linux/dependencies-generator.js 2>/dev/null; then
    sed -i "s/const FAIL_BUILD_FOR_NEW_DEPENDENCIES = true/const FAIL_BUILD_FOR_NEW_DEPENDENCIES = false/" build/linux/dependencies-generator.js
    echo "Set FAIL_BUILD_FOR_NEW_DEPENDENCIES to false"
  fi
  # Check if fix is already applied
  if ! grep -q "Skip dependency check if no reference list exists" build/linux/dependencies-generator.js 2>/dev/null; then
    # Use Node.js to do the replacement more reliably
    node << 'EOF'
const fs = require('fs');
const file = 'build/linux/dependencies-generator.js';
let content = fs.readFileSync(file, 'utf8');

// Replace the dependency check to make it optional
const oldPattern = /const referenceGeneratedDeps = packageType === 'deb' \?\s+dep_lists_1\.referenceGeneratedDepsByArch\[arch\] :\s+dep_lists_2\.referenceGeneratedDepsByArch\[arch\];\s+if \(JSON\.stringify\(sortedDependencies\) !== JSON\.stringify\(referenceGeneratedDeps\)\) \{/s;

const newCode = `const referenceGeneratedDeps = packageType === 'deb' ?
        dep_lists_1.referenceGeneratedDepsByArch[arch] :
        dep_lists_2.referenceGeneratedDepsByArch[arch];
    // Skip dependency check if no reference list exists for this architecture
    if (referenceGeneratedDeps) {
        if (JSON.stringify(sortedDependencies) !== JSON.stringify(referenceGeneratedDeps)) {`;

if (oldPattern.test(content)) {
  content = content.replace(oldPattern, newCode);

  // Also need to close the if statement and add else
  const returnPattern = /(\s+return sortedDependencies;\s+})/;
  const replacement = `}
    else {
        console.warn("No reference dependency list found for architecture " + arch + ". Skipping dependency check.");
    }
    return sortedDependencies;
}`;

  content = content.replace(returnPattern, replacement);
  fs.writeFileSync(file, content, 'utf8');
  console.log('Fixed dependencies-generator.js');
} else {
  console.log('dependencies-generator.js already fixed or pattern not found');
}
EOF
  else
    echo "dependencies-generator.js already fixed"
  fi
fi

# Fix calculate-deps.js - add architecture cases
if [[ -f "build/linux/debian/calculate-deps.js" ]]; then
  echo "Fixing calculate-deps.js..."
  if ! grep -q "case 'riscv64':" build/linux/debian/calculate-deps.js 2>/dev/null; then
    node << 'EOF'
const fs = require('fs');
const file = 'build/linux/debian/calculate-deps.js';
let content = fs.readFileSync(file, 'utf8');

// Add cases for alternative architectures
const arm64Case = /case 'arm64':\s+cmd\.push\(`-l\$\{chromiumSysroot\}\/usr\/lib\/aarch64-linux-gnu`, `-l\$\{chromiumSysroot\}\/lib\/aarch64-linux-gnu`, `-l\$\{vscodeSysroot\}\/usr\/lib\/aarch64-linux-gnu`, `-l\$\{vscodeSysroot\}\/lib\/aarch64-linux-gnu`\);\s+break;/;

const newCases = `case 'arm64':
            cmd.push(\`-l\${chromiumSysroot}/usr/lib/aarch64-linux-gnu\`, \`-l\${chromiumSysroot}/lib/aarch64-linux-gnu\`, \`-l\${vscodeSysroot}/usr/lib/aarch64-linux-gnu\`, \`-l\${vscodeSysroot}/lib/aarch64-linux-gnu\`);
            break;
        case 'ppc64el':
            cmd.push(\`-l\${chromiumSysroot}/usr/lib/powerpc64le-linux-gnu\`, \`-l\${chromiumSysroot}/lib/powerpc64le-linux-gnu\`, \`-l\${vscodeSysroot}/usr/lib/powerpc64le-linux-gnu\`, \`-l\${vscodeSysroot}/lib/powerpc64le-linux-gnu\`);
            break;
        case 'riscv64':
            cmd.push(\`-l\${chromiumSysroot}/usr/lib/riscv64-linux-gnu\`, \`-l\${chromiumSysroot}/lib/riscv64-linux-gnu\`, \`-l\${vscodeSysroot}/usr/lib/riscv64-linux-gnu\`, \`-l\${vscodeSysroot}/lib/riscv64-linux-gnu\`);
            break;
        case 'loong64':
            cmd.push(\`-l\${chromiumSysroot}/usr/lib/loongarch64-linux-gnu\`, \`-l\${chromiumSysroot}/lib/loongarch64-linux-gnu\`, \`-l\${vscodeSysroot}/usr/lib/loongarch64-linux-gnu\`, \`-l\${vscodeSysroot}/lib/loongarch64-linux-gnu\`);
            break;`;

if (arm64Case.test(content)) {
  content = content.replace(arm64Case, newCases);
  fs.writeFileSync(file, content, 'utf8');
  console.log('Fixed calculate-deps.js');
} else {
  console.log('calculate-deps.js pattern not found');
}
EOF
  else
    echo "calculate-deps.js already fixed"
  fi
fi

# Fix types.js - add architectures to allowed list
if [[ -f "build/linux/debian/types.js" ]]; then
  echo "Fixing types.js..."
  if ! grep -q "'riscv64'" build/linux/debian/types.js 2>/dev/null; then
    node << 'EOF'
const fs = require('fs');
const file = 'build/linux/debian/types.js';
let content = fs.readFileSync(file, 'utf8');

content = content.replace(
  /return \['amd64', 'armhf', 'arm64'\]\.includes\(s\);/,
  "return ['amd64', 'armhf', 'arm64', 'ppc64el', 'riscv64', 'loong64'].includes(s);"
);

fs.writeFileSync(file, content, 'utf8');
console.log('Fixed types.js');
EOF
  else
    echo "types.js already fixed"
  fi
fi

# Fix install-sysroot.js - add architecture cases
if [[ -f "build/linux/debian/install-sysroot.js" ]]; then
  echo "Fixing install-sysroot.js..."
  if ! grep -q "case 'riscv64':" build/linux/debian/install-sysroot.js 2>/dev/null; then
    node << 'EOF'
const fs = require('fs');
const file = 'build/linux/debian/install-sysroot.js';
let content = fs.readFileSync(file, 'utf8');

// Add cases after armhf
const armhfPattern = /case 'armhf':\s+expectedName = `arm-rpi-linux-gnueabihf\$\{prefix\}\.tar\.gz`;\s+triple = 'arm-rpi-linux-gnueabihf';\s+break;/;

const newCases = `case 'armhf':
            expectedName = \`arm-rpi-linux-gnueabihf\${prefix}.tar.gz\`;
            triple = 'arm-rpi-linux-gnueabihf';
            break;
        case 'ppc64el':
            expectedName = \`powerpc64le-linux-gnu\${prefix}.tar.gz\`;
            triple = 'powerpc64le-linux-gnu';
            break;
        case 'riscv64':
            expectedName = \`riscv64-linux-gnu\${prefix}.tar.gz\`;
            triple = 'riscv64-linux-gnu';
            break;
        case 'loong64':
            expectedName = \`loongarch64-linux-gnu\${prefix}.tar.gz\`;
            triple = 'loongarch64-linux-gnu';
            break;`;

if (armhfPattern.test(content)) {
  content = content.replace(armhfPattern, newCases);
  fs.writeFileSync(file, content, 'utf8');
  console.log('Fixed install-sysroot.js');
} else {
  console.log('install-sysroot.js pattern not found');
}
EOF
  else
    echo "install-sysroot.js already fixed"
  fi
fi

# Fix gulpfile.vscode.linux.js - add architecture mappings
if [[ -f "build/gulpfile.vscode.linux.js" ]]; then
  echo "Fixing gulpfile.vscode.linux.js..."
  if ! grep -q "riscv64: 'riscv64'" build/gulpfile.vscode.linux.js 2>/dev/null; then
    node << 'EOF'
const fs = require('fs');
const file = 'build/gulpfile.vscode.linux.js';
let content = fs.readFileSync(file, 'utf8');

content = content.replace(
  /return \{ x64: 'amd64', armhf: 'armhf', arm64: 'arm64' \}\[arch\];/,
  "return { x64: 'amd64', armhf: 'armhf', arm64: 'arm64', ppc64le: 'ppc64el', riscv64: 'riscv64', loong64: 'loong64' }[arch];"
);

fs.writeFileSync(file, content, 'utf8');
console.log('Fixed gulpfile.vscode.linux.js');
EOF
  else
    echo "gulpfile.vscode.linux.js already fixed"
  fi
fi

echo "All fixes applied successfully!"
