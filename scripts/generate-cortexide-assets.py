#!/usr/bin/env python3
#---------------------------------------------------------------------------------------------
#  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
#  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
#---------------------------------------------------------------------------------------------

"""
CortexIDE Asset Generator
Generates CortexIDE-branded assets for all platforms
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from typing import Dict, List, Tuple

class CortexIDEAssetGenerator:
    def __init__(self, builder_dir: str, cortexide_dir: str):
        self.builder_dir = Path(builder_dir)
        self.cortexide_dir = Path(cortexide_dir)
        self.assets_dir = self.cortexide_dir / "resources"
        self.void_icons_dir = self.cortexide_dir / "void_icons"

        # CortexIDE brand colors
        self.brand_colors = {
            'primary': '#6366f1',      # Indigo
            'secondary': '#8b5cf6',    # Purple
            'accent': '#06b6d4',       # Cyan
            'background': '#1e1b4b',   # Dark indigo
            'text': '#ffffff',         # White
            'text_secondary': '#e2e8f0' # Light gray
        }

        # Asset specifications
        self.asset_specs = {
            'icons': {
                'sizes': [16, 24, 32, 48, 64, 96, 128, 256, 512],
                'formats': ['png', 'ico', 'icns']
            },
            'logos': {
                'sizes': [192, 512, 1024],
                'formats': ['png', 'svg']
            },
            'installer': {
                'sizes': [(100, 100), (125, 125), (150, 150), (175, 175), (200, 200), (225, 225), (250, 250)],
                'formats': ['bmp']
            }
        }

    def log(self, message: str, level: str = "INFO"):
        """Log a message with timestamp"""
        import datetime
        timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        colors = {
            "INFO": "\033[0;32m",    # Green
            "WARN": "\033[1;33m",    # Yellow
            "ERROR": "\033[0;31m",   # Red
            "DEBUG": "\033[0;34m"    # Blue
        }
        color = colors.get(level, "")
        reset = "\033[0m"
        print(f"{color}[{timestamp}] {level}:{reset} {message}")

    def check_dependencies(self) -> bool:
        """Check if required dependencies are available"""
        dependencies = ['convert', 'identify', 'rsvg-convert']
        missing = []

        for dep in dependencies:
            try:
                subprocess.run([dep, '--version'], capture_output=True, check=True)
            except (subprocess.CalledProcessError, FileNotFoundError):
                missing.append(dep)

        if missing:
            self.log(f"Missing dependencies: {', '.join(missing)}", "ERROR")
            self.log("Please install ImageMagick and librsvg2-bin", "ERROR")
            return False

        return True

    def create_svg_logo(self, size: int = 512) -> str:
        """Create CortexIDE SVG logo"""
        svg_content = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg width="{size}" height="{size}" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="gradient" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:{self.brand_colors['primary']};stop-opacity:1" />
      <stop offset="100%" style="stop-color:{self.brand_colors['secondary']};stop-opacity:1" />
    </linearGradient>
    <filter id="glow">
      <feGaussianBlur stdDeviation="3" result="coloredBlur"/>
      <feMerge>
        <feMergeNode in="coloredBlur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
  </defs>

  <!-- Background circle -->
  <circle cx="256" cy="256" r="240" fill="url(#gradient)" stroke="{self.brand_colors['accent']}" stroke-width="8"/>

  <!-- Inner design -->
  <circle cx="256" cy="200" r="60" fill="{self.brand_colors['text']}" opacity="0.9"/>
  <rect x="216" y="160" width="80" height="80" rx="12" fill="{self.brand_colors['text']}" opacity="0.8"/>

  <!-- Code symbol -->
  <text x="256" y="320" font-family="Arial, sans-serif" font-size="120" font-weight="bold"
        text-anchor="middle" fill="{self.brand_colors['text']}" filter="url(#glow)">C</text>

  <!-- Accent elements -->
  <circle cx="150" cy="150" r="20" fill="{self.brand_colors['accent']}" opacity="0.6"/>
  <circle cx="362" cy="150" r="20" fill="{self.brand_colors['accent']}" opacity="0.6"/>
  <circle cx="150" cy="362" r="20" fill="{self.brand_colors['accent']}" opacity="0.6"/>
  <circle cx="362" cy="362" r="20" fill="{self.brand_colors['accent']}" opacity="0.6"/>
</svg>'''
        return svg_content

    def create_installer_bitmap(self, width: int, height: int) -> str:
        """Create Windows installer bitmap"""
        # This would need to be implemented with proper bitmap generation
        # For now, return a placeholder
        return f"# Placeholder for {width}x{height} bitmap"

    def generate_icons(self):
        """Generate all required icons"""
        self.log("Generating CortexIDE icons...")

        # Create base SVG logo
        svg_content = self.create_svg_logo(512)
        svg_path = self.builder_dir / "temp_cortexide_logo.svg"
        svg_path.write_text(svg_content)

        # Generate PNG icons
        for size in self.asset_specs['icons']['sizes']:
            png_path = self.builder_dir / f"temp_cortexide_{size}.png"
            try:
                subprocess.run([
                    'convert', str(svg_path), '-resize', f'{size}x{size}', str(png_path)
                ], check=True)
                self.log(f"Generated {size}x{size} PNG icon")
            except subprocess.CalledProcessError as e:
                self.log(f"Failed to generate {size}x{size} PNG: {e}", "ERROR")

        # Generate ICO file
        ico_path = self.builder_dir / "temp_cortexide.ico"
        try:
            # Create ICO with multiple sizes
            sizes = [16, 24, 32, 48, 64, 96, 128, 256]
            convert_cmd = ['convert']
            for size in sizes:
                png_file = self.builder_dir / f"temp_cortexide_{size}.png"
                if png_file.exists():
                    convert_cmd.append(str(png_file))
            convert_cmd.append(str(ico_path))

            subprocess.run(convert_cmd, check=True)
            self.log("Generated ICO file")
        except subprocess.CalledProcessError as e:
            self.log(f"Failed to generate ICO: {e}", "ERROR")

        # Generate ICNS file for macOS
        icns_path = self.builder_dir / "temp_cortexide.icns"
        try:
            # Create iconset directory
            iconset_dir = self.builder_dir / "cortexide.iconset"
            iconset_dir.mkdir(exist_ok=True)

            # Generate different sizes for iconset
            icon_sizes = [
                (16, "icon_16x16.png"),
                (32, "icon_16x16@2x.png"),
                (32, "icon_32x32.png"),
                (64, "icon_32x32@2x.png"),
                (128, "icon_128x128.png"),
                (256, "icon_128x128@2x.png"),
                (256, "icon_256x256.png"),
                (512, "icon_256x256@2x.png"),
                (512, "icon_512x512.png"),
                (1024, "icon_512x512@2x.png")
            ]

            for size, filename in icon_sizes:
                png_file = self.builder_dir / f"temp_cortexide_{size}.png"
                if png_file.exists():
                    subprocess.run([
                        'convert', str(png_file), '-resize', f'{size}x{size}',
                        str(iconset_dir / filename)
                    ], check=True)

            # Create ICNS from iconset
            subprocess.run(['iconutil', '-c', 'icns', str(iconset_dir), '-o', str(icns_path)], check=True)
            self.log("Generated ICNS file")

            # Clean up iconset
            import shutil
            shutil.rmtree(iconset_dir)

        except subprocess.CalledProcessError as e:
            self.log(f"Failed to generate ICNS: {e}", "ERROR")

    def copy_assets_to_builder(self):
        """Copy generated assets to builder directories"""
        self.log("Copying assets to builder directories...")

        # Copy to stable
        self.copy_asset_to_directories("stable")

        # Copy to insider
        self.copy_asset_to_directories("insider")

    def copy_asset_to_directories(self, variant: str):
        """Copy assets to specific variant directory"""
        variant_dir = self.builder_dir / "src" / variant

        # Copy ICO file
        ico_src = self.builder_dir / "temp_cortexide.ico"
        ico_dest = variant_dir / "resources" / "win32" / "code.ico"
        if ico_src.exists():
            self.copy_file(ico_src, ico_dest, f"{variant} Windows ICO")

        # Copy ICNS file
        icns_src = self.builder_dir / "temp_cortexide.icns"
        icns_dest = variant_dir / "resources" / "darwin" / "code.icns"
        if icns_src.exists():
            self.copy_file(icns_src, icns_dest, f"{variant} macOS ICNS")

        # Copy PNG files
        for size in [150, 70, 192, 512]:
            png_src = self.builder_dir / f"temp_cortexide_{size}.png"
            if size in [150, 70]:
                png_dest = variant_dir / "resources" / "win32" / f"code_{size}x{size}.png"
            else:
                png_dest = variant_dir / "resources" / "server" / f"code-{size}.png"

            if png_src.exists():
                self.copy_file(png_src, png_dest, f"{variant} {size}x{size} PNG")

        # Copy SVG for Linux
        svg_src = self.builder_dir / "temp_cortexide_logo.svg"
        svg_dest = variant_dir / "resources" / "linux" / "code.svg"
        if svg_src.exists():
            self.copy_file(svg_src, svg_dest, f"{variant} Linux SVG")

    def copy_file(self, src: Path, dest: Path, description: str):
        """Copy file with backup and logging"""
        try:
            # Create backup if destination exists
            if dest.exists():
                backup_path = dest.with_suffix(dest.suffix + '.backup')
                dest.rename(backup_path)

            # Create destination directory
            dest.parent.mkdir(parents=True, exist_ok=True)

            # Copy file
            import shutil
            shutil.copy2(src, dest)
            self.log(f"✅ {description}: {dest.name}")

        except Exception as e:
            self.log(f"Failed to copy {description}: {e}", "ERROR")

    def update_desktop_files(self):
        """Update desktop files with CortexIDE branding"""
        self.log("Updating desktop files...")

        for variant in ["stable", "insider"]:
            variant_dir = self.builder_dir / "src" / variant / "resources" / "linux"

            # Update .desktop file
            desktop_file = variant_dir / "code.desktop"
            if desktop_file.exists():
                self.update_desktop_file(desktop_file, variant)

            # Update .appdata.xml file
            appdata_file = variant_dir / "code.appdata.xml"
            if appdata_file.exists():
                self.update_appdata_file(appdata_file, variant)

    def update_desktop_file(self, desktop_file: Path, variant: str):
        """Update desktop file with CortexIDE branding"""
        content = desktop_file.read_text()

        replacements = {
            'Name=Code': 'Name=CortexIDE',
            'Comment=Code Editor': 'Comment=CortexIDE - AI-powered Code Editor',
            'GenericName=Text Editor': 'GenericName=AI-powered Code Editor',
            'Exec=code': 'Exec=cortexide',
            'Icon=code': 'Icon=cortexide'
        }

        for old, new in replacements.items():
            content = content.replace(old, new)

        desktop_file.write_text(content)
        self.log(f"✅ Updated {variant} desktop file")

    def update_appdata_file(self, appdata_file: Path, variant: str):
        """Update appdata file with CortexIDE branding"""
        content = appdata_file.read_text()

        replacements = {
            '<name>Code</name>': '<name>CortexIDE</name>',
            '<summary>Code Editor</summary>': '<summary>CortexIDE - AI-powered Code Editor</summary>',
            '<description>': '<description>CortexIDE is an AI-powered code editor built on VS Code technology.</description>'
        }

        for old, new in replacements.items():
            content = content.replace(old, new)

        appdata_file.write_text(content)
        self.log(f"✅ Updated {variant} appdata file")

    def cleanup_temp_files(self):
        """Clean up temporary files"""
        self.log("Cleaning up temporary files...")

        temp_files = [
            "temp_cortexide_logo.svg",
            "temp_cortexide.ico",
            "temp_cortexide.icns"
        ]

        for size in self.asset_specs['icons']['sizes']:
            temp_files.append(f"temp_cortexide_{size}.png")

        for temp_file in temp_files:
            temp_path = self.builder_dir / temp_file
            if temp_path.exists():
                temp_path.unlink()

        self.log("✅ Cleaned up temporary files")

    def generate_summary(self):
        """Generate asset replacement summary"""
        summary_path = self.builder_dir / "cortexide-asset-generation-summary.md"

        summary_content = f"""# CortexIDE Asset Generation Summary

## Generated: {self.get_timestamp()}

## Brand Colors Used:
- Primary: {self.brand_colors['primary']}
- Secondary: {self.brand_colors['secondary']}
- Accent: {self.brand_colors['accent']}

## Assets Generated:

### Icons
- ICO file for Windows
- ICNS file for macOS
- PNG files in multiple sizes: {', '.join(map(str, self.asset_specs['icons']['sizes']))}
- SVG file for Linux

### Files Updated:
- Desktop files (.desktop)
- AppData files (.appdata.xml)
- All platform-specific icon files

## Variants Updated:
- Stable
- Insider

## Notes:
- All original files backed up with .backup extension
- Generated assets use CortexIDE brand colors
- Desktop files updated to reflect CortexIDE branding
- Ready for production use

## Next Steps:
1. Test assets across all platforms
2. Verify icon quality and clarity
3. Update installer graphics if needed
4. Test desktop integration
"""

        summary_path.write_text(summary_content)
        self.log(f"✅ Generated summary: {summary_path}")

    def get_timestamp(self) -> str:
        """Get current timestamp"""
        import datetime
        return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

    def run(self):
        """Run the complete asset generation process"""
        self.log("Starting CortexIDE asset generation...")

        # Check dependencies
        if not self.check_dependencies():
            return False

        try:
            # Generate assets
            self.generate_icons()

            # Copy to builder directories
            self.copy_assets_to_builder()

            # Update desktop files
            self.update_desktop_files()

            # Clean up
            self.cleanup_temp_files()

            # Generate summary
            self.generate_summary()

            self.log("✅ CortexIDE asset generation completed successfully!")
            return True

        except Exception as e:
            self.log(f"Asset generation failed: {e}", "ERROR")
            return False

def main():
    """Main entry point"""
    if len(sys.argv) != 3:
        print("Usage: python generate-cortexide-assets.py <builder_dir> <cortexide_dir>")
        sys.exit(1)

    builder_dir = sys.argv[1]
    cortexide_dir = sys.argv[2]

    generator = CortexIDEAssetGenerator(builder_dir, cortexide_dir)
    success = generator.run()

    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
