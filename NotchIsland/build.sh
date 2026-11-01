#!/bin/bash
# Baut NotchIsland.app in ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/NotchIsland.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.NotchIsland</string>
    <key>CFBundleName</key><string>Notch Island</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Notch Island liest den aktuellen Titel aus Spotify und steuert die Wiedergabe.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Notch Island zeigt deinen nächsten Termin an der Notch an.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Notch Island zeigt an, wenn sich Kopfhörer wie AirPods verbinden.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Fertig: $APP"

# ./build.sh install – ersetzt die installierte App in /Applications und startet sie neu
if [[ "${1:-}" == "install" ]]; then
    pkill -x NotchIsland || true
    sleep 1
    rm -rf /Applications/NotchIsland.app
    ditto "$APP" /Applications/NotchIsland.app
    open /Applications/NotchIsland.app
    echo "Installiert und gestartet: /Applications/NotchIsland.app"
fi
