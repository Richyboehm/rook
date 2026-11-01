#!/bin/bash
# Baut "RB-Tools.app" in ./build
#
#   ./build.sh           nur bauen
#   ./build.sh install   nach /Applications installieren und starten
#   ./build.sh zip       zusätzlich ein ZIP zum Weitergeben erzeugen
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/RB-Tools.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RBTools "$APP/Contents/MacOS/RBTools"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>de.richyboehm.rbtools</string>
    <key>CFBundleName</key><string>RB-Tools</string>
    <key>CFBundleDisplayName</key><string>RB-Tools</string>
    <key>CFBundleExecutable</key><string>RBTools</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key><string>RB-Tools zeigt den Song, der gerade in Spotify läuft, und steuert die Wiedergabe.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>RB-Tools zeigt deinen nächsten Termin in der Notch und im StandBy-Modus.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>RB-Tools zeigt an, wenn sich Kopfhörer wie AirPods verbinden.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>RB-Tools sortiert deinen Downloads-Ordner automatisch, wenn du den Aufräumer einschaltest.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Fertig: $APP"

case "${1:-}" in
install)
    pkill -x RBTools || true
    sleep 1
    rm -rf "/Applications/RB-Tools.app"
    ditto "$APP" "/Applications/RB-Tools.app"
    open "/Applications/RB-Tools.app"
    echo "Installiert und gestartet: /Applications/RB-Tools.app"
    ;;
zip)
    ditto -c -k --keepParent "$APP" "build/RB-Tools.zip"
    echo "Zum Weitergeben: build/RB-Tools.zip"
    ;;
esac
