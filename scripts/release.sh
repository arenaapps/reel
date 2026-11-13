#!/bin/bash
# Builds a downloadable Reel.app for both Apple silicon and Intel Macs and zips it into build/.
#
# For a build that opens without a warning on other Macs, set these (in scripts/sign.local or the
# environment) before running:
#   REEL_RELEASE_IDENTITY  a "Developer ID Application: ..." certificate in your keychain
#   REEL_NOTARY_PROFILE    a notarytool keychain profile, made once with
#                          xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Without them the app is signed ad hoc: it works, but macOS asks people to confirm the first time.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/sign.local ] && source scripts/sign.local

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/Reel.app
ZIP="build/Reel-$VERSION.zip"

REEL_UNIVERSAL=1 REEL_SIGN_IDENTITY=- ./scripts/bundle.sh release

if [ -n "${REEL_RELEASE_IDENTITY:-}" ]; then
  echo "Signing with $REEL_RELEASE_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$REEL_RELEASE_IDENTITY" \
    --entitlements Resources/Reel.entitlements "$APP"
else
  echo "No REEL_RELEASE_IDENTITY: signed ad hoc. People will need to confirm the first launch."
fi
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${REEL_RELEASE_IDENTITY:-}" ] && [ -n "${REEL_NOTARY_PROFILE:-}" ]; then
  echo "Notarising (this can take a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$REEL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

lipo -archs "$APP/Contents/MacOS/Reel"
shasum -a 256 "$ZIP"
echo "Built $ZIP"
