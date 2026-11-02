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
    /// Farben des Covers; bleibt beim Songwechsel stehen, bis die neuen da sind,
    /// damit die Farbe weich überblenden kann.
    @Published private(set) var palette = ArtworkPalette.neutral
    @Published private(set) var isPlaying = false
    /// Abspielposition in Sekunden zum Zeitpunkt `positionDate`.
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()

    /// Nur wenn eine Funktion Cover zeigen soll (Notch, Sperrbildschirm), werden sie geladen.
    var needsArtwork = false {
        didSet { if needsArtwork { ensureArtwork() } }
    }

    nonisolated static let bundleID = "com.spotify.client"
    nonisolated private static let separator = "\u{1F}"
    nonisolated private static let queue = DispatchQueue(label: "Rook.spotify")
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

    // MARK: Apple Events (nur bei Bedarf)

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

    func playPause() { send { SpotifyEvents.command("PlPs") } }
    func next() { send { SpotifyEvents.command("Next") } }
    func previous() { send { SpotifyEvents.command("Prev") } }

    /// Springt im Song an diese Stelle. Spotify meldet das nicht zurück, deshalb gleich selbst setzen.
    func seek(to seconds: Double) {
        let seconds = min(max(seconds, 0), track?.duration ?? seconds)
        send { SpotifyEvents.set("pPos", to: NSAppleEventDescriptor(double: seconds)) }
        position = seconds
        positionDate = Date()
    }

    /// Den neuen Stand liefert danach Spotifys eigene Meldung.
    private func send(_ event: @escaping @Sendable () -> Void) {
        guard isRunning else { return }
        Spotify.queue.async(execute: event)
    }

    /// Fragt Stand und Titel ab und gibt sie im selben Format wie früher das AppleScript zurück.
    nonisolated private static func runStateScript() -> String? {
        do {
            let state = try SpotifyEvents.get(SpotifyEvents.property("pPlS"))
            let stateName = switch state.enumCodeValue {
            case SpotifyEvents.code("kPSP"): "playing"
            case SpotifyEvents.code("kPSp"): "paused"
            default: "stopped"
            }
            if stateName == "stopped" { return "stopped" }
            let track = SpotifyEvents.property("pTrk")
            func text(_ code: String) throws -> String {
                try SpotifyEvents.get(SpotifyEvents.property(code, of: track)).stringValue ?? ""
            }
            let duration = try SpotifyEvents.get(SpotifyEvents.property("pDur", of: track)).int32Value
            let position = try SpotifyEvents.get(SpotifyEvents.property("pPos")).doubleValue
            return [stateName, try text("ID  "), try text("pnam"), try text("pArt"), try text("pAlb"), try text("aUrl"),
                    String(duration), String(position)].joined(separator: separator)
        } catch {
            Log.write("Spotify-Abfrage fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
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
            let palette = ArtworkPalette.from(image) // noch im Hintergrund
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.track?.artworkURL == url else { return }
                    self.artwork = image
                    if let palette, palette != self.palette { self.palette = palette }
                }
            }
        }.resume()
    }

    private func clear() {
        if isPlaying { isPlaying = false }
        if track != nil { track = nil }
    }
}

/// Spotify-Befehle als einzelne Apple Events statt als AppleScript. Gleiche Erlaubnis
/// („Spotify steuern“), aber AppleScript muss nicht geladen werden; das spart rund 16 MB.
/// Die Codes stehen in Spotifys Skript-Beschreibung (Spotify.sdef).
enum SpotifyEvents {
    static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// Ein Befehl aus Spotifys eigener Sammlung, z. B. „PlPs“ für Play/Pause.
    static func command(_ id: String) {
        _ = try? send(event("spfy", id))
    }

    /// Eigenschaft der App (ohne `container`) oder eines Objekts, z. B. des aktuellen Titels.
    static func property(_ id: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(id)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }

    static func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = event("core", "getd")
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        return try send(event).paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }

    static func set(_ id: String, to value: NSAppleEventDescriptor) {
        let event = event("core", "setd")
        event.setParam(property(id), forKeyword: AEKeyword(keyDirectObject))
        event.setParam(value, forKeyword: AEKeyword(keyAEData))
        _ = try? send(event)
    }

    private static func event(_ eventClass: String, _ id: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(id),
                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: Spotify.bundleID),
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Wartet auf die Antwort; Fehler von Spotify (z. B. kein Titel) werden zu `throw`.
    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 5)
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number))
        }
        return reply
    }
}
