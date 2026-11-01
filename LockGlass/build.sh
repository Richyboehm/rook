#!/bin/bash
# Baut LockGlass.app in ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/LockGlass.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LockGlass "$APP/Contents/MacOS/LockGlass"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.LockGlass</string>
    <key>CFBundleName</key><string>LockGlass</string>
    <key>CFBundleExecutable</key><string>LockGlass</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>LockGlass liest den aktuellen Titel aus Spotify und steuert die Wiedergabe.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>LockGlass zeigt deinen nächsten Termin im StandBy-Modus an.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Fertig: $APP"

# ./build.sh install – ersetzt die installierte App in /Applications und startet sie neu
if [[ "${1:-}" == "install" ]]; then
    pkill -x LockGlass || true
    sleep 1
    rm -rf /Applications/LockGlass.app
    ditto "$APP" /Applications/LockGlass.app
    open /Applications/LockGlass.app
    echo "Installiert und gestartet: /Applications/LockGlass.app"
fi
