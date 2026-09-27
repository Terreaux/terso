#!/bin/sh
# Build Terso.app from the Swift package.
#   scripts/bundle.sh [debug|release]   → build/Terso.app
set -eu
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c "$CONFIG" --product Terso
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Terso.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Terso" "$APP/Contents/MacOS/Terso"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
for b in "$BIN"/Terso_*.bundle; do
  [ -e "$b" ] || continue
  case "$b" in *Tests.bundle) continue ;; esac
  cp -R "$b" "$APP/Contents/Resources/"
done
[ -f "$ROOT/Support/AppIcon.icns" ] && cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed"
echo "$APP"
