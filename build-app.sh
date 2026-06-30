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

# Ad-hoc code signature so macOS will run the bundle locally without a
# developer cert. (Distribution/notarization is a later concern.)
echo "==> ad-hoc codesign"
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || \
    echo "    (codesign skipped — unsigned bundle will still run locally)"

echo "==> built ${PWD}/${APP}"

if [[ "${1:-}" == "--run" ]]; then
    echo "==> launching"
    open "${APP}"
fi
