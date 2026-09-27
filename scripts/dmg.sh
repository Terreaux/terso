#!/bin/sh
# Build an ad-hoc-signed disk image with a drag-to-Applications shortcut.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
sh scripts/bundle.sh "${1:-release}"
APP="$ROOT/build/Terso.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT/build/Terso-$VERSION-$(uname -m).dmg"
STAGING=$(mktemp -d "$ROOT/build/dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
ditto "$APP" "$STAGING/Terso.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Terso -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
