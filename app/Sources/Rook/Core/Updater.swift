import AppKit

/// Rook aktualisiert sich selbst, samt Rook Search, das in Rook steckt. Einmal am Tag (und beim
/// Öffnen der Kommandozentrale) wird eine kleine Versionsdatei auf der Download-Seite gelesen.
/// Eingespielt wird ein Update nur, wenn es nachweislich mit demselben Apple-Zertifikat signiert
/// ist wie dieses Rook: dann ohne Rückfrage von macOS, und alle Erlaubnisse bleiben.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    struct Version: Equatable, Decodable {
        let version: String
        let build: Int
    }

    static let latestInfo = URL(string: "https://richyboehm.github.io/rook/download/Rook.json")!
    static let download = URL(string: "https://richyboehm.github.io/rook/download/Rook.zip")!
    static let website = URL(string: "https://richyboehm.github.io/rook/download/")!
    static let current = Version(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–",
        build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)

    /// Neueste Version auf der Download-Seite; nil, solange unbekannt (z. B. offline).
    @Published private(set) var latest: Version?
    @Published private(set) var phase: Phase = .idle
    private var timer: Timer?
    private var progress: NSKeyValueObservation?

    var updateAvailable: Bool { (latest?.build ?? 0) > Self.current.build }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: true
        default: false
        }
    }

    /// Kurz nach dem Start einmal nachsehen, dann einmal am Tag. Kein Abfragen dazwischen.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check() {
        var request = URLRequest(url: Self.latestInfo)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let latest = data.flatMap { try? JSONDecoder().decode(Version.self, from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let latest, self?.latest != latest { self?.latest = latest } }
            }
        }.resume()
    }

    /// Lädt die neue Version, prüft sie, tauscht Rook aus und startet neu.
    func install() {
        guard !isBusy else { return }
        guard AppFiles.ownTeam != nil else {
            // Ein selbst gebautes Rook ohne Apple-Zertifikat kann ein Update nicht prüfen.
            phase = .failed("Dieses Rook kann sich nicht selbst prüfen. Bitte von der Download-Seite laden.")
            return
        }
        phase = .downloading(0)
        let task = URLSession.shared.downloadTask(with: Self.download) { [weak self] file, response, error in
            // Die Datei wird nach dem Rückruf gelöscht, deshalb sofort an einen eigenen Ort.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var saved: URL?
            if let file, error == nil, status == 200 {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Rook-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: file, to: copy)) != nil { saved = copy }
            }
            let message = error?.localizedDescription ?? (status == 200 ? "Download fehlgeschlagen" : "Download-Seite antwortet mit \(status)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = nil
                    if let saved { self.installArchive(saved) } else { self.phase = .failed(message) }
                }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }
        }
        task.resume()
    }

    private func installArchive(_ archive: URL) {
        phase = .installing
        let target = Bundle.main.bundleURL
        let current = Self.current.build
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = Self.unpackAndReplace(archive, target: target, newerThan: current)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let problem { self.phase = .failed(problem) } else { Self.relaunch() }
                }
            }
        }
    }

    nonisolated private static func unpackAndReplace(_ archive: URL, target: URL, newerThan current: Int) -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Rook-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: folder)
        }
        guard AppFiles.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) else { return "Das Update ließ sich nicht entpacken" }
        let app = folder.appendingPathComponent("Rook.app")
        guard let info = AppFiles.info(of: app), info.id == Bundle.main.bundleIdentifier else { return "Im Update fehlt Rook" }
        guard info.build > current else { return "Das Update ist nicht neuer als dieses Rook" }
        guard AppFiles.isSignedLikeRook(app, identifier: info.id) else {
            return "Das Update ist nicht mit dem Zertifikat von Rook signiert und wurde nicht installiert"
        }
        return AppFiles.replace(target, with: app)
    }

    /// Beendet Rook und startet die neue Version, sobald die alte wirklich weg ist.
    private static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
