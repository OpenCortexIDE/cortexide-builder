#!/usr/bin/env bash
# Diagnostic script to check for locked files in a DMG

set -e

DMG_PATH="${1}"

if [[ -z "${DMG_PATH}" ]]; then
  echo "Usage: $0 <path-to-dmg>"
  exit 1
fi

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "Error: DMG file not found: ${DMG_PATH}"
  exit 1
fi

echo "=== Checking DMG: ${DMG_PATH} ==="
echo ""

# Mount the DMG
MOUNT_POINT=$(mktemp -d)
echo "Mounting DMG to: ${MOUNT_POINT}"

hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_POINT}" -quiet

# Find the app bundle
APP_BUNDLE=$(find "${MOUNT_POINT}" -name "*.app" -type d | head -n 1)

if [[ -z "${APP_BUNDLE}" ]]; then
  echo "Error: App bundle not found in DMG"
  hdiutil detach "${MOUNT_POINT}" -quiet
  rmdir "${MOUNT_POINT}"
  exit 1
fi

echo "Found app bundle: ${APP_BUNDLE}"
echo ""

# Check for locked files
echo "=== Checking for locked files ==="
LOCKED_FILES=$(find "${APP_BUNDLE}" -flags +uchg 2>/dev/null || true)

if [[ -n "${LOCKED_FILES}" ]]; then
  LOCKED_COUNT=$(echo "${LOCKED_FILES}" | wc -l | tr -d ' ')
  echo "⚠ ERROR: Found ${LOCKED_COUNT} locked files!"
  echo ""
  echo "First 10 locked files:"
  echo "${LOCKED_FILES}" | head -10 | sed 's/^/  /'
  echo ""
  echo "These files will cause installation errors!"
else
  echo "✓ No locked files found"
fi

echo ""

# Check for read-only files
echo "=== Checking for read-only files ==="
READONLY_FILES=$(find "${APP_BUNDLE}" -type f ! -perm -u+w 2>/dev/null || true)

if [[ -n "${READONLY_FILES}" ]]; then
  READONLY_COUNT=$(echo "${READONLY_FILES}" | wc -l | tr -d ' ')
  echo "⚠ WARNING: Found ${READONLY_COUNT} read-only files!"
  echo ""
  echo "First 10 read-only files:"
  echo "${READONLY_FILES}" | head -10 | sed 's/^/  /'
else
  echo "✓ No read-only files found"
fi

echo ""

# Check extended attributes
echo "=== Checking extended attributes ==="
FILES_WITH_XATTR=$(find "${APP_BUNDLE}" -type f -exec sh -c 'xattr -l "$1" >/dev/null 2>&1 && echo "$1"' _ {} \; 2>/dev/null | head -5 || true)

if [[ -n "${FILES_WITH_XATTR}" ]]; then
  echo "Files with extended attributes (first 5):"
  echo "${FILES_WITH_XATTR}" | sed 's/^/  /'
  echo ""
  echo "Checking for problematic attributes..."
  for FILE in ${FILES_WITH_XATTR}; do
    XATTRS=$(xattr -l "${FILE}" 2>/dev/null || true)
    if echo "${XATTRS}" | grep -q "com.apple.quarantine\|com.apple.FinderInfo"; then
      echo "  ${FILE}:"
      echo "${XATTRS}" | grep -E "com.apple.quarantine|com.apple.FinderInfo" | sed 's/^/    /'
    fi
  done
else
  echo "✓ No extended attributes found (or xattr not available)"
fi

# Unmount
echo ""
echo "Unmounting DMG..."
hdiutil detach "${MOUNT_POINT}" -quiet
rmdir "${MOUNT_POINT}"

echo ""
echo "=== Check complete ==="

