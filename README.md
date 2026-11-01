# Mac-Tools

Eigene kleine Mac-Apps, gebaut mit Swift und SwiftUI für macOS 26+.
Alle laufen sparsam: Sie reagieren nur auf Ereignisse des Systems, statt regelmäßig abzufragen.

## RB-Tools

`RBTools` fasst alles in einer App zusammen, mit einer Kommandozentrale zum Ein- und Ausschalten
jeder Funktion: Widgets auf dem Sperrbildschirm (Musik, Termin, Wetter, Akku & AirPods), StandBy,
Notch Island, Fensterholer und Downloads-Aufräumer.

```bash
cd RBTools
./build.sh install   # bauen, nach /Applications installieren und starten
./build.sh zip       # ZIP zum Weitergeben
```

Das Wetter kommt von [Open-Meteo](https://open-meteo.com); gesendet wird nur der eingetragene Ort.

## Einzelne Apps (Vorgänger, durch RB-Tools ersetzt)

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
