import AppKit

struct Track: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: Double // Sekunden
}

/// Spotify-Status ohne Dauerabfrage: Spotify verschickt bei jedem Wechsel (Titel, Play,
/// Pause, Spulen) selbst eine Meldung mit allen Angaben. AppleScript brauchen wir nur
/// für den Stand beim Start, die Cover-Adresse und die Steuertasten. Diese Aufrufe laufen
/// in einer eigenen Warteschlange, damit der Hauptthread nie wartet.
@MainActor
final class Spotify: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    /// Abspielposition in Sekunden zum Zeitpunkt `positionDate`.
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()

    /// Nur wenn das Widget gebraucht wird (Mac gesperrt), werden Cover geladen.
    var needsArtwork = false {
        didSet { if needsArtwork { ensureArtwork() } }
    }

    nonisolated private static let bundleID = "com.spotify.client"
    nonisolated private static let separator = "\u{1F}"
    nonisolated private static let queue = DispatchQueue(label: "LockGlass.spotify")
    /// Wird nur auf `queue` benutzt.
    nonisolated(unsafe) private static var stateScript: NSAppleScript?

    private var querying = false
    private var loadedArtworkURL: URL?
    /// Titel, für den die Cover-Adresse schon erfragt wurde (verhindert Wiederholungen,
    /// z. B. bei lokalen Dateien ohne Cover).
    private var artworkQueriedFor: String?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handle(info) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Spotify.bundleID else { return }
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Spotify.bundleID).isEmpty
    }

    // MARK: Meldungen von Spotify

    private func handle(_ info: [AnyHashable: Any]?) {
        guard let info, let state = info["Player State"] as? String else { return query() }
        if state == "Stopped" { return clear() }
        guard let id = info["Track ID"] as? String, let name = info["Name"] as? String else { return query() }

        let sameTrack = track?.id == id
        let newTrack = Track(
            id: id,
            name: name,
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            artworkURL: sameTrack ? track?.artworkURL : nil, // steht nicht in der Meldung
            duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        )
        Log.write("Spotify-Meldung: \(state) | \(name)")
        update(track: newTrack, playing: state == "Playing",
               position: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0)
        if !sameTrack { ensureArtwork() }
    }

    // MARK: AppleScript (nur bei Bedarf)

    /// Fragt Spotify einmal komplett ab. Startet Spotify nie selbst.
    func query() {
        guard isRunning else { return clear() }
        guard !querying else { return }
        querying = true
        Spotify.queue.async {
            let output = Spotify.runStateScript()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.querying = false
                    self.apply(output)
                }
            }
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    /// Den neuen Stand liefert danach Spotifys eigene Meldung.
    private func send(_ command: String) {
        guard isRunning else { return }
        let source = "tell application id \"\(Spotify.bundleID)\" to \(command)"
        Spotify.queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    nonisolated private static func runStateScript() -> String? {
        if stateScript == nil {
            stateScript = NSAppleScript(source: """
                tell application id "\(bundleID)"
                    set s to player state as string
                    if s is "stopped" then return "stopped"
                    set t to current track
                    set d to character id 31
                    return s & d & (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & (artwork url of t) & d & ((duration of t) as string) & d & ((player position) as string)
                end tell
                """)
        }
        var error: NSDictionary?
        guard let out = stateScript?.executeAndReturnError(&error).stringValue else {
            Log.write("Spotify-Abfrage fehlgeschlagen: \(error?["NSAppleScriptErrorBriefMessage"] ?? "unbekannt")")
            return nil
        }
        return out
    }

    private func apply(_ output: String?) {
        guard let output else { return }
        let parts = output.components(separatedBy: Spotify.separator)
        Log.write("Spotify-Abfrage: \(parts.prefix(3).joined(separator: " | "))")
        guard parts.count == 8 else { return clear() }

        let newTrack = Track(
            id: parts[1],
            name: parts[2],
            artist: parts[3],
            album: parts[4],
            artworkURL: URL(string: parts[5]),
            duration: (Double(parts[6]) ?? 0) / 1000
        )
        // AppleScript formatiert Kommazahlen je nach Sprache mit Komma.
        artworkQueriedFor = newTrack.id
        update(track: newTrack, playing: parts[0] == "playing",
               position: Double(parts[7].replacingOccurrences(of: ",", with: ".")) ?? 0)
        ensureArtwork()
    }

    // MARK: Zustand

    /// Setzt nur, was sich wirklich geändert hat, damit SwiftUI nichts unnötig neu zeichnet.
    private func update(track newTrack: Track, playing: Bool, position newPosition: Double) {
        if newTrack.id != track?.id, artwork != nil { artwork = nil }
        if newTrack != track { track = newTrack }
        if playing != isPlaying { isPlaying = playing }
        position = newPosition
        positionDate = Date()
    }

    /// Lädt das Cover des aktuellen Titels, aber nur wenn das Widget gebraucht wird
    /// und es noch nicht da ist.
    private func ensureArtwork() {
        guard needsArtwork, let track else { return }
        guard let url = track.artworkURL else {
            // Die Adresse steht nicht in Spotifys Meldung, also einmal nachfragen.
            if artworkQueriedFor != track.id {
                artworkQueriedFor = track.id
                query()
            }
            return
        }
        guard url != loadedArtworkURL else { return }
        loadedArtworkURL = url
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.track?.artworkURL == url else { return }
                    self.artwork = image
                }
            }
        }.resume()
    }

    private func clear() {
        if isPlaying { isPlaying = false }
        if track != nil { track = nil }
    }
}
