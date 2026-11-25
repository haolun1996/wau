#!/bin/sh
# Builds a Release copy of Wau and packages it as dist/Wau-<version>.dmg.
#
#   tools/package.sh
#
# Optional, for distributing to other Macs (needs a paid Apple Developer account):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"  re-signs the app
#   NOTARY_PROFILE=<keychain profile>  also notarizes and staples the DMG
#     (create the profile once with: xcrun notarytool store-credentials)
set -eu
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project Wau.xcodeproj -scheme Wau -configuration Release \
  -derivedDataPath build/release build | grep -E "error:|BUILD" || true

APP=build/release/Build/Products/Release/Wau.app
[ -d "$APP" ] || { echo "Release build failed" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "Signing with $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

STAGING=build/dmg
rm -rf "$STAGING" && mkdir -p "$STAGING" dist
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="dist/Wau-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Wau $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "Created $DMG"
