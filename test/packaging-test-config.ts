/*---------------------------------------------------------------------------------------------
 *  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
 *  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
 *--------------------------------------------------------------------------------------------*/

// Cross-Platform Packaging Test Configuration
export const PACKAGING_TEST_CONFIG = {
	// Platform-specific file requirements
	platforms: {
		macos: {
			requiredFiles: [
				'build/osx/include.gypi',
				'resources/darwin'
			],
			optionalFiles: [
				'resources/darwin/cortexide.icns',
				'resources/darwin/cortexide.iconset'
			],
			buildFiles: [
				'build/osx/include.gypi'
			]
		},
		linux: {
			requiredFiles: [
				'build/linux/appimage/build.sh',
				'build/linux/appimage/recipe.yml',
				'build/linux/package_bin.sh',
				'build/linux/package_reh.sh',
				'build/linux/deps.sh'
			],
			optionalFiles: [
				'resources/linux/cortexide.desktop',
				'resources/linux/cortexide-insider.desktop',
				'resources/linux/cortexide.appdata.xml',
				'resources/linux/cortexide-insider.appdata.xml'
			],
			buildFiles: [
				'build/linux/appimage/build.sh',
				'build/linux/appimage/recipe.yml',
				'build/linux/package_bin.sh',
				'build/linux/package_reh.sh'
			]
		},
		windows: {
			requiredFiles: [
				'build/windows/msi/build.sh',
				'build/windows/msi/vscodium.wxs',
				'build/windows/msi/vscodium.xsl',
				'build/windows/package.sh'
			],
			optionalFiles: [
				'resources/win32/cortexide.ico',
				'resources/win32/cortexide.rc'
			],
			buildFiles: [
				'build/windows/msi/build.sh',
				'build/windows/msi/vscodium.wxs',
				'build/windows/package.sh'
			]
		}
	},

	// Cross-platform consistency requirements
	consistency: {
		brandingFiles: [
			'product.json',
			'package.json'
		],
		buildScripts: [
			'build.sh',
			'build_cli.sh'
		],
		assetScripts: [
			'prepare_src.sh',
			'prepare_vscode.sh',
			'prepare_assets.sh',
			'prepare_checksums.sh'
		]
	},

	// Asset directories
	assetDirectories: [
		'src/stable',
		'src/insider'
	],

	// MSI localization files
	msiLocalization: [
		'build/windows/msi/i18n/vscodium.de-de.wxl',
		'build/windows/msi/i18n/vscodium.en-us.wxl',
		'build/windows/msi/i18n/vscodium.es-es.wxl',
		'build/windows/msi/i18n/vscodium.fr-fr.wxl',
		'build/windows/msi/i18n/vscodium.it-it.wxl',
		'build/windows/msi/i18n/vscodium.ja-jp.wxl',
		'build/windows/msi/i18n/vscodium.ko-kr.wxl',
		'build/windows/msi/i18n/vscodium.ru-ru.wxl',
		'build/windows/msi/i18n/vscodium.zh-cn.wxl',
		'build/windows/msi/i18n/vscodium.zh-tw.wxl'
	],

	// MSI resources
	msiResources: [
		'build/windows/msi/resources/stable/wix-banner.bmp',
		'build/windows/msi/resources/stable/wix-dialog.bmp',
		'build/windows/msi/resources/insider/wix-banner.bmp',
		'build/windows/msi/resources/insider/wix-dialog.bmp'
	],

	// Branding keywords to check for
	brandingKeywords: [
		'cortexide',
		'CortexIDE',
		'CORTEXIDE'
	],

	// File patterns to check for branding
	brandingPatterns: {
		'product.json': ['cortexide', 'CortexIDE'],
		'package.json': ['cortexide', 'CortexIDE'],
		'build.sh': ['cortexide', 'CortexIDE'],
		'build_cli.sh': ['cortexide', 'CortexIDE'],
		'prepare_assets.sh': ['cortexide', 'CortexIDE'],
		'prepare_checksums.sh': ['cortexide', 'CortexIDE']
	},

	// Platform-specific branding patterns
	platformBrandingPatterns: {
		macos: {
			'build/osx/include.gypi': ['cortexide', 'CortexIDE']
		},
		linux: {
			'build/linux/appimage/recipe.yml': ['cortexide', 'CortexIDE'],
			'build/linux/package_bin.sh': ['cortexide', 'CortexIDE'],
			'build/linux/package_reh.sh': ['cortexide', 'CortexIDE'],
			'resources/linux/cortexide.desktop': ['CortexIDE'],
			'resources/linux/cortexide-insider.desktop': ['CortexIDE'],
			'resources/linux/cortexide.appdata.xml': ['CortexIDE'],
			'resources/linux/cortexide-insider.appdata.xml': ['CortexIDE']
		},
		windows: {
			'build/windows/msi/vscodium.wxs': ['cortexide', 'CortexIDE'],
			'build/windows/msi/vscodium.xsl': ['cortexide', 'CortexIDE'],
			'build/windows/package.sh': ['cortexide', 'CortexIDE']
		}
	},

	// Test scenarios
	testScenarios: [
		{
			name: 'File Existence Check',
			description: 'Verify all required files exist',
			type: 'existence'
		},
		{
			name: 'Branding Consistency Check',
			description: 'Verify CortexIDE branding is consistent across platforms',
			type: 'branding'
		},
		{
			name: 'Script Syntax Check',
			description: 'Verify packaging scripts have valid syntax',
			type: 'syntax'
		},
		{
			name: 'Asset Preparation Check',
			description: 'Verify asset preparation scripts work correctly',
			type: 'assets'
		},
		{
			name: 'Cross-Platform Consistency Check',
			description: 'Verify consistency across all platforms',
			type: 'consistency'
		}
	],

	// Expected file counts
	expectedFileCounts: {
		'src/stable': 88, // Based on project structure
		'src/insider': 88, // Based on project structure
		'build/windows/msi/i18n': 10 // Number of localization files
	},

	// Test thresholds
	thresholds: {
		minRequiredFiles: 0.8, // 80% of required files must exist
		minBrandingConsistency: 0.9, // 90% of files must have correct branding
		minScriptValidity: 1.0, // 100% of scripts must have valid syntax
		minAssetCompleteness: 0.8 // 80% of assets must be present
	}
};

// Test result interface
export interface PackagingTestResult {
	platform: string;
	testType: string;
	passed: boolean;
	message: string;
	details?: any;
}

// Test configuration interface
export interface PackagingTestConfig {
	platform: string;
	testTypes: string[];
	includeOptional: boolean;
	strictMode: boolean;
}

// Default test configuration
export const DEFAULT_PACKAGING_TEST_CONFIG: PackagingTestConfig = {
	platform: 'all',
	testTypes: ['existence', 'branding', 'syntax', 'assets', 'consistency'],
	includeOptional: true,
	strictMode: false
};
