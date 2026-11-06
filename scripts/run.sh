#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/QuickGrade"
APP="QuickGrade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/QuickGrade"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp AppBundle/Resources/AppIcon.icns AppBundle/Resources/MenuMark.png "$APP/Contents/Resources/"
codesign --force --timestamp=none --sign "Apple Development: David Pukha (Z4N5S27YWV)" "$APP"
# Install a copy the user can open from Spotlight and the Applications folder.
# Login items only stick for an app that lives there.
if touch /Applications/.quickgrade-write-test 2>/dev/null; then
  rm -f /Applications/.quickgrade-write-test
  DEST="/Applications/QuickGrade.app"
else
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/QuickGrade.app"
fi
killall QuickGrade 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
