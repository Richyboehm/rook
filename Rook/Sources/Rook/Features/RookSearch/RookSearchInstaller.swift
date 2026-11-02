import AppKit

/// Lädt den Browser Rook Search von der Download-Seite und legt ihn in den Ordner Programme.
/// Die App bekommt dabei dieselbe Markierung „aus dem Internet“ wie bei einem normalen
/// Download, damit macOS sie beim ersten Start genauso prüft.
@MainActor
final class RookSearchInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let bundleID = "de.richyboehm.rook"
    static let download = URL(string: "https://richyboehm.github.io/rook/download/Rook-Search.dmg")!
    static let website = URL(string: "https://richyboehm.github.io/rook/download/")!
    private static let target = URL(fileURLWithPath: "/Applications/Rook Search.app")

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var installedURL: URL?

    private var task: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    init() { refresh() }

    func refresh() {
        installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
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
        // Wie bei einem Download im Browser: macOS prüft die App beim ersten Start.
        let stamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        _ = run("/usr/bin/xattr", ["-w", "-r", "com.apple.quarantine", "0081;\(stamp);Rook;", target.path])
        return nil
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
