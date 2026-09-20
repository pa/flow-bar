#!/bin/bash
# Assemble flow-bar.app from a SwiftPM release build.
#
# This is the SINGLE build entry point — CI, the Homebrew cask, and local dev
# all go through here. Keep it that way: the cask invokes it via
# `installer script:`, so any build logic that lives elsewhere is logic the
# cask can't reach.
#
# Usage:
#   ./build-app.sh [--run]
#   ./build-app.sh --version 0.3.0 --channel homebrew-source --sign-local
#
# Options:
#   --version X.Y.Z   Version to stamp. Takes precedence over $APP_VERSION.
#                     REQUIRED for cask installs: Homebrew's
#                     Cask::Artifact::Installer hardcodes the child env, so
#                     there is no way to pass APP_VERSION in.
#   --channel C       Install provenance baked into Info.plist as
#                     FBInstallChannel: homebrew-source | github-release | dev.
#                     The updater reads it to decide whether it may self-install.
#   --sign-local      Sign with a per-machine self-signed identity, creating it
#                     first if absent. This is what keeps the TCC Automation
#                     grant alive across `brew upgrade` (see below).
#   --no-sign         Force ad-hoc signing.
#   --swift-flags "…" Extra flags passed through to `swift build`.
#   --run             Launch the app when done.
set -euo pipefail

cd "$(dirname "$0")"

APP="flow-bar.app"
CONFIG="release"
BIN=".build/${CONFIG}/flow-bar"
LOCAL_IDENTITY="flow-bar Code Signing"

VERSION_ARG=""
CHANNEL=""
SIGN_MODE=""          # local | none | "" (=> $CODESIGN_IDENTITY, else ad-hoc)
SWIFT_FLAGS=""
DO_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     VERSION_ARG="$2"; shift 2 ;;
        --channel)     CHANNEL="$2";     shift 2 ;;
        --swift-flags) SWIFT_FLAGS="$2"; shift 2 ;;
        --sign-local)  SIGN_MODE="local"; shift ;;
        --no-sign)     SIGN_MODE="none";  shift ;;
        --run)         DO_RUN=1; shift ;;
        --no-open)     DO_RUN=0; shift ;;
        *) echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done

# --- Toolchain preflight -----------------------------------------------------
# Users installing from the cask compile on their own machine, so a missing or
# misconfigured toolchain is a normal failure mode, not an exotic one. Say
# exactly what to run.
if ! command -v swift >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: no Swift toolchain found.

flow-bar compiles on your machine so it links against your macOS SDK. Install
the Command Line Tools (about 1 GB — full Xcode is not required):

    xcode-select --install
EOF
    exit 1
fi
if ! swift build --help >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: `swift` is on PATH but not runnable.

This usually means xcode-select points at a moved or deleted Xcode. Fix with:

    sudo xcode-select --reset
EOF
    exit 1
fi

# Which macOS SDK this build links against.
#
# This is load-bearing, not cosmetic: SwiftUI picks its appearance from the SDK
# a binary was linked against, so it's what decides whether the app looks native
# (see "Distribution" in CLAUDE.md). It's stamped into Info.plist as FBBuildSDK
# so the app can tell the user when a rebuild is due.
#
# `xcrun --show-sdk-version` on its own is NOT reliable. On a machine with Xcode
# selected it can still resolve to the Command Line Tools SDK path and fail
# outright ("unable to lookup item 'SDKVersion'"), which used to fall through to
# "unknown" — silently disabling the very rebuild nudge this value exists for.
# So: ask for the macosx SDK explicitly, then fall back to the bare form, then
# to the OS version, which on a CLT-only machine is the closest honest answer.
detect_sdk_version() {
    local v
    v="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return; }
    v="$(xcrun --show-sdk-version 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return; }
    v="$(sw_vers -productVersion 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return; }
    printf 'unknown'
}

# What the linked binary actually records, which beats any guess: the same
# LC_BUILD_VERSION field `.github/workflows/verify-install.yml` asserts on.
sdk_from_binary() {
    [ -f "$1" ] || return 1
    otool -l "$1" 2>/dev/null \
        | awk '/LC_BUILD_VERSION/ {f=1; next} f && $1=="sdk" {print $2; exit}'
}

SDK_VERSION="$(detect_sdk_version)"
echo "==> toolchain: $(swift --version 2>/dev/null | head -1)"
echo "==> macOS SDK: ${SDK_VERSION}"

# --- Build -------------------------------------------------------------------
echo "==> swift build -c ${CONFIG} ${SWIFT_FLAGS}"
# shellcheck disable=SC2086
swift build -c "${CONFIG}" ${SWIFT_FLAGS}

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/flow-bar"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
# Loose icns (Finder/Dock read this).
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# The changelog, whole.
#
# The same text GitHub publishes as release bodies, so the app can show what
# changed with no network call and no second copy to drift. The WHOLE file, not
# just the newest section: the history is the part you go looking for ("when did
# the hotkey change?"), and the find bar can search all of it. 17 KB.
if [ -f "CHANGELOG.md" ]; then
    cp CHANGELOG.md "${APP}/Contents/Resources/release-notes.md"
fi

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
            --minimum-deployment-target 15.0 \
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

# --- Version + provenance ----------------------------------------------------
# Precedence: --version → $APP_VERSION → CI tag → git tag → dev marker.
# A source tarball has no git metadata, which is why --version exists.
VERSION="${VERSION_ARG}"
[ -z "${VERSION}" ] && VERSION="${APP_VERSION:-}"
[ -z "${VERSION}" ] && [ -n "${GITHUB_REF_NAME:-}" ] && VERSION="${GITHUB_REF_NAME#v}"
[ -z "${VERSION}" ] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -z "${VERSION}" ] && VERSION="0.0.0-dev"

[ -z "${CHANNEL}" ] && CHANNEL="dev"

PLIST="${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
# CFBundleVersion was frozen at 1 for a long time. LaunchServices uses it to
# arbitrate between copies of the same bundle ID, so a frozen build number can
# make it prefer a stale copy. Keep it in step with the marketing version.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${PLIST}"

# Provenance, read back by Updater.swift. Baked into the plist rather than a
# sidecar file so it survives the bundle being copied or moved — a path check
# can't distinguish a cask install in /Applications from a manual DMG install.
plist_set_string() {
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "${PLIST}" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "${PLIST}"
}
plist_set_string FBInstallChannel "${CHANNEL}"
# Prefer what the binary itself records over what the toolchain claimed: it's
# the ground truth for appearance, and it's available now that linking is done.
if BIN_SDK="$(sdk_from_binary "${APP}/Contents/MacOS/flow-bar")" && [ -n "${BIN_SDK}" ]; then
    if [ "${BIN_SDK}" != "${SDK_VERSION}" ]; then
        echo "==> SDK from linked binary: ${BIN_SDK} (toolchain said ${SDK_VERSION})"
    fi
    SDK_VERSION="${BIN_SDK}"
fi
plist_set_string FBBuildSDK "${SDK_VERSION}"

echo "==> version ${VERSION}  channel ${CHANNEL}  sdk ${SDK_VERSION}"

# --- Code signature ----------------------------------------------------------
# Why this matters: FlowClient.spawnDisclaimed deliberately does NOT disclaim
# responsibility for the AppleScript terminal backends, so flow-bar itself owns
# the TCC Automation grant. TCC keys that grant to the Designated Requirement.
# An ad-hoc signature's DR is the code hash, which changes every single build —
# so ad-hoc means the grant is dropped on every upgrade and `flow do` silently
# starts failing with -1743.
#
# A self-signed identity gives a stable, hash-pinned DR
# (`identifier "cloud.facets.flow-bar" and certificate leaf = H"…"`) that holds
# across rebuilds. The cert does NOT need to be added as a trusted root —
# trust is required to *validate* a signature, not to produce one.
if [ "${SIGN_MODE}" = "local" ]; then
    if ! security find-identity -p codesigning 2>/dev/null | grep -q "${LOCAL_IDENTITY}"; then
        echo "==> creating local signing identity"
        ./scripts/create-signing-cert.sh || true
    fi
    if security find-identity -p codesigning 2>/dev/null | grep -q "${LOCAL_IDENTITY}"; then
        SIGN_ID="${LOCAL_IDENTITY}"
        security unlock-keychain -p "flow-bar-signing" "flow-bar-signing.keychain" 2>/dev/null || true
    else
        echo "    (could not create a local identity — falling back to ad-hoc;"
        echo "     you may need to re-grant Automation after each upgrade)"
        SIGN_ID="-"
    fi
elif [ "${SIGN_MODE}" = "none" ]; then
    SIGN_ID="-"
else
    SIGN_ID="${CODESIGN_IDENTITY:--}"
fi

echo "==> codesign (identity: ${SIGN_ID})"
codesign --force --deep --sign "${SIGN_ID}" "${APP}" >/dev/null 2>&1 || \
    echo "    (codesign skipped — unsigned bundle will still run locally)"

echo "==> built ${PWD}/${APP}"

if [ "${DO_RUN}" = "1" ]; then
    echo "==> launching"
    open "${APP}"
fi
