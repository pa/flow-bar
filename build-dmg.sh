#!/bin/bash
# Package flow-bar.app into a drag-to-Applications disk image.
# Run after build-app.sh (needs flow-bar.app present). Produces flow-bar.dmg.
set -euo pipefail

cd "$(dirname "$0")"
APP="flow-bar.app"
DMG="flow-bar.dmg"

[ -d "${APP}" ] || { echo "error: ${APP} not found — run ./build-app.sh first"; exit 1; }

STAGE="$(mktemp -d)/flow-bar"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
# Symlink so the mounted window shows an Applications shortcut to drag into.
ln -s /Applications "${STAGE}/Applications"

rm -f "${DMG}"
# Standard compressed UDIF disk image (what Finder mounts on double-click).
# NOTE: `makehybrid` produces an optical-disc hybrid that Finder won't mount as
# a normal .dmg, so we must use `create -format UDZO` here.
hdiutil create -volname "flow-bar" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "$(dirname "${STAGE}")"

echo "==> built ${PWD}/${DMG}"
