#!/bin/bash
# Builds Reel.app into ./build and signs it with a stable identity so macOS
# keeps the Screen Recording permission between rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Reel"
APP=build/Reel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Put REEL_SIGN_IDENTITY=<certificate hash or name> in scripts/sign.local (gitignored)
# or the environment. Without one the app is signed ad hoc, and macOS asks for
# Screen Recording permission again after each rebuild.
[ -f scripts/sign.local ] && source scripts/sign.local
IDENTITY="${REEL_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --entitlements Resources/Reel.entitlements "$APP" 2>/dev/null \
  || codesign --force --sign - --entitlements Resources/Reel.entitlements "$APP"
echo "Built $APP"
