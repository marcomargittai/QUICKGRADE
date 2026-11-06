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
# Sign as Marco Margittai when his certificate is in the keychain. SIGN_IDENTITY overrides.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Marco Margittai" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
else
  # An ad-hoc signature changes with every build, so macOS forgets the Accessibility approval.
  echo "No Marco Margittai signing certificate found. Signing ad-hoc."
  echo "After this build, remove QuickGrade under Privacy & Security, Accessibility, and add it again."
  codesign --force --sign - "$APP"
fi
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
