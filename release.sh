#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")
export COURSE_PLAYER_ARCHS=${COURSE_PLAYER_ARCHS:-"arm64 x86_64"}

"$SCRIPT_DIR/build-app.sh"

RELEASE_DIR="$SCRIPT_DIR/.build/release"
APP="$SCRIPT_DIR/.build/Course Player.app"
DMG="$RELEASE_DIR/Course-Player-$VERSION.dmg"
ZIP="$RELEASE_DIR/Course-Player-$VERSION.zip"
mkdir -p "$RELEASE_DIR"
rm -f "$DMG" "$ZIP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
hdiutil create -volname "Course Player" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler staple "$DMG"
fi

echo "$DMG"
echo "$ZIP"

