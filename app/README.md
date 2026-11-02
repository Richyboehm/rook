# Rook

Eigene Mac-App, gebaut mit Swift und SwiftUI für macOS 26+. Eine Kommandozentrale schaltet jede
Funktion einzeln ein und aus:

- **Widgets** auf dem Sperrbildschirm: Musik (Spotify), nächster Termin, Wetter, Akku & AirPods
- **StandBy**: große Uhr auf dem Sperrbildschirm, während der Mac lädt
- **Notch Island**: Musik, Screenshots, Ablage, Termine, Timer und mehr an der Notch
- **Fensterholer**: Cmd + Tab bringt immer ein Fenster nach vorne
- **Mausrad**: kehrt Scrollen und Zoomen nur für die Maus um, das Trackpad bleibt unverändert
- **Lautstärke**: eigene Lautstärke für jede App, wie unter Windows
- **Downloads-Aufräumer**: sortiert neue Downloads nach Dateityp

Ein Klick auf den Raben in der Menüleiste öffnet ein kleines Fenster mit allen Funktionen
(per Ziehen umsortierbar) und einer Leistungsanzeige mit CPU und Arbeitsspeicher von Rook.
Von dort und aus der Kommandozentrale lässt sich auch der Browser
[Rook Search](../README.md) laden und installieren.

Rook hieß früher Richy. Die interne Kennung `de.richyboehm.richy` ist geblieben, damit
Einstellungen und Erlaubnisse beim Umbenennen erhalten bleiben.

Ausgeschaltete Funktionen laufen gar nicht. Alles andere reagiert auf Meldungen von macOS,
statt regelmäßig nachzusehen. Gemessen mit laufender Musik: etwa 0,2 % CPU und 25 MB.

```bash
cd app
./build.sh install   # bauen, nach /Applications installieren und starten
./build.sh zip       # ZIP zum Weitergeben
```

## Gut zu wissen

- `build.sh` signiert mit einem Zertifikat von Apple, wenn eins im Schlüsselbund liegt
  („Apple Development“, kostenlos über eine Apple-ID in Xcode → Settings → Accounts →
  Manage Certificates). Dann bleiben die Erlaubnisse (Bedienungshilfen, Spotify, Kalender …)
  auch nach einem Neubau oder Update erhalten. Ohne Zertifikat wird nur lokal signiert, und
  macOS fragt nach jedem Neubau neu. Ein selbst erstelltes Zertifikat nimmt macOS dafür nicht an.
- Zum Signieren braucht macOS außerdem Apples Zwischenzertifikat „WWDR G3“
  (apple.com/certificateauthority), falls Xcode es nicht selbst abgelegt hat.
- Widgets, StandBy und Teile der Notch nutzen inoffizielle macOS-Funktionen
  (SkyLight, login.framework). Nach großen macOS-Updates prüfen.
- Das Wetter kommt von [Open-Meteo](https://open-meteo.com); gesendet wird nur der eingetragene Ort.
- Protokoll für die Fehlersuche: in der Kommandozentrale unter Allgemein einschalten,
  es liegt dann unter `~/Library/Logs/Rook.log`.
- Die Vorgänger-Apps (LockGlass, NotchIsland, Fensterholer, Aufräumer) stecken in der Git-Historie.
