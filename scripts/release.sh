#!/bin/zsh
# Build a QuickGrade.app that other people can download.
#
# This needs two things that do not live in the repo:
#   1. A "Developer ID Application" certificate in the login keychain.
#      Apple Development certificates are refused by other Macs.
#   2. Notary credentials, so Gatekeeper will open the app without a warning.
#      One-time setup (App Store Connect API key is the stable option):
#        xcrun notarytool store-credentials "quickgrade-notary" \
#          --key /path/to/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER
#      Or pass NOTARY_PROFILE if the keychain profile has another name.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-quickgrade-notary}"
APP="dist/QuickGrade.app"
ENTITLEMENTS="AppBundle/QuickGrade.entitlements"

identity_line=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [[ -z "$identity_line" ]]; then
  echo "No Developer ID Application certificate in this keychain."
  echo "The only usable signature on this Mac is an Apple Development certificate."
  echo "Other Macs will not open an app signed with that."
  echo
  echo "What to do once:"
  echo "  1. Enroll the Apple Developer Program (\$99/year) on an account you control."
  echo "  2. In Xcode: Settings, Accounts, Manage Certificates, add Developer ID Application."
  echo "  3. Create an App Store Connect API key and store it:"
  echo "       xcrun notarytool store-credentials \"quickgrade-notary\" --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER"
  echo "  4. Run scripts/release.sh again."
  exit 1
fi
IDENTITY=$(echo "$identity_line" | sed -E 's/.*"(.*)"/\1/')

echo "Building release with: $IDENTITY"
swift build -c release

VERSION=$(plutil -extract CFBundleShortVersionString raw -o - AppBundle/Info.plist)
ZIP="dist/QuickGrade-${VERSION}.zip"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp ".build/release/QuickGrade" "$APP/Contents/MacOS/QuickGrade"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"
cp AppBundle/Resources/AppIcon.icns AppBundle/Resources/MenuMark.png "$APP/Contents/Resources/"

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo
  echo "Signed, but not notarized: $ZIP"
  echo "Gatekeeper will still block this zip on other Macs."
  echo "Store notary credentials, then run this script again:"
  echo "  xcrun notarytool store-credentials \"$PROFILE\" --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER"
  exit 1
fi

echo "Submitting to Apple notary..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Ready to upload: $ZIP"
