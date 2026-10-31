#!/bin/sh
# Packs build/Rook.app into download/Rook.dmg for the download page.
# Run ./build.sh first. The disk image holds the app and a shortcut to Applications.
set -e
cd "$(dirname "$0")"
[ -d build/Rook.app ] || { echo "Erst ./build.sh ausführen"; exit 1; }

STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto build/Rook.app "$STAGE/Rook.app"
ln -s /Applications "$STAGE/Programme"
mkdir -p ../download
hdiutil create -quiet -volname "Rook" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 ../download/Rook.dmg
rm -rf "$STAGE"
echo "Fertig: $(cd ../download && pwd)/Rook.dmg ($(du -h ../download/Rook.dmg | cut -f1))"
