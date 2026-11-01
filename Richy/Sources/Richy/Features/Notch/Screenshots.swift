import AppKit

/// Screenshots über das macOS-eigene Werkzeug `screencapture`: gleiche Auswahl wie bei
/// Shift + Ctrl + Cmd + 4 (Esc bricht ab). Das Bild landet in der Zwischenablage und als
/// Datei in einem eigenen Cache-Ordner, damit es in der Ablage liegen kann. Dateien dort
/// werden nach 24 Stunden gelöscht.
@MainActor
enum Screenshots {
    enum Mode { case area, window, screen }

    static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Richy/Screenshots", isDirectory: true)
    }()

    static func capture(_ mode: Mode, completion: @escaping @MainActor (URL) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
        let file = folder.appendingPathComponent("Bildschirmfoto \(stamp).png")

        let arguments: [String] = switch mode {
        case .area: ["-i", "-s", file.path]       // nur Bereich
        case .window: ["-i", "-w", file.path]     // nur Fenster
        case .screen: ["-m", file.path]           // eingebauter Bildschirm
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Abgebrochen (Esc): Es gibt keine Datei, also passiert nichts.
                    guard FileManager.default.fileExists(atPath: file.path),
                          let image = NSImage(contentsOf: file) else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    completion(file)
                }
            }
        }
        try? process.run()
    }

    /// Alte Screenshots aus dem Cache entfernen (beim Start).
    static func cleanUp() {
        let keys: Set<URLResourceKey> = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for file in files {
            if let created = try? file.resourceValues(forKeys: keys).creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
