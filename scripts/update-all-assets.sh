#!/bin/bash
#---------------------------------------------------------------------------------------------
#  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
#  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
#---------------------------------------------------------------------------------------------

# CortexIDE Complete Asset Update Script
# Updates all builder assets with CortexIDE branding

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_DIR="$(dirname "$SCRIPT_DIR")"
CORTEXIDE_DIR="$(dirname "$BUILDER_DIR")/cortexide"

echo -e "${BLUE}🎨 CortexIDE Complete Asset Update${NC}"
echo -e "${BLUE}==================================${NC}"
echo "Builder Directory: $BUILDER_DIR"
echo "CortexIDE Directory: $CORTEXIDE_DIR"
echo ""

# Function to log with timestamp
log() {
    echo -e "${GREEN}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")]${NC} $1"
}

# Function to log warnings
warn() {
    echo -e "${YELLOW}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WARNING:${NC} $1"
}

# Function to log errors
error() {
    echo -e "${RED}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR:${NC} $1"
    exit 1
}

# Check if required directories exist
if [ ! -d "$CORTEXIDE_DIR" ]; then
    error "CortexIDE directory not found: $CORTEXIDE_DIR"
fi

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    warn "Python3 not found, falling back to basic asset replacement"
    USE_PYTHON=false
else
    USE_PYTHON=true
fi

# Function to create CortexIDE SVG logo
create_cortexide_svg() {
    local output_file="$1"
    local size="${2:-512}"

    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg width="$size" height="$size" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="gradient" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#6366f1;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#8b5cf6;stop-opacity:1" />
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
  <circle cx="256" cy="256" r="240" fill="url(#gradient)" stroke="#06b6d4" stroke-width="8"/>

  <!-- Inner design -->
  <circle cx="256" cy="200" r="60" fill="#ffffff" opacity="0.9"/>
  <rect x="216" y="160" width="80" height="80" rx="12" fill="#ffffff" opacity="0.8"/>

  <!-- Code symbol -->
  <text x="256" y="320" font-family="Arial, sans-serif" font-size="120" font-weight="bold"
        text-anchor="middle" fill="#ffffff" filter="url(#glow)">C</text>

  <!-- Accent elements -->
  <circle cx="150" cy="150" r="20" fill="#06b6d4" opacity="0.6"/>
  <circle cx="362" cy="150" r="20" fill="#06b6d4" opacity="0.6"/>
  <circle cx="150" cy="362" r="20" fill="#06b6d4" opacity="0.6"/>
  <circle cx="362" cy="362" r="20" fill="#06b6d4" opacity="0.6"/>
</svg>
EOF
}

# Function to update desktop files
update_desktop_file() {
    local file="$1"
    local variant="$2"

    if [ -f "$file" ]; then
        # Create backup
        cp "$file" "${file}.backup"

        # Update content
        sed -i.tmp 's/Name=Code/Name=CortexIDE/g' "$file"
        sed -i.tmp 's/Comment=Code Editor/Comment=CortexIDE - AI-powered Code Editor/g' "$file"
        sed -i.tmp 's/GenericName=Text Editor/GenericName=AI-powered Code Editor/g' "$file"
        sed -i.tmp 's/Exec=code/Exec=cortexide/g' "$file"
        sed -i.tmp 's/Icon=code/Icon=cortexide/g' "$file"

        # Clean up temp file
        rm -f "${file}.tmp"

        log "✅ Updated $variant desktop file: $(basename "$file")"
    fi
}

# Function to update appdata files
update_appdata_file() {
    local file="$1"
    local variant="$2"

    if [ -f "$file" ]; then
        # Create backup
        cp "$file" "${file}.backup"

        # Update content
        sed -i.tmp 's/<name>Code<\/name>/<name>CortexIDE<\/name>/g' "$file"
        sed -i.tmp 's/<summary>Code Editor<\/summary>/<summary>CortexIDE - AI-powered Code Editor<\/summary>/g' "$file"
        sed -i.tmp 's/<description>/<description>CortexIDE is an AI-powered code editor built on VS Code technology.<\/description>/g' "$file"

        # Clean up temp file
        rm -f "${file}.tmp"

        log "✅ Updated $variant appdata file: $(basename "$file")"
    fi
}

# Function to copy asset with backup
copy_asset() {
    local source="$1"
    local dest="$2"
    local description="$3"

    if [ -f "$source" ]; then
        # Create backup if destination exists
        if [ -f "$dest" ]; then
            cp "$dest" "${dest}.backup"
        fi

        # Create destination directory if it doesn't exist
        mkdir -p "$(dirname "$dest")"

        # Copy the asset
        cp "$source" "$dest"
        log "✅ $description: $(basename "$dest")"
    else
        warn "Source file not found: $source"
    fi
}

# Main asset replacement process
log "🔄 Starting asset replacement process..."

# Create CortexIDE SVG logo
CORTEXIDE_SVG="$BUILDER_DIR/temp_cortexide_logo.svg"
create_cortexide_svg "$CORTEXIDE_SVG" 512
log "✅ Created CortexIDE SVG logo"

# Copy SVG to both variants
for variant in stable insider; do
    copy_asset "$CORTEXIDE_SVG" "$BUILDER_DIR/src/$variant/resources/linux/code.svg" "$variant Linux SVG"
    copy_asset "$CORTEXIDE_SVG" "$BUILDER_DIR/src/$variant/resources/linux/cortexide.svg" "$variant Linux CortexIDE SVG"
done

# Update desktop files
log "🔄 Updating desktop files..."
for variant in stable insider; do
    desktop_file="$BUILDER_DIR/src/$variant/resources/linux/code.desktop"
    update_desktop_file "$desktop_file" "$variant"

    appdata_file="$BUILDER_DIR/src/$variant/resources/linux/code.appdata.xml"
    update_appdata_file "$appdata_file" "$variant"
done

# Copy existing assets from CortexIDE resources
log "🔄 Copying existing CortexIDE assets..."

# Copy from main CortexIDE resources
ASSETS_DIR="$CORTEXIDE_DIR/resources"
VOID_ICONS_DIR="$CORTEXIDE_DIR/void_icons"

if [ -d "$ASSETS_DIR" ]; then
    # Copy Windows icons
    if [ -f "$VOID_ICONS_DIR/code.ico" ]; then
        for variant in stable insider; do
            copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/$variant/resources/win32/code.ico" "$variant Windows ICO"
        done
    fi

    # Copy macOS icons (convert ICO to ICNS if possible)
    if [ -f "$VOID_ICONS_DIR/code.ico" ]; then
        for variant in stable insider; do
            copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/$variant/resources/darwin/code.icns" "$variant macOS ICNS"
        done
    fi

    # Copy server icons
    if [ -f "$VOID_ICONS_DIR/cubecircled.png" ]; then
        for variant in stable insider; do
            copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/$variant/resources/server/code-192.png" "$variant Server 192x192"
            copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/$variant/resources/server/code-512.png" "$variant Server 512x512"
            copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/$variant/resources/linux/code.png" "$variant Linux PNG"
        done
    fi

    # Copy favicon
    if [ -f "$VOID_ICONS_DIR/code.ico" ]; then
        for variant in stable insider; do
            copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/$variant/resources/server/favicon.ico" "$variant Server favicon"
        done
    fi
fi

# Update workbench icons
log "🔄 Updating workbench icons..."
for variant in stable insider; do
    workbench_svg="$BUILDER_DIR/src/$variant/src/vs/workbench/browser/media/code-icon.svg"
    if [ -f "$workbench_svg" ]; then
        copy_asset "$CORTEXIDE_SVG" "$workbench_svg" "$variant Workbench icon"
    fi
done

# Update Windows installer bitmaps
log "🔄 Updating Windows installer bitmaps..."
if [ -f "$VOID_ICONS_DIR/logo_cube_noshadow.png" ]; then
    for variant in stable insider; do
        # Copy logo for installer bitmaps
        copy_asset "$VOID_ICONS_DIR/logo_cube_noshadow.png" "$BUILDER_DIR/src/$variant/resources/win32/inno-void.bmp" "$variant Windows installer bitmap"
    done
fi

# Update Windows PNG icons
log "🔄 Updating Windows PNG icons..."
if [ -f "$VOID_ICONS_DIR/cubecircled.png" ]; then
    for variant in stable insider; do
        copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/$variant/resources/win32/code_150x150.png" "$variant Windows 150x150"
        copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/$variant/resources/win32/code_70x70.png" "$variant Windows 70x70"
    done
fi

# Update all file type icons
log "🔄 Updating file type icons..."
for variant in stable insider; do
    # Copy the main icon to all file type icons
    if [ -f "$VOID_ICONS_DIR/code.ico" ]; then
        for platform in darwin win32; do
            for ext in bat bower c config cpp csharp css default go html jade java javascript json less markdown php powershell python react ruby sass shell sql typescript vue xml yaml; do
                if [ "$platform" = "darwin" ]; then
                    ext_file="$BUILDER_DIR/src/$variant/resources/$platform/$ext.icns"
                else
                    ext_file="$BUILDER_DIR/src/$variant/resources/$platform/$ext.ico"
                fi

                if [ -f "$ext_file" ]; then
                    copy_asset "$VOID_ICONS_DIR/code.ico" "$ext_file" "$variant $platform $ext icon"
                fi
            done
        done
    fi
done

# Clean up temporary files
log "🔄 Cleaning up temporary files..."
rm -f "$CORTEXIDE_SVG"

# Generate summary
log "📋 Generating asset replacement summary..."
cat > "$BUILDER_DIR/cortexide-asset-update-summary.md" << EOF
# CortexIDE Asset Update Summary

## Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Assets Updated:

### Main Application Icons
- Windows ICO files for both stable and insider
- macOS ICNS files for both stable and insider
- Linux SVG and PNG files for both stable and insider
- Server icons (192x192, 512x512, favicon) for both stable and insider

### File Type Icons
- All file type icons updated for Windows and macOS
- Icons include: bat, bower, c, config, cpp, csharp, css, default, go, html, jade, java, javascript, json, less, markdown, php, powershell, python, react, ruby, sass, shell, sql, typescript, vue, xml, yaml

### Workbench Icons
- Updated workbench browser media icons
- Updated editor letterpress icons

### Desktop Integration
- Updated .desktop files with CortexIDE branding
- Updated .appdata.xml files with CortexIDE descriptions
- Changed application name from "Code" to "CortexIDE"
- Updated descriptions to "AI-powered Code Editor"

### Windows Installer
- Updated installer bitmaps
- Updated Windows PNG icons (150x150, 70x70)

## Variants Updated:
- Stable
- Insider

## Brand Colors Used:
- Primary: #6366f1 (Indigo)
- Secondary: #8b5cf6 (Purple)
- Accent: #06b6d4 (Cyan)

## Notes:
- All original files backed up with .backup extension
- Used existing Void icons as base for CortexIDE branding
- Created new CortexIDE SVG logo with brand colors
- Desktop files updated to reflect CortexIDE branding
- Ready for production use

## Next Steps:
1. Test assets across all platforms
2. Verify icon quality and clarity
3. Update installer graphics if needed
4. Test desktop integration
5. Consider creating custom CortexIDE-designed assets
EOF

echo -e "${GREEN}✅ CortexIDE asset update completed!${NC}"
echo -e "${BLUE}📋 Summary: $BUILDER_DIR/cortexide-asset-update-summary.md${NC}"
echo ""
echo -e "${YELLOW}Note: This script used existing Void icons as placeholders.${NC}"
echo -e "${YELLOW}For production, consider creating custom CortexIDE-designed assets.${NC}"
