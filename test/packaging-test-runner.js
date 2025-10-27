/*---------------------------------------------------------------------------------------------
 *  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
 *  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
 *--------------------------------------------------------------------------------------------*/

import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';
import { PACKAGING_TEST_CONFIG, PackagingTestResult, PackagingTestConfig, DEFAULT_PACKAGING_TEST_CONFIG } from './packaging-test-config.js';

export class PackagingTestRunner {
	private config: PackagingTestConfig;
	private results: PackagingTestResult[] = [];

	constructor(config: PackagingTestConfig = DEFAULT_PACKAGING_TEST_CONFIG) {
		this.config = config;
	}

	async runTests(): Promise<PackagingTestResult[]> {
		this.results = [];
		
		const platforms = this.config.platform === 'all' 
			? Object.keys(PACKAGING_TEST_CONFIG.platforms)
			: [this.config.platform];

		for (const platform of platforms) {
			await this.runPlatformTests(platform);
		}

		if (this.config.testTypes.includes('consistency')) {
			await this.runConsistencyTests();
		}

		return this.results;
	}

	private async runPlatformTests(platform: string): Promise<void> {
		const platformConfig = PACKAGING_TEST_CONFIG.platforms[platform as keyof typeof PACKAGING_TEST_CONFIG.platforms];
		if (!platformConfig) {
			this.addResult(platform, 'platform', false, `Unknown platform: ${platform}`);
			return;
		}

		// Test file existence
		if (this.config.testTypes.includes('existence')) {
			await this.testFileExistence(platform, platformConfig);
		}

		// Test branding
		if (this.config.testTypes.includes('branding')) {
			await this.testBranding(platform, platformConfig);
		}

		// Test script syntax
		if (this.config.testTypes.includes('syntax')) {
			await this.testScriptSyntax(platform, platformConfig);
		}

		// Test assets
		if (this.config.testTypes.includes('assets')) {
			await this.testAssets(platform);
		}
	}

	private async testFileExistence(platform: string, platformConfig: any): Promise<void> {
		const requiredFiles = platformConfig.requiredFiles || [];
		const optionalFiles = this.config.includeOptional ? (platformConfig.optionalFiles || []) : [];
		const allFiles = [...requiredFiles, ...optionalFiles];

		let existingFiles = 0;
		let missingFiles: string[] = [];

		for (const file of allFiles) {
			if (fs.existsSync(file)) {
				existingFiles++;
			} else {
				missingFiles.push(file);
			}
		}

		const threshold = requiredFiles.length > 0 ? existingFiles / requiredFiles.length : 1;
		const passed = threshold >= PACKAGING_TEST_CONFIG.thresholds.minRequiredFiles;

		this.addResult(platform, 'existence', passed, 
			`File existence check: ${existingFiles}/${allFiles.length} files found`,
			{ existingFiles, missingFiles, threshold });
	}

	private async testBranding(platform: string, platformConfig: any): Promise<void> {
		const brandingPatterns = PACKAGING_TEST_CONFIG.platformBrandingPatterns[platform as keyof typeof PACKAGING_TEST_CONFIG.platformBrandingPatterns];
		if (!brandingPatterns) {
			this.addResult(platform, 'branding', true, 'No branding patterns defined for platform');
			return;
		}

		let correctFiles = 0;
		let totalFiles = 0;
		let brandingIssues: string[] = [];

		for (const [file, keywords] of Object.entries(brandingPatterns)) {
			if (fs.existsSync(file)) {
				totalFiles++;
				const content = fs.readFileSync(file, 'utf8');
				const hasCorrectBranding = keywords.some(keyword => 
					content.toLowerCase().includes(keyword.toLowerCase())
				);

				if (hasCorrectBranding) {
					correctFiles++;
				} else {
					brandingIssues.push(`${file}: Missing branding keywords ${keywords.join(', ')}`);
				}
			}
		}

		const threshold = totalFiles > 0 ? correctFiles / totalFiles : 1;
		const passed = threshold >= PACKAGING_TEST_CONFIG.thresholds.minBrandingConsistency;

		this.addResult(platform, 'branding', passed,
			`Branding check: ${correctFiles}/${totalFiles} files have correct branding`,
			{ correctFiles, totalFiles, brandingIssues, threshold });
	}

	private async testScriptSyntax(platform: string, platformConfig: any): Promise<void> {
		const buildFiles = platformConfig.buildFiles || [];
		let validScripts = 0;
		let totalScripts = 0;
		let syntaxErrors: string[] = [];

		for (const script of buildFiles) {
			if (fs.existsSync(script) && script.endsWith('.sh')) {
				totalScripts++;
				try {
					execSync(`bash -n "${script}"`, { stdio: 'pipe' });
					validScripts++;
				} catch (error) {
					syntaxErrors.push(`${script}: ${error}`);
				}
			}
		}

		const threshold = totalScripts > 0 ? validScripts / totalScripts : 1;
		const passed = threshold >= PACKAGING_TEST_CONFIG.thresholds.minScriptValidity;

		this.addResult(platform, 'syntax', passed,
			`Script syntax check: ${validScripts}/${totalScripts} scripts are valid`,
			{ validScripts, totalScripts, syntaxErrors, threshold });
	}

	private async testAssets(platform: string): Promise<void> {
		const assetDirs = PACKAGING_TEST_CONFIG.assetDirectories;
		let existingDirs = 0;
		let totalFiles = 0;
		let missingDirs: string[] = [];

		for (const dir of assetDirs) {
			if (fs.existsSync(dir) && fs.statSync(dir).isDirectory()) {
				existingDirs++;
				const files = fs.readdirSync(dir);
				totalFiles += files.length;
			} else {
				missingDirs.push(dir);
			}
		}

		const threshold = assetDirs.length > 0 ? existingDirs / assetDirs.length : 1;
		const passed = threshold >= PACKAGING_TEST_CONFIG.thresholds.minAssetCompleteness;

		this.addResult(platform, 'assets', passed,
			`Asset check: ${existingDirs}/${assetDirs.length} directories exist with ${totalFiles} files`,
			{ existingDirs, totalFiles, missingDirs, threshold });
	}

	private async runConsistencyTests(): Promise<void> {
		// Test cross-platform branding consistency
		const brandingFiles = PACKAGING_TEST_CONFIG.consistency.brandingFiles;
		let consistentFiles = 0;
		let totalFiles = 0;
		let consistencyIssues: string[] = [];

		for (const file of brandingFiles) {
			if (fs.existsSync(file)) {
				totalFiles++;
				const content = fs.readFileSync(file, 'utf8');
				const hasCortexideBranding = PACKAGING_TEST_CONFIG.brandingKeywords.some(keyword =>
					content.toLowerCase().includes(keyword.toLowerCase())
				);

				if (hasCortexideBranding) {
					consistentFiles++;
				} else {
					consistencyIssues.push(`${file}: Missing CortexIDE branding`);
				}
			}
		}

		const threshold = totalFiles > 0 ? consistentFiles / totalFiles : 1;
		const passed = threshold >= PACKAGING_TEST_CONFIG.thresholds.minBrandingConsistency;

		this.addResult('cross-platform', 'consistency', passed,
			`Consistency check: ${consistentFiles}/${totalFiles} files have consistent branding`,
			{ consistentFiles, totalFiles, consistencyIssues, threshold });
	}

	private addResult(platform: string, testType: string, passed: boolean, message: string, details?: any): void {
		this.results.push({
			platform,
			testType,
			passed,
			message,
			details
		});
	}

	getResults(): PackagingTestResult[] {
		return this.results;
	}

	getSummary(): { total: number; passed: number; failed: number; platforms: string[] } {
		const total = this.results.length;
		const passed = this.results.filter(r => r.passed).length;
		const failed = total - passed;
		const platforms = [...new Set(this.results.map(r => r.platform))];

		return { total, passed, failed, platforms };
	}

	printResults(): void {
		console.log('\n=== Cross-Platform Packaging Test Results ===\n');

		const summary = this.getSummary();
		console.log(`Total Tests: ${summary.total}`);
		console.log(`Passed: ${summary.passed}`);
		console.log(`Failed: ${summary.failed}`);
		console.log(`Platforms: ${summary.platforms.join(', ')}\n`);

		// Group results by platform
		const groupedResults = this.results.reduce((acc, result) => {
			if (!acc[result.platform]) {
				acc[result.platform] = [];
			}
			acc[result.platform].push(result);
			return acc;
		}, {} as Record<string, PackagingTestResult[]>);

		// Print results by platform
		for (const [platform, results] of Object.entries(groupedResults)) {
			console.log(`\n--- ${platform.toUpperCase()} ---`);
			for (const result of results) {
				const status = result.passed ? '✅' : '❌';
				console.log(`${status} ${result.testType}: ${result.message}`);
				if (result.details && this.config.strictMode) {
					console.log(`   Details: ${JSON.stringify(result.details, null, 2)}`);
				}
			}
		}

		console.log('\n=== Test Summary ===');
		if (summary.failed === 0) {
			console.log('🎉 All packaging tests passed!');
		} else {
			console.log(`⚠️  ${summary.failed} test(s) failed. Check the details above.`);
		}
	}
}

// CLI interface
if (import.meta.url === `file://${process.argv[1]}`) {
	const args = process.argv.slice(2);
	const config: PackagingTestConfig = {
		platform: 'all',
		testTypes: ['existence', 'branding', 'syntax', 'assets', 'consistency'],
		includeOptional: true,
		strictMode: false
	};

	// Parse command line arguments
	for (let i = 0; i < args.length; i++) {
		switch (args[i]) {
			case '--platform':
				config.platform = args[++i] || 'all';
				break;
			case '--test-types':
				config.testTypes = args[++i]?.split(',') || ['existence', 'branding', 'syntax', 'assets', 'consistency'];
				break;
			case '--include-optional':
				config.includeOptional = true;
				break;
			case '--no-optional':
				config.includeOptional = false;
				break;
			case '--strict':
				config.strictMode = true;
				break;
			case '--help':
				console.log(`
Cross-Platform Packaging Test Runner

Usage: node packaging-test-runner.js [OPTIONS]

Options:
  --platform <platform>     Platform to test (macos, linux, windows, all)
  --test-types <types>       Comma-separated test types (existence, branding, syntax, assets, consistency)
  --include-optional        Include optional files in tests (default)
  --no-optional            Exclude optional files from tests
  --strict                 Show detailed test results
  --help                   Show this help message

Examples:
  node packaging-test-runner.js
  node packaging-test-runner.js --platform macos
  node packaging-test-runner.js --test-types existence,branding
  node packaging-test-runner.js --strict
				`);
				process.exit(0);
				break;
		}
	}

	// Run tests
	const runner = new PackagingTestRunner(config);
	runner.runTests().then(() => {
		runner.printResults();
		process.exit(runner.getSummary().failed > 0 ? 1 : 0);
	}).catch(error => {
		console.error('Test runner error:', error);
		process.exit(1);
	});
}
