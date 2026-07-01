#!/bin/bash
# Assemble flow-bar.app from a SwiftPM release build.
# Usage: ./build-app.sh [--run]
set -euo pipefail

cd "$(dirname "$0")"

APP="flow-bar.app"
CONFIG="release"
BIN=".build/${CONFIG}/flow-bar"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/flow-bar"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# Code signature. Defaults to ad-hoc ("-") for local dev builds. Release CI
# sets CODESIGN_IDENTITY to a STABLE self-signed cert so the app's Designated
# Requirement stays constant across versions — that's what lets macOS keep
# Accessibility/Automation grants after an upgrade (ad-hoc's identity changes
# every build, so TCC treats each update as a new app and drops the grant).
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "==> codesign (identity: ${SIGN_ID})"
codesign --force --deep --sign "${SIGN_ID}" "${APP}" >/dev/null 2>&1 || \
    echo "    (codesign skipped — unsigned bundle will still run locally)"

echo "==> built ${PWD}/${APP}"

if [[ "${1:-}" == "--run" ]]; then
    echo "==> launching"
    open "${APP}"
fi
