import AppKit
import Security

/// Lädt den Browser Rook Search von der Download-Seite und legt ihn in den Ordner Programme.
/// Ist die geladene App mit demselben Apple-Zertifikat signiert wie Rook selbst, ist sie geprüft
/// echt und wird ohne Rückfrage von macOS installiert; mit demselben Zertifikat behält sie auch
/// ihre Erlaubnisse. Sonst bekommt sie die Markierung „aus dem Internet“ wie bei einem normalen
/// Download, damit macOS sie beim ersten Start prüft.
@MainActor
final class RookSearchInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    /// Version aus Info.plist (CFBundleShortVersionString und CFBundleVersion).
    struct Version: Equatable, Decodable {
        let version: String
        let build: Int

        static func > (lhs: Version, rhs: Version) -> Bool {
            lhs.build != rhs.build ? lhs.build > rhs.build
                : lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
    }

    nonisolated static let bundleID = "de.richyboehm.rook"
    static let download = URL(string: "https://richyboehm.github.io/rook/download/Rook-Search.dmg")!
    /// Liegt neben der DMG; `browser/make-dmg.sh` schreibt sie.
    static let latestInfo = URL(string: "https://richyboehm.github.io/rook/download/Rook-Search.json")!
    static let website = URL(string: "https://richyboehm.github.io/rook/download/")!
    private static let target = URL(fileURLWithPath: "/Applications/Rook Search.app")

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var installedURL: URL?
    @Published private(set) var installedVersion: Version?
    /// Neueste Version auf der Download-Seite; nil, solange unbekannt (z. B. offline).
    @Published private(set) var latestVersion: Version?

    private var task: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    init() { refresh() }

    func refresh() {
        installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
        installedVersion = installedURL.flatMap { Bundle(url: $0) }.flatMap { bundle in
            guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  let build = (bundle.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) else { return nil }
            return Version(version: version, build: build)
        }
    }

    /// Gibt es auf der Download-Seite eine neuere Version als die installierte?
    var updateAvailable: Bool {
        guard let installedVersion, let latestVersion else { return false }
        return latestVersion > installedVersion
    }

    /// Fragt die kleine Versionsdatei ab; nur, wenn die Kommandozentrale die Karte zeigt.
    func checkForUpdate() {
        var request = URLRequest(url: Self.latestInfo)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let latest = data.flatMap { try? JSONDecoder().decode(Version.self, from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let latest { self?.latestVersion = latest } }
            }
        }.resume()
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: true
        default: false
        }
    }

    func open() {
        guard let url = installedURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Lädt die neueste Version und installiert sie (auch zum Aktualisieren).
    func install() {
        guard !isBusy else { return }
        phase = .downloading(0)
        let task = URLSession.shared.downloadTask(with: Self.download) { [weak self] file, response, error in
            // Die Datei wird nach dem Rückruf gelöscht, deshalb sofort an einen eigenen Ort.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var saved: URL?
            if let file, error == nil, status == 200 {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Rook-Search-\(UUID().uuidString).dmg")
                if (try? FileManager.default.moveItem(at: file, to: copy)) != nil { saved = copy }
            }
            let message = error?.localizedDescription ?? (status == 200 ? "Download fehlgeschlagen" : "Download-Seite antwortet mit \(status)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = nil
                    if let saved { self.installDiskImage(saved) } else { self.phase = .failed(message) }
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
        self.task = task
        task.resume()
    }

    /// Einbinden, App kopieren, auswerfen; läuft im Hintergrund.
    private func installDiskImage(_ image: URL) {
        phase = .installing
        let target = Self.target
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.copyApp(from: image, to: target)
            try? FileManager.default.removeItem(at: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let problem = result {
                        self.phase = .failed(problem)
                    } else {
                        self.phase = .idle
                        self.refresh()
                        self.open()
                    }
                }
            }
        }
    }

    /// Gibt `nil` bei Erfolg zurück, sonst eine kurze Fehlerbeschreibung.
    nonisolated private static func copyApp(from image: URL, to target: URL) -> String? {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("Rook-Search-\(UUID().uuidString)")
        guard run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen",
                                        "-mountpoint", mount.path, "-quiet"]) else {
            return "Das Disk-Image ließ sich nicht öffnen"
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        let source = mount.appendingPathComponent("Rook Search.app")
        guard FileManager.default.fileExists(atPath: source.path) else { return "Im Disk-Image fehlt Rook Search.app" }
        // Erst daneben kopieren, dann austauschen: eine laufende alte Version bleibt bis dahin heil.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".Rook Search \(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [source.path, staging.path]) else {
            return "Keine Schreibrechte für den Ordner Programme"
        }
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return "Installieren fehlgeschlagen: \(error.localizedDescription)"
        }
        if isSignedLikeRook(target) { return nil }
        // Wie bei einem Download im Browser: macOS prüft die App beim ersten Start.
        let stamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        _ = run("/usr/bin/xattr", ["-w", "-r", "com.apple.quarantine", "0081;\(stamp);Rook;", target.path])
        return nil
    }

    /// Stammt die App nachweislich vom selben Team wie Rook (gleiche App-Kennung, Zertifikat von Apple)?
    /// Wer die Download-Seite fälscht oder die Datei unterwegs austauscht, besteht das nicht.
    nonisolated private static func isSignedLikeRook(_ app: URL) -> Bool {
        guard let team = ownTeam, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let requirement = "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path])
    }

    /// Das Apple-Team, mit dem Rook selbst signiert ist; nil bei nur lokal signierten Bauten.
    nonisolated private static var ownTeam: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
