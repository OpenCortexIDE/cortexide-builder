#!/usr/bin/env bash
# Verifies that the macOS permission fix removes locked files before packaging.

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Skipping: macOS-only test"
  exit 0
fi

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
WORKDIR="$(mktemp -d)"
cleanup() {
  chflags -R nouchg "${WORKDIR}" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

APP_DIR="${WORKDIR}/VSCode-darwin-x64/TestApp.app"
DMG_LOCKED="${WORKDIR}/locked.dmg"
DMG_UNLOCKED="${WORKDIR}/unlocked.dmg"

echo "+ Creating test app bundle with problematic files"
mkdir -p "${APP_DIR}/Contents/Resources/app"
touch "${APP_DIR}/Contents/Resources/app/locked.txt"
chmod 400 "${APP_DIR}/Contents/Resources/app/locked.txt"

echo "+ Creating DMG with read-only file (should fail permission check)"
hdiutil create -fs HFS+ -srcfolder "${APP_DIR}" "${DMG_LOCKED}" -quiet
set +e
"${ROOT_DIR}/check_dmg_permissions.sh" "${DMG_LOCKED}"
RESULT=$?
set -e
if [[ "${RESULT}" -eq 0 ]]; then
  echo "Expected check_dmg_permissions.sh to fail on read-only DMG" >&2
  exit 1
fi

echo "+ Adding locked flag to file (simulating worst-case)"
chflags uchg "${APP_DIR}/Contents/Resources/app/locked.txt"
set +e
if find "${APP_DIR}" -flags +uchg | grep -q "locked.txt"; then
  echo "  ✓ Locked flag present"
else
  echo "  ✗ Failed to set locked flag" >&2
  exit 1
fi
set -e

echo "+ Running final permission fix commands"
(
  cd "${WORKDIR}/VSCode-darwin-x64"
  APP_BUNDLE="TestApp.app"
  chflags -R nouchg "${APP_BUNDLE}"
  chflags -R noschg "${APP_BUNDLE}"
  chflags -R nouappnd "${APP_BUNDLE}"
  chflags -R nosappnd "${APP_BUNDLE}"
  chflags -R nouchg,noschg "${APP_BUNDLE}"
  find "${APP_BUNDLE}" -type f ! -perm -u+w -exec chmod u+w {} \; 2>/dev/null || true
  find "${APP_BUNDLE}" -type d ! -perm -u+w -exec chmod u+w {} \; 2>/dev/null || true
  find "${APP_BUNDLE}" -type f -exec chmod 644 {} \; 2>/dev/null || true
  find "${APP_BUNDLE}" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "${APP_BUNDLE}/Contents/Resources/app" -type f -exec chmod 644 {} \; 2>/dev/null || true
)

set +e
if find "${APP_DIR}" -flags +uchg | grep -q "locked.txt"; then
  set -e
  echo "✗ Locked flag still present after fix" >&2
  exit 1
else
  set -e
  echo "  ✓ Locked flag removed"
fi

echo "+ Creating DMG after fix (should pass)"
hdiutil create -fs HFS+ -srcfolder "${APP_DIR}" "${DMG_UNLOCKED}" -quiet
"${ROOT_DIR}/check_dmg_permissions.sh" "${DMG_UNLOCKED}"

echo "✓ macOS permission fix test passed"

