# RB-Tools

Eigene Mac-App, gebaut mit Swift und SwiftUI für macOS 26+. Eine Kommandozentrale schaltet jede
Funktion einzeln ein und aus:

- **Widgets** auf dem Sperrbildschirm: Musik (Spotify), nächster Termin, Wetter, Akku & AirPods
- **StandBy**: große Uhr auf dem Sperrbildschirm, während der Mac lädt
- **Notch Island**: Musik, Screenshots, Ablage, Termine, Timer und mehr an der Notch
- **Fensterholer**: Cmd + Tab bringt immer ein Fenster nach vorne
- **Downloads-Aufräumer**: sortiert neue Downloads nach Dateityp

Ausgeschaltete Funktionen laufen gar nicht. Alles andere reagiert auf Meldungen von macOS,
statt regelmäßig nachzusehen.

```bash
cd RBTools
./build.sh install   # bauen, nach /Applications installieren und starten
./build.sh zip       # ZIP zum Weitergeben
```

## Gut zu wissen

- Die App ist nur lokal signiert. Nach jedem Neubau fragt macOS die Erlaubnisse
  (Bedienungshilfen, Bildschirmaufnahme, Spotify, Kalender …) eventuell neu ab.
  Für den Fensterholer den alten Eintrag unter Bedienungshilfen entfernen und neu hinzufügen.
- Widgets, StandBy und Teile der Notch nutzen inoffizielle macOS-Funktionen
  (SkyLight, login.framework). Nach großen macOS-Updates prüfen.
- Das Wetter kommt von [Open-Meteo](https://open-meteo.com); gesendet wird nur der eingetragene Ort.
- Protokoll für die Fehlersuche: in der Kommandozentrale unter Allgemein einschalten,
  es liegt dann unter `~/Library/Logs/RBTools.log`.
- Die Vorgänger-Apps (LockGlass, NotchIsland, Fensterholer, Aufräumer) stecken in der Git-Historie.
