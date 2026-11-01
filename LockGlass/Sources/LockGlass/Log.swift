import Foundation

/// Schreibt Diagnosezeilen nach ~/Library/Logs/LockGlass.log, aber nur im Debug-Modus
/// (Start mit --debug oder `defaults write local.LockGlass debug -bool true`).
enum Log {
    private static let enabled = CommandLine.arguments.contains("--debug")
        || UserDefaults.standard.bool(forKey: "debug")

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LockGlass.log")

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let message = message()
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
