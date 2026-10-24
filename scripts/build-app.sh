#!/usr/bin/env bash
# Builds dist/OpenThock.app (universal, release, ad-hoc signed unless CODESIGN_IDENTITY is set).
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal binary: build each architecture, then merge (works without full Xcode).
ARCHS=${ARCHS:-"arm64 x86_64"}
BINS=()
for a in $ARCHS; do
  swift build -c release --triple "$a-apple-macosx14.0"
  BINS+=("$(swift build -c release --triple "$a-apple-macosx14.0" --show-bin-path)/OpenThock")
done
BIN=.build/OpenThock-universal
lipo -create "${BINS[@]}" -output "$BIN"

# App icon from Resources/icon-1024.png (regenerate it with scripts/make-icon.swift).
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o .build/AppIcon.icns

APP=dist/OpenThock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenThock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Packs "$APP/Contents/Resources/Packs"
cp SOUNDS-LICENSE.md LICENSE "$APP/Contents/Resources/"
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/OpenThock"))"
