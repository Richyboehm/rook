import Foundation

/// Schreibt Diagnosezeilen nach ~/Library/Logs/RBTools.log, aber nur, wenn das
/// Protokoll in der Kommandozentrale eingeschaltet ist (oder mit --debug gestartet).
/// Die Datei wird auf etwa 200 KB begrenzt.
enum Log {
    nonisolated(unsafe) static var enabled = CommandLine.arguments.contains("--debug")

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RBTools.log")

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date().formatted(date: .numeric, time: .standard))  \(message())\n"
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
