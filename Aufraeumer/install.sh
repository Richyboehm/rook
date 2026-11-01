#!/bin/bash
# Baut den Downloads-Aufräumer, legt ihn nach /Applications und richtet den
# automatischen Start ein: Das System startet ihn nur, wenn sich in ~/Downloads
# etwas ändert (plus alle 30 Minuten als Sicherheitsnetz), danach beendet er sich.
#
#   ./install.sh            installieren / aktualisieren
#   ./install.sh uninstall  automatischen Start entfernen und App löschen
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/Downloads-Aufräumer.app"
LABEL="local.Aufraeumer"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "uninstall" ]]; then
    rm -f "$AGENT"
    rm -rf "$APP"
    echo "Entfernt."
    exit 0
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Aufraeumer "$APP/Contents/MacOS/Aufraeumer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.Aufraeumer</string>
    <key>CFBundleName</key><string>Downloads-Aufräumer</string>
    <key>CFBundleExecutable</key><string>Aufraeumer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/Aufraeumer</string></array>
    <key>WatchPaths</key>
    <array><string>$HOME/Downloads</string></array>
    <key>StartInterval</key><integer>1800</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>10</integer>
    <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installiert: $APP (startet automatisch bei Änderungen in ~/Downloads)"
