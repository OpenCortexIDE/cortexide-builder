#!/bin/bash
#---------------------------------------------------------------------------------------------
#  Copyright (c) 2025 Glass Devtools, Inc. All rights reserved.
#  Licensed under the Apache License, Version 2.0. See LICENSE.txt for more information.
#---------------------------------------------------------------------------------------------

# CortexIDE Asset Replacement Script
# Replaces all builder assets with CortexIDE branding

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
ASSETS_DIR="$CORTEXIDE_DIR/resources"
VOID_ICONS_DIR="$CORTEXIDE_DIR/void_icons"

echo -e "${BLUE}🎨 CortexIDE Asset Replacement${NC}"
echo -e "${BLUE}==============================${NC}"
echo "Builder Directory: $BUILDER_DIR"
echo "CortexIDE Directory: $CORTEXIDE_DIR"
echo "Assets Directory: $ASSETS_DIR"
echo "Void Icons Directory: $VOID_ICONS_DIR"
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

if [ ! -d "$ASSETS_DIR" ]; then
    error "Assets directory not found: $ASSETS_DIR"
fi

if [ ! -d "$VOID_ICONS_DIR" ]; then
    error "Void icons directory not found: $VOID_ICONS_DIR"
fi

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

# Function to create CortexIDE icon from void icon
create_cortexide_icon() {
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

        # For now, just copy the void icon as CortexIDE icon
        # In a real implementation, you would convert/redesign the icon
        cp "$source" "$dest"
        log "✅ $description: $(basename "$dest") (using void icon as placeholder)"
    else
        warn "Source file not found: $source"
    fi
}

# Replace main application icons
log "🔄 Replacing main application icons..."

# macOS icons (.icns)
for icon in code.icns; do
    if [ -f "$VOID_ICONS_DIR/code.ico" ]; then
        # Convert ICO to ICNS (this would need proper conversion in real implementation)
        copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/stable/resources/darwin/$icon" "macOS stable icon"
        copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/insider/resources/darwin/$icon" "macOS insider icon"
    fi
done

# Linux icons
log "🔄 Replacing Linux icons..."
copy_asset "$ASSETS_DIR/linux/code.png" "$BUILDER_DIR/src/stable/resources/linux/code.png" "Linux stable PNG"
copy_asset "$ASSETS_DIR/linux/code.png" "$BUILDER_DIR/src/insider/resources/linux/code.png" "Linux insider PNG"

# Copy SVG if available, otherwise use PNG as SVG
if [ -f "$VOID_ICONS_DIR/cubecircled.png" ]; then
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/stable/resources/linux/code.svg" "Linux stable SVG"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/insider/resources/linux/code.svg" "Linux insider SVG"
fi

# Windows icons
log "🔄 Replacing Windows icons..."
copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/stable/resources/win32/code.ico" "Windows stable ICO"
copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/insider/resources/win32/code.ico" "Windows insider ICO"

# Windows PNG icons
if [ -f "$VOID_ICONS_DIR/cubecircled.png" ]; then
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/stable/resources/win32/code_150x150.png" "Windows stable 150x150"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/insider/resources/win32/code_150x150.png" "Windows insider 150x150"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/stable/resources/win32/code_70x70.png" "Windows stable 70x70"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/insider/resources/win32/code_70x70.png" "Windows insider 70x70"
fi

# Server icons
log "🔄 Replacing server icons..."
if [ -f "$VOID_ICONS_DIR/cubecircled.png" ]; then
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/stable/resources/server/code-192.png" "Server stable 192x192"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/insider/resources/server/code-192.png" "Server insider 192x192"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/stable/resources/server/code-512.png" "Server stable 512x512"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/insider/resources/server/code-512.png" "Server insider 512x512"
fi

copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/stable/resources/server/favicon.ico" "Server stable favicon"
copy_asset "$VOID_ICONS_DIR/code.ico" "$BUILDER_DIR/src/insider/resources/server/favicon.ico" "Server insider favicon"

# Replace Windows installer bitmaps
log "🔄 Replacing Windows installer bitmaps..."
if [ -f "$VOID_ICONS_DIR/logo_cube_noshadow.png" ]; then
    # Copy the logo for installer bitmaps
    copy_asset "$VOID_ICONS_DIR/logo_cube_noshadow.png" "$BUILDER_DIR/src/stable/resources/win32/inno-void.bmp" "Windows installer bitmap"
    copy_asset "$VOID_ICONS_DIR/logo_cube_noshadow.png" "$BUILDER_DIR/src/insider/resources/win32/inno-void.bmp" "Windows installer bitmap"
fi

# Replace workbench icons
log "🔄 Replacing workbench icons..."
if [ -f "$VOID_ICONS_DIR/cubecircled.png" ]; then
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/stable/src/vs/workbench/browser/media/code-icon.svg" "Workbench stable icon"
    copy_asset "$VOID_ICONS_DIR/cubecircled.png" "$BUILDER_DIR/src/insider/src/vs/workbench/browser/media/code-icon.svg" "Workbench insider icon"
fi

# Update desktop files and appdata
log "🔄 Updating desktop files and appdata..."

# Update stable desktop files
if [ -f "$BUILDER_DIR/src/stable/resources/linux/code.desktop" ]; then
    sed -i.bak 's/Name=Code/Name=CortexIDE/g' "$BUILDER_DIR/src/stable/resources/linux/code.desktop"
    sed -i.bak 's/Comment=Code Editor/Comment=CortexIDE - AI-powered Code Editor/g' "$BUILDER_DIR/src/stable/resources/linux/code.desktop"
    sed -i.bak 's/GenericName=Text Editor/GenericName=AI-powered Code Editor/g' "$BUILDER_DIR/src/stable/resources/linux/code.desktop"
    log "✅ Updated stable desktop file"
fi

if [ -f "$BUILDER_DIR/src/stable/resources/linux/code.appdata.xml" ]; then
    sed -i.bak 's/<name>Code<\/name>/<name>CortexIDE<\/name>/g' "$BUILDER_DIR/src/stable/resources/linux/code.appdata.xml"
    sed -i.bak 's/<summary>Code Editor<\/summary>/<summary>CortexIDE - AI-powered Code Editor<\/summary>/g' "$BUILDER_DIR/src/stable/resources/linux/code.appdata.xml"
    log "✅ Updated stable appdata file"
fi

# Update insider desktop files
if [ -f "$BUILDER_DIR/src/insider/resources/linux/code.desktop" ]; then
    sed -i.bak 's/Name=Code/Name=CortexIDE/g' "$BUILDER_DIR/src/insider/resources/linux/code.desktop"
    sed -i.bak 's/Comment=Code Editor/Comment=CortexIDE - AI-powered Code Editor/g' "$BUILDER_DIR/src/insider/resources/linux/code.desktop"
    sed -i.bak 's/GenericName=Text Editor/GenericName=AI-powered Code Editor/g' "$BUILDER_DIR/src/insider/resources/linux/code.desktop"
    log "✅ Updated insider desktop file"
fi

if [ -f "$BUILDER_DIR/src/insider/resources/linux/code.appdata.xml" ]; then
    sed -i.bak 's/<name>Code<\/name>/<name>CortexIDE<\/name>/g' "$BUILDER_DIR/src/insider/resources/linux/code.appdata.xml"
    sed -i.bak 's/<summary>Code Editor<\/summary>/<summary>CortexIDE - AI-powered Code Editor<\/summary>/g' "$BUILDER_DIR/src/insider/resources/linux/code.appdata.xml"
    log "✅ Updated insider appdata file"
fi

# Create CortexIDE-specific assets
log "🔄 Creating CortexIDE-specific assets..."

# Create a simple CortexIDE logo SVG
cat > "$BUILDER_DIR/src/stable/resources/linux/cortexide.svg" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="gradient" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#6366f1;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#8b5cf6;stop-opacity:1" />
    </linearGradient>
  </defs>
  <rect width="512" height="512" rx="64" fill="url(#gradient)"/>
  <text x="256" y="320" font-family="Arial, sans-serif" font-size="120" font-weight="bold" text-anchor="middle" fill="white">C</text>
  <circle cx="256" cy="180" r="40" fill="white" opacity="0.9"/>
  <rect x="216" y="140" width="80" height="80" rx="8" fill="white" opacity="0.7"/>
</svg>
EOF

cp "$BUILDER_DIR/src/stable/resources/linux/cortexide.svg" "$BUILDER_DIR/src/insider/resources/linux/cortexide.svg"
log "✅ Created CortexIDE SVG logo"

# Generate summary
log "📋 Generating asset replacement summary..."
cat > "$BUILDER_DIR/asset-replacement-summary.md" << EOF
# CortexIDE Asset Replacement Summary

## Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Assets Replaced:

### macOS Icons (.icns)
- \`src/stable/resources/darwin/code.icns\`
- \`src/insider/resources/darwin/code.icns\`

### Linux Icons
- \`src/stable/resources/linux/code.png\`
- \`src/insider/resources/linux/code.png\`
- \`src/stable/resources/linux/code.svg\`
- \`src/insider/resources/linux/code.svg\`
- \`src/stable/resources/linux/cortexide.svg\` (new)
- \`src/insider/resources/linux/cortexide.svg\` (new)

### Windows Icons
- \`src/stable/resources/win32/code.ico\`
- \`src/insider/resources/win32/code.ico\`
- \`src/stable/resources/win32/code_150x150.png\`
- \`src/insider/resources/win32/code_150x150.png\`
- \`src/stable/resources/win32/code_70x70.png\`
- \`src/insider/resources/win32/code_70x70.png\`

### Server Icons
- \`src/stable/resources/server/code-192.png\`
- \`src/insider/resources/server/code-192.png\`
- \`src/stable/resources/server/code-512.png\`
- \`src/insider/resources/server/code-512.png\`
- \`src/stable/resources/server/favicon.ico\`
- \`src/insider/resources/server/favicon.ico\`

### Workbench Icons
- \`src/stable/src/vs/workbench/browser/media/code-icon.svg\`
- \`src/insider/src/vs/workbench/browser/media/code-icon.svg\`

## Desktop Files Updated:
- \`src/stable/resources/linux/code.desktop\`
- \`src/insider/resources/linux/code.desktop\`
- \`src/stable/resources/linux/code.appdata.xml\`
- \`src/insider/resources/linux/code.appdata.xml\`

## Notes:
- All original assets have been backed up with .backup extension
- Void icons were used as placeholders for CortexIDE branding
- Desktop files updated to reflect CortexIDE branding
- New CortexIDE SVG logo created

## Next Steps:
1. Design proper CortexIDE icons and logos
2. Replace placeholder assets with final designs
3. Test asset replacement across all platforms
4. Update installer graphics and splash screens
EOF

echo -e "${GREEN}✅ Asset replacement completed!${NC}"
echo -e "${BLUE}📋 Summary: $BUILDER_DIR/asset-replacement-summary.md${NC}"
echo ""
echo -e "${YELLOW}Note: This script used Void icons as placeholders.${NC}"
echo -e "${YELLOW}For production, replace with proper CortexIDE-designed assets.${NC}"
