#!/bin/zsh
# Free distribution build. No Apple Developer Program fee.
# Other Macs can open this after the person approves it once in System Settings.
# A paid Developer ID signature is what removes that approval step.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

STAGE="dist/share"
APP="$STAGE/QuickGrade.app"
ZIP="dist/QuickGrade.zip"

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/QuickGrade" "$APP/Contents/MacOS/QuickGrade"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"
cp AppBundle/Resources/AppIcon.icns AppBundle/Resources/MenuMark.png "$APP/Contents/Resources/"

# Ad-hoc signature. A development certificate would be refused on other Macs.
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

cat > "$STAGE/Read Me.txt" << 'NOTE'
QuickGrade

1. Move QuickGrade to your Applications folder.
2. Open it. macOS will say it cannot verify the developer.
3. Open System Settings, go to Privacy & Security, and click Open Anyway.
   On older macOS you can also Control-click the app, choose Open, then Open.
4. Allow Accessibility when asked. QuickGrade needs that to see Space in Finder.
5. Select a photo in Finder and press Space.
NOTE

rm -f "$ZIP"
# Keep the zip free of AppleDouble files. Those land inside the app and make it look damaged.
COPYFILE_DISABLE=1 ditto -c -k --norsrc "$STAGE" "$ZIP"
echo "Ready to send: $ZIP"
echo "People approve it once under Privacy & Security, Open Anyway."
