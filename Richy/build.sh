#!/bin/bash
# Baut "Richy.app" in ./build
#
#   ./build.sh           nur bauen
#   ./build.sh install   nach /Applications installieren und starten
#   ./build.sh zip       zusätzlich ein ZIP zum Weitergeben erzeugen
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Richy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Richy "$APP/Contents/MacOS/Richy"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>de.richyboehm.richy</string>
    <key>CFBundleName</key><string>Richy</string>
    <key>CFBundleDisplayName</key><string>Richy</string>
    <key>CFBundleExecutable</key><string>Richy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key><string>Richy zeigt den Song, der gerade in Spotify läuft, und steuert die Wiedergabe.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Richy zeigt deinen nächsten Termin in der Notch und im StandBy-Modus.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Richy zeigt an, wenn sich Kopfhörer wie AirPods verbinden.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Richy stellt die Lautstärke einzelner Apps ein, wenn du die Lautstärke pro App einschaltest. Der Ton wird nicht aufgenommen oder gespeichert.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Richy sortiert deinen Downloads-Ordner automatisch, wenn du den Aufräumer einschaltest.</string>
</dict>
</plist>
PLIST

# Mit einem Zertifikat von Apple („Apple Development“, kostenlos mit einer Apple-ID in Xcode,
# oder „Developer ID“) erkennt macOS Richy an Team und Name. Erteilte Erlaubnisse bleiben dann
# auch nach einem Neubau erhalten. Ohne Zertifikat wird nur lokal signiert; dann gelten die
# Erlaubnisse nur für genau diesen Bau. Ein selbst erstelltes Zertifikat nimmt macOS dafür nicht an.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"(Developer ID Application|Apple Development):/ { print $2; exit }')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signiert mit: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Nur lokal signiert (kein Apple-Zertifikat gefunden)"
fi
echo "Fertig: $APP"

case "${1:-}" in
install)
    pkill -x Richy || true
    sleep 1
    rm -rf "/Applications/Richy.app"
    ditto "$APP" "/Applications/Richy.app"
    open "/Applications/Richy.app"
    echo "Installiert und gestartet: /Applications/Richy.app"
    ;;
zip)
    ditto -c -k --keepParent "$APP" "build/Richy.zip"
    echo "Zum Weitergeben: build/Richy.zip"
    ;;
esac
