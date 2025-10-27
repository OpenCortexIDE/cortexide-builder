# Cross-Platform Packaging Tests

This directory contains comprehensive tests for CortexIDE's cross-platform packaging system, ensuring consistent builds across macOS, Linux, and Windows.

## Overview

The packaging tests verify:
- **File Existence**: All required packaging files are present
- **Branding Consistency**: CortexIDE branding is consistent across platforms
- **Script Syntax**: Packaging scripts have valid syntax
- **Asset Preparation**: Asset preparation scripts work correctly
- **Cross-Platform Consistency**: Consistency across all platforms

## Test Structure

### Bash Test Script (`scripts/test-packaging-crossplatform.sh`)
- **Purpose**: Platform-specific packaging validation
- **Coverage**: 
  - macOS: Bundle structure, resources, build configuration
  - Linux: AppImage, desktop files, AppStream metadata
  - Windows: MSI installer, resources, localization

### Node.js Test Runner (`packaging-test-runner.js`)
- **Purpose**: Comprehensive cross-platform testing
- **Coverage**:
  - File existence validation
  - Branding consistency checks
  - Script syntax validation
  - Asset completeness verification
  - Cross-platform consistency analysis

### Test Configuration (`packaging-test-config.ts`)
- **Purpose**: Centralized test configuration
- **Contains**:
  - Platform-specific file requirements
  - Branding patterns and keywords
  - Test thresholds and scenarios
  - Expected file counts and structures

## Running Tests

### Using Node.js Test Runner
```bash
# Run all tests
npm test

# Test specific platform
npm run test:macos
npm run test:linux
npm run test:windows

# Test specific functionality
npm run test:consistency
npm run test:branding

# Run with detailed output
npm run test:strict
```

### Using Bash Test Script
```bash
# Run all tests
./scripts/test-packaging-crossplatform.sh

# Test specific platform
./scripts/test-packaging-crossplatform.sh macos
./scripts/test-packaging-crossplatform.sh linux
./scripts/test-packaging-crossplatform.sh windows

# Check prerequisites only
./scripts/test-packaging-crossplatform.sh --check
```

### Manual Test Execution

#### Node.js Tests
```bash
cd test
node packaging-test-runner.js
node packaging-test-runner.js --platform macos
node packaging-test-runner.js --test-types existence,branding
node packaging-test-runner.js --strict
```

#### Bash Tests
```bash
cd scripts
./test-packaging-crossplatform.sh
./test-packaging-crossplatform.sh macos
./test-packaging-crossplatform.sh --check
```

## Test Coverage

### Platform Coverage
- ✅ **macOS**: Bundle structure, resources, build configuration
- ✅ **Linux**: AppImage, desktop files, AppStream metadata, package scripts
- ✅ **Windows**: MSI installer, resources, localization files

### File Coverage
- ✅ **Required Files**: All platform-specific required files
- ✅ **Optional Files**: Platform-specific optional files (when enabled)
- ✅ **Build Scripts**: Packaging and build scripts
- ✅ **Asset Directories**: Source asset directories
- ✅ **Resources**: Platform-specific resources and icons

### Branding Coverage
- ✅ **Product Configuration**: product.json, package.json
- ✅ **Build Scripts**: build.sh, build_cli.sh
- ✅ **Asset Scripts**: prepare_*.sh scripts
- ✅ **Platform-Specific**: Platform-specific branding files

### Consistency Coverage
- ✅ **Cross-Platform Branding**: Consistent branding across platforms
- ✅ **Version Information**: Consistent version information
- ✅ **Build Scripts**: Consistent build script behavior
- ✅ **Asset Preparation**: Consistent asset preparation

## Test Configuration

### Platform Requirements

#### macOS
- Bundle structure files
- Icon resources (.icns, .iconset)
- Build configuration (include.gypi)

#### Linux
- AppImage build scripts and recipe
- Desktop files (.desktop)
- AppStream metadata (.appdata.xml)
- Package scripts (package_bin.sh, package_reh.sh)

#### Windows
- MSI installer configuration (.wxs, .xsl)
- MSI resources (banners, dialogs)
- Localization files (.wxl)
- Package scripts

### Branding Requirements
- CortexIDE branding in all configuration files
- Consistent product names and descriptions
- Proper icon and resource branding
- Correct build script branding

### Test Thresholds
- **File Existence**: 80% of required files must exist
- **Branding Consistency**: 90% of files must have correct branding
- **Script Validity**: 100% of scripts must have valid syntax
- **Asset Completeness**: 80% of assets must be present

## Test Scenarios

### File Existence Check
Verifies all required packaging files exist for each platform.

### Branding Consistency Check
Ensures CortexIDE branding is consistent across all platforms and files.

### Script Syntax Check
Validates that all packaging scripts have correct syntax.

### Asset Preparation Check
Verifies asset preparation scripts work correctly and assets are present.

### Cross-Platform Consistency Check
Ensures consistency across all platforms and build configurations.

## Prerequisites

### Required Software
- Node.js (v16 or higher)
- npm (v8 or higher)
- Bash shell
- Platform-specific tools (optional):
  - macOS: Xcode command line tools
  - Linux: dpkg/rpm, AppImage tool
  - Windows: NSIS

### Required Files
- All platform-specific packaging files
- Asset directories and resources
- Build and packaging scripts

## Test Results

### Output Format
Tests provide detailed output including:
- Test summary (total, passed, failed)
- Platform-specific results
- Detailed error messages
- File existence status
- Branding consistency issues
- Script syntax errors

### Success Criteria
- All required files exist
- Branding is consistent across platforms
- All scripts have valid syntax
- Assets are properly prepared
- Cross-platform consistency is maintained

## Troubleshooting

### Common Issues

#### Missing Files
- Check file paths in test configuration
- Verify files exist in correct locations
- Ensure proper file permissions

#### Branding Issues
- Verify CortexIDE branding in all files
- Check for typos in branding keywords
- Ensure consistent casing

#### Script Syntax Errors
- Validate bash script syntax
- Check for proper quoting and escaping
- Verify script permissions

#### Asset Issues
- Ensure asset directories exist
- Check asset file permissions
- Verify asset preparation scripts

### Debug Mode
Use `--strict` flag for detailed test results:
```bash
node packaging-test-runner.js --strict
```

## Contributing

### Adding New Tests
1. Update test configuration in `packaging-test-config.ts`
2. Add new test scenarios
3. Update platform requirements
4. Test on all platforms
5. Update documentation

### Test Guidelines
- Use descriptive test names
- Include both positive and negative test cases
- Test all supported platforms
- Ensure tests are deterministic
- Add appropriate error handling

### Debugging Tests
- Use `--strict` mode for detailed output
- Check test configuration
- Verify file paths and permissions
- Test individual components

## CI/CD Integration

### GitHub Actions
Tests are automatically run in CI/CD pipeline:
- Cross-platform tests on all supported platforms
- Branding consistency checks
- Script syntax validation
- Asset preparation verification

### Test Reports
Test results are available in:
- GitHub Actions logs
- Test output files
- Detailed error reports

## License

Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
Licensed under the Apache License, Version 2.0.
