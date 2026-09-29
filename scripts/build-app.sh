#!/usr/bin/env bash
#
# Build UsageRings as a universal .app bundle in dist/UsageRings.app.
#
# Runs SwiftPM in release mode targeting both arm64 and x86_64, then
# assembles the app bundle by hand (Contents/MacOS/UsageRings and
# Contents/Info.plist), and ad-hoc signs it. LSUIElement is true in the
# plist so launching the app puts a menu bar item up with no Dock icon.
#
# Nothing here writes into /Applications or pushes anywhere.

set -euo pipefail

# Resolve the repo root regardless of where the caller invoked the script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

APP_NAME="UsageRings"
APP_BUNDLE="dist/${APP_NAME}.app"
INFO_PLIST_SOURCE="Resources/Info.plist"

if [[ ! -f "${INFO_PLIST_SOURCE}" ]]; then
    echo "error: ${INFO_PLIST_SOURCE} not found" >&2
    exit 1
fi

echo "building ${APP_NAME} (release, universal)…"
swift build -c release --arch arm64 --arch x86_64

# `swift build --arch arm64 --arch x86_64` places the universal binary under
# .build/apple/Products/Release/<name>. Fall back to the single-arch layout
# only if the universal path is missing AND the fallback binary is itself
# universal — a single-arch binary would defeat the point of the script.
BIN_CANDIDATES=(
    ".build/apple/Products/Release/${APP_NAME}"
    ".build/release/${APP_NAME}"
)

BIN=""
for candidate in "${BIN_CANDIDATES[@]}"; do
    if [[ -f "${candidate}" ]]; then
        BIN="${candidate}"
        break
    fi
done

if [[ -z "${BIN}" ]]; then
    echo "error: could not locate built binary — checked ${BIN_CANDIDATES[*]}" >&2
    exit 1
fi

# Enforce universal: require both arm64 and x86_64 slices. `lipo -archs`
# prints a whitespace-separated list; without this a partial build would
# silently ship a single-arch binary to Intel or Apple Silicon users.
ARCHS="$(lipo -archs "${BIN}" 2>/dev/null || true)"
if [[ "${ARCHS}" != *"arm64"* || "${ARCHS}" != *"x86_64"* ]]; then
    echo "error: ${BIN} is not universal (arm64 + x86_64). lipo -archs: '${ARCHS}'" >&2
    exit 1
fi

echo "assembling ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${INFO_PLIST_SOURCE}" "${APP_BUNDLE}/Contents/Info.plist"

echo "signing ${APP_BUNDLE} ad-hoc…"
codesign --force --deep -s - "${APP_BUNDLE}"

# Print the absolute path so downstream steps can pipe it into `open`.
BUNDLE_ABS_PATH="$(cd "$(dirname "${APP_BUNDLE}")" && pwd)/$(basename "${APP_BUNDLE}")"
echo "built ${BUNDLE_ABS_PATH}"
