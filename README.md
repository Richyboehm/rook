# Richy

Eigene Mac-App, gebaut mit Swift und SwiftUI für macOS 26+. Eine Kommandozentrale schaltet jede
Funktion einzeln ein und aus:

- **Widgets** auf dem Sperrbildschirm: Musik (Spotify), nächster Termin, Wetter, Akku & AirPods
- **StandBy**: große Uhr auf dem Sperrbildschirm, während der Mac lädt
- **Notch Island**: Musik, Screenshots, Ablage, Termine, Timer und mehr an der Notch
- **Fensterholer**: Cmd + Tab bringt immer ein Fenster nach vorne
- **Mausrad**: kehrt Scrollen und Zoomen nur für die Maus um, das Trackpad bleibt unverändert
- **Downloads-Aufräumer**: sortiert neue Downloads nach Dateityp

Ausgeschaltete Funktionen laufen gar nicht. Alles andere reagiert auf Meldungen von macOS,
statt regelmäßig nachzusehen.

```bash
cd Richy
./build.sh install   # bauen, nach /Applications installieren und starten
./build.sh zip       # ZIP zum Weitergeben
```

## Gut zu wissen

- Die App ist nur lokal signiert. Nach jedem Neubau fragt macOS die Erlaubnisse
  (Bedienungshilfen, Bildschirmaufnahme, Spotify, Kalender …) neu ab. Ein selbst erstelltes
  Signatur-Zertifikat hat macOS für die Erlaubnis-Listen nicht angenommen; dauerhaft lösen
  ließe sich das nur mit einer Developer ID von Apple.
- Widgets, StandBy und Teile der Notch nutzen inoffizielle macOS-Funktionen
  (SkyLight, login.framework). Nach großen macOS-Updates prüfen.
- Das Wetter kommt von [Open-Meteo](https://open-meteo.com); gesendet wird nur der eingetragene Ort.
- Protokoll für die Fehlersuche: in der Kommandozentrale unter Allgemein einschalten,
  es liegt dann unter `~/Library/Logs/Richy.log`.
- Die Vorgänger-Apps (LockGlass, NotchIsland, Fensterholer, Aufräumer) stecken in der Git-Historie.
