#!/usr/bin/env bash
# Packages dist/OpenThock.app into dist/OpenThock.dmg (drag-to-Applications) and a .zip.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d dist/OpenThock.app ] || ./scripts/build-app.sh

STAGE=.build/dmg
rm -rf "$STAGE" dist/OpenThock.dmg dist/OpenThock.zip
mkdir -p "$STAGE"
cp -R dist/OpenThock.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OpenThock" -srcfolder "$STAGE" -ov -format UDZO dist/OpenThock.dmg >/dev/null
(cd dist && ditto -c -k --keepParent OpenThock.app OpenThock.zip)
shasum -a 256 dist/OpenThock.dmg dist/OpenThock.zip
