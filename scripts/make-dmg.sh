#!/usr/bin/env bash
#
# Build UsageRings.app (via scripts/build-app.sh) and package it into an
# unsigned .dmg with the drag-to-Applications layout.
#
# Output: dist/UsageRings-<version>.dmg, where <version> is
# `CFBundleShortVersionString` from Resources/Info.plist.
#
# Nothing here pushes, publishes, notarises, or installs into /Applications.
# The dmg is unsigned; a downstream user is expected to open it via System
# Settings → Privacy & Security → Open Anyway, or run
# `xattr -dr com.apple.quarantine /Applications/UsageRings.app` after they
# drag the app across (see README). The old "right-click → Open" shortcut
# still works on macOS 14 but was disabled for unnotarised apps in macOS 15+.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

APP_NAME="UsageRings"
APP_BUNDLE="dist/${APP_NAME}.app"
INFO_PLIST_SOURCE="Resources/Info.plist"
DMG_STAGE="dist/dmg"

if [[ ! -f "${INFO_PLIST_SOURCE}" ]]; then
    echo "error: ${INFO_PLIST_SOURCE} not found" >&2
    exit 1
fi

# Read CFBundleShortVersionString from Info.plist. `PlistBuddy` gets the
# value directly by keypath, no dependency on `defaults`' preferences
# domain naming or path-suffix quirks.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST_SOURCE}")"
if [[ -z "${VERSION}" ]]; then
    echo "error: could not read CFBundleShortVersionString from ${INFO_PLIST_SOURCE}" >&2
    exit 1
fi

DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"

echo "building ${APP_NAME}.app (via scripts/build-app.sh)…"
"${SCRIPT_DIR}/build-app.sh"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} not produced by build-app.sh" >&2
    exit 1
fi

echo "staging ${DMG_STAGE}/…"
# Fresh staging directory every run — leftover files from a previous build
# would otherwise get packed into the dmg.
rm -rf "${DMG_STAGE}"
mkdir -p "${DMG_STAGE}"
# Copy the app itself.
cp -R "${APP_BUNDLE}" "${DMG_STAGE}/${APP_NAME}.app"
# Symlink /Applications so users can drag-drop. `ln -s /Applications` (as
# opposed to `ln -s /Applications/.`) is what Finder recognises as the
# drag-target icon.
ln -s /Applications "${DMG_STAGE}/Applications"

echo "creating ${DMG_PATH}…"
# Remove any prior dmg with the same version so `hdiutil create -ov` is
# not asked to overwrite something we could not otherwise recreate.
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

# Print the absolute path so downstream steps or logs are unambiguous.
DMG_ABS_PATH="$(cd "$(dirname "${DMG_PATH}")" && pwd)/$(basename "${DMG_PATH}")"
echo "built ${DMG_ABS_PATH}"
