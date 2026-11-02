#!/bin/sh
# Packs "build/Rook Search.app" into download/Rook-Search.dmg for the download page.
# Run ./build.sh first. The disk image holds the app and a shortcut to Applications.
set -e
cd "$(dirname "$0")"
APP="build/Rook Search.app"
DMG=../download/Rook-Search.dmg
[ -d "$APP" ] || { echo "Erst ./build.sh ausführen"; exit 1; }

STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Rook Search.app"
ln -s /Applications "$STAGE/Programme"
mkdir -p ../download
hdiutil create -quiet -volname "Rook Search" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG"
rm -rf "$STAGE"

# Daneben die Version, damit die Menüleisten-App Rook nur dann „Aktualisieren“ anbietet,
# wenn es wirklich etwas Neues gibt. Für ein Update CFBundleVersion in Info.plist erhöhen.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
printf '{ "version": "%s", "build": %s }\n' "$VERSION" "$BUILD" > ../download/Rook-Search.json

echo "Fertig: $(cd ../download && pwd)/Rook-Search.dmg ($(du -h "$DMG" | cut -f1)), Version $VERSION ($BUILD)"
