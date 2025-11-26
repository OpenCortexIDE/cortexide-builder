#!/usr/bin/env node
/**
 * Test script to verify CSS import transformation logic
 * This tests the regex patterns used in the esbuild plugin
 */

const testCases = [
    {
        name: "Side-effect import",
        input: `import './file.css';`,
        shouldTransform: true
    },
    {
        name: "Static import with default",
        input: `import styles from './file.css';`,
        shouldTransform: true
    },
    {
        name: "Static import with namespace",
        input: `import * as styles from './file.css';`,
        shouldTransform: true
    },
    {
        name: "Dynamic import",
        input: `const css = await import('./file.css');`,
        shouldTransform: true
    },
    {
        name: "No CSS import",
        input: `import { something } from './file.js';`,
        shouldTransform: false
    }
];

console.log("Testing CSS import transformation patterns...\n");

// Pattern 1: Static imports
const staticImportPattern = /import\s+([^'"\n]*?)\s+from\s+['"]([^'"]*\.css)['"]/g;

// Pattern 2: Side-effect imports
const sideEffectPattern = /import\s+['"]([^'"]*\.css)['"]\s*;?/g;

// Pattern 3: Dynamic imports
const dynamicImportPattern = /import\s*\(\s*['"]([^'"]*\.css)['"]\s*\)/g;

let passed = 0;
let failed = 0;

for (const testCase of testCases) {
    const { name, input, shouldTransform } = testCase;
    
    const hasStatic = staticImportPattern.test(input);
    staticImportPattern.lastIndex = 0; // Reset regex
    
    const hasSideEffect = sideEffectPattern.test(input);
    sideEffectPattern.lastIndex = 0;
    
    const hasDynamic = dynamicImportPattern.test(input);
    dynamicImportPattern.lastIndex = 0;
    
    const actuallyTransforms = hasStatic || hasSideEffect || hasDynamic;
    
    if (actuallyTransforms === shouldTransform) {
        console.log(`✓ ${name}: ${actuallyTransforms ? 'Transforms' : 'No transform'} (correct)`);
        passed++;
    } else {
        console.log(`✗ ${name}: Expected ${shouldTransform ? 'transform' : 'no transform'}, got ${actuallyTransforms ? 'transform' : 'no transform'}`);
        failed++;
    }
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);

if (failed > 0) {
    process.exit(1);
} else {
    console.log("\n✓ All pattern tests passed!");
}

