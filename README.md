# Mac-Tools

Eigene kleine Mac-Apps, gebaut mit Swift und SwiftUI für macOS 26+.
Alle laufen sparsam: Sie reagieren nur auf Ereignisse des Systems, statt regelmäßig abzufragen.

| Ordner | Was es macht | Bauen & installieren |
|---|---|---|
| `LockGlass` | Musik-Widget (Spotify) im Glas-Look auf dem Sperrbildschirm, dazu StandBy-Modus am Strom: große Uhr, Song, nächster Termin, Ladestand, nachts rot | `./build.sh install` |
| `NotchIsland` | „Dynamic Island“ an der Notch: Musik, Snipping-Tool, Datei-Ablage, nächster Termin, Timer, AirPods, Entsperren | `./build.sh install` |
| `Fensterholer` | Nach Cmd + Tab erscheint immer ein Fenster der gewählten App (minimierte zurückholen, sonst neues öffnen) | `./build.sh install` |
| `Aufraeumer` | Sortiert `~/Downloads` automatisch nach Dateityp, alte Installer in den Papierkorb | `./install.sh` (Entfernen: `./install.sh uninstall`) |

## Gut zu wissen

- Die Apps sind nur lokal signiert. Nach jedem Neubau fragt macOS die Erlaubnisse
  (Bedienungshilfen, Bildschirmaufnahme, Spotify, Kalender …) eventuell neu ab.
  Beim Fensterholer den alten Eintrag unter Bedienungshilfen entfernen und neu hinzufügen.
- LockGlass, StandBy und Teile von NotchIsland nutzen inoffizielle macOS-Funktionen
  (SkyLight, DisplayServices, login.framework). Nach großen macOS-Updates prüfen.
- Debug-Protokoll: LockGlass und NotchIsland mit `--debug` starten, Logs unter `~/Library/Logs/`.
