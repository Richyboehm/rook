import Foundation

/// Sortiert ~/Downloads nach Dateityp in Unterordner. Das System meldet jede Änderung
/// im Ordner; erst dann wird einmal sortiert (im Hintergrund, mit niedriger Priorität).
/// Unbekannte Dateitypen, Ordner und unfertige Downloads bleiben, wo sie sind.
@MainActor
final class DownloadsCleaner: ObservableObject {
    struct Action: Identifiable {
        let id = UUID()
        let date: Date
        let file: String
        let target: String // Ordnername oder „Papierkorb“
    }

    @Published private(set) var recent: [Action] = []
    @Published private(set) var lastError: String?
    var trashOldInstallers = true

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "RBTools.downloads", qos: .utility)

    nonisolated static let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    /// Installer, die älter sind, kommen in den Papierkorb.
    nonisolated static let installerMaxAge: TimeInterval = 14 * 24 * 60 * 60
    /// So frische Dateien werden womöglich noch geschrieben und kommen beim zweiten Durchgang dran.
    nonisolated static let settleTime: TimeInterval = 5

    nonisolated static let categories: [(folder: String, extensions: Set<String>)] = [
        ("Bilder", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "dng"]),
        ("Dokumente", ["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "odt", "epub"]),
        ("Tabellen", ["xls", "xlsx", "csv", "numbers", "ods"]),
        ("Präsentationen", ["ppt", "pptx", "key", "odp"]),
        ("Videos", ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
        ("Musik", ["mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg"]),
        ("Archive", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Installer", ["dmg", "pkg", "mpkg", "iso"]),
        ("Code", ["py", "js", "ts", "json", "html", "css", "swift", "sh", "xml", "yml", "yaml"]),
    ]
    /// Unfertige Downloads der Browser.
    nonisolated static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    var running: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        let descriptor = open(Self.downloads.path, O_EVTONLY)
        guard descriptor >= 0 else {
            lastError = "Kein Zugriff auf den Downloads-Ordner"
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        schedule(after: 0)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    /// Mehrere Änderungen kurz hintereinander werden zu einem Durchgang zusammengefasst.
    private func schedule(after delay: TimeInterval = 1.5) {
        pending?.cancel()
        let trash = trashOldInstallers
        let work = DispatchWorkItem { [weak self] in
            let first = Self.sortOnce(trashOldInstallers: trash)
            var actions = first.actions
            if first.skippedFresh {
                Thread.sleep(forTimeInterval: Self.settleTime + 1)
                actions += Self.sortOnce(trashOldInstallers: trash).actions
            }
            let error = first.error
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastError = error
                    if !actions.isEmpty { self.recent = Array((actions.reversed() + self.recent).prefix(30)) }
                }
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Sortieren (im Hintergrund)

    nonisolated private static func sortOnce(trashOldInstallers: Bool) -> (actions: [Action], skippedFresh: Bool, error: String?) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else {
            return ([], false, "Kein Zugriff auf den Downloads-Ordner")
        }

        var actions: [Action] = []
        var skippedFresh = false
        let now = Date()
        for file in entries {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            guard !partialExtensions.contains(ext),
                  let category = categories.first(where: { $0.extensions.contains(ext) }) else { continue }
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < settleTime {
                skippedFresh = true
                continue
            }
            if trashOldInstallers, category.folder == "Installer",
               let created = values.creationDate, now.timeIntervalSince(created) > installerMaxAge {
                if (try? fileManager.trashItem(at: file, resultingItemURL: nil)) != nil {
                    actions.append(Action(date: now, file: file.lastPathComponent, target: "Papierkorb"))
                }
                continue
            }
            let folder = downloads.appendingPathComponent(category.folder)
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? fileManager.moveItem(at: file, to: freeDestination(for: file, in: folder))) != nil {
                actions.append(Action(date: now, file: file.lastPathComponent, target: category.folder))
            }
        }

        // Installer, die schon einsortiert sind, altern dort weiter.
        if trashOldInstallers {
            let installers = downloads.appendingPathComponent("Installer")
            for file in (try? fileManager.contentsOfDirectory(at: installers, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles])) ?? [] {
                guard let created = (try? file.resourceValues(forKeys: keys))?.creationDate,
                      now.timeIntervalSince(created) > installerMaxAge,
                      (try? fileManager.trashItem(at: file, resultingItemURL: nil)) != nil else { continue }
                actions.append(Action(date: now, file: file.lastPathComponent, target: "Papierkorb"))
            }
        }
        for action in actions { Log.write("Downloads – \(action.target): \(action.file)") }
        return (actions, skippedFresh, nil)
    }

    /// Freier Zielname: „Foto.jpg“, sonst „Foto 2.jpg“, „Foto 3.jpg“ …
    nonisolated private static func freeDestination(for file: URL, in folder: URL) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var candidate = folder.appendingPathComponent(file.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }
}
