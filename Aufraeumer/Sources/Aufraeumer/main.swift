import Foundation

// Downloads-Aufräumer: sortiert ~/Downloads einmal durch und beendet sich sofort wieder.
// Gestartet wird er vom System (launchd), sobald sich im Ordner etwas ändert.
//
//   --dry-run   nur anzeigen, was passieren würde

let dryRun = CommandLine.arguments.contains("--dry-run")
let fileManager = FileManager.default
let home = fileManager.homeDirectoryForCurrentUser
let downloads = home.appendingPathComponent("Downloads")
let logURL = home.appendingPathComponent("Library/Logs/Aufraeumer.log")

/// Installer, die älter sind, kommen in den Papierkorb.
let installerMaxAge: TimeInterval = 14 * 24 * 60 * 60
/// So frische Dateien werden womöglich noch geschrieben und bleiben beim nächsten Mal dran.
let settleTime: TimeInterval = 5

let categories: [(folder: String, extensions: Set<String>)] = [
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
let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

func log(_ message: String) {
    if dryRun { print(message); return }
    let line = "\(Date().formatted(date: .numeric, time: .standard))  \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// Freier Zielname: „Foto.jpg“, sonst „Foto 2.jpg“, „Foto 3.jpg“ …
func freeDestination(for file: URL, in folder: URL) -> URL {
    let base = file.deletingPathExtension().lastPathComponent
    let ext = file.pathExtension
    var candidate = folder.appendingPathComponent(file.lastPathComponent)
    var number = 2
    while fileManager.fileExists(atPath: candidate.path) {
        candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
        number += 1
    }
    return candidate
}

let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]

/// Ein Durchgang durch ~/Downloads. Gibt zurück, ob frische Dateien übersprungen wurden.
func sortDownloads() -> Bool {
guard let entries = try? fileManager.contentsOfDirectory(
    at: downloads, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
) else {
    log("Downloads-Ordner nicht lesbar (fehlt die Erlaubnis?)")
    exit(1)
}

var skippedFresh = false
let now = Date()
for file in entries {
    guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
    let ext = file.pathExtension.lowercased()
    guard !partialExtensions.contains(ext) else { continue }
    guard let category = categories.first(where: { $0.extensions.contains(ext) }) else { continue }
    if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < settleTime {
        skippedFresh = true
        continue
    }

    if category.folder == "Installer",
       let created = values.creationDate, now.timeIntervalSince(created) > installerMaxAge {
        log("Papierkorb: \(file.lastPathComponent) (Installer älter als 14 Tage)")
        if !dryRun { try? fileManager.trashItem(at: file, resultingItemURL: nil) }
        continue
    }

    let folder = downloads.appendingPathComponent(category.folder)
    let destination = freeDestination(for: file, in: folder)
    log("\(category.folder): \(file.lastPathComponent)")
    if !dryRun {
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try fileManager.moveItem(at: file, to: destination) } catch { log("Fehler bei \(file.lastPathComponent): \(error.localizedDescription)") }
    }
}

return skippedFresh
}

// Kam gerade eine Datei an, kurz warten und sie dann auch noch einsortieren.
if sortDownloads() && !dryRun {
    Thread.sleep(forTimeInterval: settleTime + 1)
    _ = sortDownloads()
}

// Installer, die schon einsortiert sind, altern dort weiter.
let now = Date()
let installerFolder = downloads.appendingPathComponent("Installer")
for file in (try? fileManager.contentsOfDirectory(at: installerFolder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [] {
    guard let created = (try? file.resourceValues(forKeys: keys))?.creationDate,
          now.timeIntervalSince(created) > installerMaxAge else { continue }
    log("Papierkorb: Installer/\(file.lastPathComponent) (älter als 14 Tage)")
    if !dryRun { try? fileManager.trashItem(at: file, resultingItemURL: nil) }
}
