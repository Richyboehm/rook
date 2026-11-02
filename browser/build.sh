#!/bin/sh
# Builds "Rook Search.app" (Apple silicon + Intel) into browser/build/.
# Needs Apple's Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"

# Use the Command Line Tools if Xcode is installed but its license was not accepted yet.
if [ -d /Library/Developer/CommandLineTools ] && ! xcrun swiftc --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP="build/Rook Search.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/start"

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos13.0" Sources/*.swift -o "build/Rook-$ARCH"
done
lipo -create build/Rook-arm64 build/Rook-x86_64 -output "$APP/Contents/MacOS/Rook"
rm build/Rook-arm64 build/Rook-x86_64

cp Info.plist "$APP/Contents/"
cp Rook.icns "$APP/Contents/Resources/"
# The start page is the same one that runs on the website.
cp -R ../index.html ../style.css ../app.js ../assets ../backgrounds "$APP/Contents/Resources/start/"

# Im Bau von Rook bekommt der Browser dieselbe Version wie Rook.
if [ -n "${ROOK_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$ROOK_VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$ROOK_BUILD" "$APP/Contents/Info.plist"
fi

# Mit einem Zertifikat von Apple („Apple Development“ oder „Developer ID“) erkennt macOS die App
# an Team und Name: Erlaubnisse (Downloads-Ordner, Kamera, Mikrofon) bleiben über Updates erhalten,
# und Rook kann vor einem Update prüfen, dass die neue Version wirklich von hier stammt.
# Ohne Zertifikat wird nur lokal signiert; dann gelten Erlaubnisse nur für genau diesen Bau.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"(Developer ID Application|Apple Development):/ { print $2; exit }')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signiert mit: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Nur lokal signiert (kein Apple-Zertifikat gefunden)"
fi
echo "Fertig: $(pwd)/$APP"
