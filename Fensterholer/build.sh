#!/bin/bash
# Baut Fensterholer.app in ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Fensterholer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Fensterholer "$APP/Contents/MacOS/Fensterholer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.Fensterholer</string>
    <key>CFBundleName</key><string>Fensterholer</string>
    <key>CFBundleExecutable</key><string>Fensterholer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Fertig: $APP"

# ./build.sh install – ersetzt die installierte App in /Applications und startet sie neu
if [[ "${1:-}" == "install" ]]; then
    pkill -x Fensterholer || true
    sleep 1
    rm -rf /Applications/Fensterholer.app
    ditto "$APP" /Applications/Fensterholer.app
    open /Applications/Fensterholer.app
    echo "Installiert und gestartet: /Applications/Fensterholer.app"
fi
