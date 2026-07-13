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
# Loose icns (Finder/Dock read this).
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# Asset-catalog icon: Notification Center resolves the app icon from a compiled
# Assets.car + CFBundleIconName, NOT the loose icns — without it the notification
# left-icon is blank. Compiling needs Xcode's actool; on Command Line Tools-only
# machines we skip it (dev builds then have a blank notification icon, which the
# release build — built in CI with Xcode — does not).
if xcrun --find actool >/dev/null 2>&1; then
    PARTIAL="$(mktemp)"
    if actool "Resources/AppIcon.xcassets" \
            --compile "${APP}/Contents/Resources" \
            --platform macosx \
            --minimum-deployment-target 13.0 \
            --app-icon AppIcon \
            --output-partial-info-plist "${PARTIAL}" >/dev/null 2>&1 \
        && [ -f "${APP}/Contents/Resources/Assets.car" ]; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "${APP}/Contents/Info.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "${APP}/Contents/Info.plist"
        echo "==> asset catalog compiled (Assets.car + CFBundleIconName)"
    else
        echo "==> actool present but compile failed — loose icns only (run 'sudo xcodebuild -runFirstLaunch'?)"
    fi
else
    echo "==> actool unavailable — loose icns only (notification left-icon blank on this build)"
fi

# Stamp the real version into the bundle so the in-app updater can compare it
# against the latest GitHub release. Prefer $APP_VERSION, then the CI tag
# ($GITHUB_REF_NAME), then the latest git tag; fall back to a dev marker.
VERSION="${APP_VERSION:-}"
[ -z "${VERSION}" ] && [ -n "${GITHUB_REF_NAME:-}" ] && VERSION="${GITHUB_REF_NAME#v}"
[ -z "${VERSION}" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -z "${VERSION}" ] && VERSION="0.0.0-dev"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
echo "==> version ${VERSION}"

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
