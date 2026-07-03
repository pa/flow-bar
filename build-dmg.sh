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
# makehybrid builds the image directly from the folder tree (no attach cycle),
# which is more robust across environments than `hdiutil create -srcfolder`.
hdiutil makehybrid -hfs -hfs-volume-name "flow-bar" -o "${DMG}" "${STAGE}" >/dev/null
rm -rf "$(dirname "${STAGE}")"

echo "==> built ${PWD}/${DMG}"
