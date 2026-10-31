#!/bin/sh
# Builds Rook.app (Apple silicon + Intel) into browser/build/.
# Needs Apple's Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"

# Use the Command Line Tools if Xcode is installed but its license was not accepted yet.
if [ -d /Library/Developer/CommandLineTools ] && ! xcrun swiftc --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP=build/Rook.app
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

codesign --force --sign - "$APP"
echo "Fertig: $(pwd)/$APP"
