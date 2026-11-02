import Foundation
import Security

/// Austauschen von App-Bundles (Rook beim Update, Rook Search beim Ablegen in Programme) und die
/// Prüfung, ob eine App wirklich vom selben Apple-Team stammt wie Rook selbst.
enum AppFiles {
    /// Das Apple-Team, mit dem Rook selbst signiert ist; nil bei nur lokal signierten Bauten.
    static let ownTeam: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Stammt die App nachweislich vom selben Team wie Rook (gleiche Kennung, Zertifikat von Apple,
    /// alles darin unverändert)? Wer die Download-Seite fälscht oder die Datei unterwegs austauscht,
    /// besteht das nicht.
    static func isSignedLikeRook(_ app: URL, identifier: String) -> Bool {
        guard let team = ownTeam, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let requirement = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path])
    }

    /// Kennung und Versionen einer App, direkt aus ihrer Info.plist (Bundle(url:) merkt sich alte Werte).
    static func info(of app: URL) -> (id: String, version: String, build: Int)? {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let id = plist["CFBundleIdentifier"] as? String else { return nil }
        return (id, plist["CFBundleShortVersionString"] as? String ?? "–",
                Int(plist["CFBundleVersion"] as? String ?? "") ?? 0)
    }

    /// Legt `source` an die Stelle von `target`. Erst daneben kopieren, dann in einem Schritt
    /// austauschen: Eine laufende alte Version bleibt bis dahin heil. Ohne die Markierung „aus dem
    /// Internet“, denn geprüft ist die App schon (Signatur oder als Teil des freigegebenen Rook).
    /// Gibt nil bei Erfolg zurück, sonst eine kurze Fehlerbeschreibung.
    static func replace(_ target: URL, with source: URL) -> String? {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent) \(UUID().uuidString).app")
        guard run("/usr/bin/ditto", ["--noqtn", source.path, staging.path]) else {
            try? FileManager.default.removeItem(at: staging)
            return "Keine Schreibrechte für den Ordner \(target.deletingLastPathComponent().lastPathComponent)"
        }
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
            return nil
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return "Austauschen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Bool {
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
