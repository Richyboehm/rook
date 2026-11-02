import AppKit
import SQLite3

/// A named set of tabs, like Safari's tab groups. A window shows either its own loose tabs or one group;
/// switching saves the window's tabs into the group and opens the other one.
struct TabGroup: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: String
        var title: String
        var pinned: Bool
    }

    var id: String
    var name: String
    var tabs: [Tab]
}

enum TabGroups {
    private static let key = "tabGroups"

    static var all: [TabGroup] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([TabGroup].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: .rookTabGroupsChanged, object: nil)
        }
    }

    static func group(_ id: String?) -> TabGroup? { all.first { $0.id == id } }

    @discardableResult
    static func add(name: String, tabs: [TabGroup.Tab]) -> TabGroup {
        let group = TabGroup(id: UUID().uuidString, name: name, tabs: tabs)
        all.append(group)
        return group
    }

    static func update(_ id: String, tabs: [TabGroup.Tab]) {
        var groups = all
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].tabs != tabs else { return }
        groups[index].tabs = tabs
        all = groups
    }

    static func rename(_ id: String, to name: String) {
        var groups = all
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
        all = groups
    }

    static func delete(_ id: String) { all.removeAll { $0.id == id } }

    /// Saves the tabs of every window that shows a group (called with the session, every 20 s and on quit).
    static func saveOpenGroups() {
        for controller in BrowserWindowController.all where !controller.isPrivate {
            if let id = controller.groupID { update(id, tabs: controller.snapshot()) }
        }
    }

    /// Addresses (http/https) from the clipboard, e.g. after "Copy Links" on a tab group in Safari.
    static func linksFromClipboard() -> [TabGroup.Tab] {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return TabGroup.Tab(url: url.absoluteString, title: url.host ?? url.absoluteString, pinned: false)
        }
    }
}

/// Reads Safari's tab groups from its database (SafariTabs.db). The file is protected by macOS:
/// Rook Search can only read it with "Full Disk Access", which the user grants once for the import.
enum SafariTabGroups {
    struct Group {
        var name: String
        var tabs: [TabGroup.Tab]
    }

    enum Result {
        case groups([Group])
        case needsAccess
        case notFound
    }

    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db")

    /// Safari is set up with tab groups on this Mac (only checks that the file exists, needs no permission).
    static var exist: Bool { FileManager.default.fileExists(atPath: database.path) }

    static func read() -> Result {
        guard exist else { return .notFound }
        // Read a copy (with its write-ahead log), so Safari's own file is never locked or changed.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("rook-safari-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: database.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(at: source, to: temp.appendingPathComponent("SafariTabs.db" + suffix))
            }
        } catch {
            return .needsAccess
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appendingPathComponent("SafariTabs.db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .needsAccess
        }
        defer { sqlite3_close(db) }

        // Named tab groups are folders (type 1, subtype 0) at the top level or inside a profile (subtype 3).
        // The unnamed group of the current window has no title and stays out.
        let groupsSQL = """
            SELECT id, title FROM bookmarks
            WHERE type = 1 AND subtype = 0 AND hidden = 0 AND deleted = 0 AND special_id = 0
              AND title IS NOT NULL AND title <> ''
              AND (parent = 0 OR parent IN (SELECT id FROM bookmarks WHERE type = 1 AND subtype = 3))
            ORDER BY parent <> 0, order_index
            """
        let tabsSQL = """
            SELECT title, url FROM bookmarks
            WHERE parent = ? AND type = 0 AND deleted = 0 AND url IS NOT NULL AND url <> ''
            ORDER BY order_index
            """
        var groups: [Group] = []
        for row in rows(db, groupsSQL) {
            guard let id = Int64(row[0] ?? ""), let name = row[1] else { continue }
            let tabs = rows(db, tabsSQL, bind: id).compactMap { tab -> TabGroup.Tab? in
                guard let url = tab[1], let parsed = URL(string: url),
                      ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
                return TabGroup.Tab(url: url, title: tab[0] ?? parsed.host ?? url, pinned: false)
            }
            if !tabs.isEmpty { groups.append(Group(name: name, tabs: tabs)) }
        }
        return .groups(groups)
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String, bind: Int64? = nil) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_int64(statement, 1, bind) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return result
    }
}

/// The dialogs around tab groups: asking for a name, importing from Safari, pasting links.
enum TabGroupDialogs {
    /// Asks for a name; nil when cancelled.
    static func askName(title: String, button: String, initial: String = "", in window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Abbrechen")
        let field = NSTextField(string: initial)
        field.placeholderString = "Name der Gruppe"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Waits for the return from System Settings, then continues the import by itself.
    private static var returnObserver: NSObjectProtocol?
    /// After a restart that was needed for the permission, the import continues automatically.
    private static let resumeKey = "resumeSafariImport"

    /// Called at launch: continues an import that needed a restart.
    static func resumeAfterRestart() {
        guard UserDefaults.standard.bool(forKey: resumeKey) else { return }
        UserDefaults.standard.removeObject(forKey: resumeKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { importFromSafari(afterSettings: true) }
    }

    /// Imports Safari's tab groups. Without access, explains the one-time permission, opens System
    /// Settings and continues by itself as soon as Rook Search is in front again.
    /// `afterSettings`: this is the attempt after granting; if it still fails, offer a restart.
    static func importFromSafari(afterSettings: Bool = false) {
        switch SafariTabGroups.read() {
        case .notFound:
            info("Keine Tab-Gruppen gefunden", "In Safari auf diesem Mac gibt es keine Tab-Gruppen.")
        case .needsAccess where afterSettings:
            // Some versions of macOS only apply the new permission after a restart of the app.
            let alert = NSAlert()
            alert.messageText = "Noch kein Zugriff"
            alert.informativeText = "Wenn du Rook Search unter „Festplattenvollzugriff“ eingeschaltet hast, braucht macOS oft noch einen Neustart der App. Rook Search startet neu und übernimmt die Tab-Gruppen danach von selbst."
            alert.addButton(withTitle: "Neu starten und übernehmen")
            alert.addButton(withTitle: "Systemeinstellungen öffnen")
            alert.addButton(withTitle: "Abbrechen")
            switch alert.runModal() {
            case .alertFirstButtonReturn: relaunchAndResume()
            case .alertSecondButtonReturn: openSettingsAndWait()
            default: break
            }
        case .needsAccess:
            let alert = NSAlert()
            alert.messageText = "Einmal Zugriff auf Safaris Tab-Gruppen erlauben"
            alert.informativeText = """
            macOS schützt die Daten von Safari. Damit Rook Search die Tab-Gruppen lesen kann, braucht es einmal den Festplattenvollzugriff:

            1. Klick auf „Systemeinstellungen öffnen“.
            2. Klick unten in der Liste auf „+“, wähle Rook Search aus dem Ordner „Programme“ und schalte es ein.
            3. Wechsle zurück zu Rook Search. Die Tab-Gruppen werden dann von selbst übernommen.

            Rook Search liest nur die Tab-Gruppen und ändert nichts an Safari. Nach dem Übernehmen kannst du den Zugriff wieder ausschalten.
            """
            alert.addButton(withTitle: "Systemeinstellungen öffnen")
            alert.addButton(withTitle: "Abbrechen")
            if alert.runModal() == .alertFirstButtonReturn { openSettingsAndWait() }
        case .groups(let groups):
            guard !groups.isEmpty else {
                return info("Keine Tab-Gruppen gefunden", "Safari hat keine Tab-Gruppen mit geöffneten Seiten.")
            }
            // Groups that were imported before (same name) are left alone, so importing twice adds nothing.
            let existing = Set(TabGroups.all.map(\.name))
            let new = groups.filter { !existing.contains($0.name) }
            for group in new { TabGroups.add(name: group.name, tabs: group.tabs) }
            let tabCount = new.reduce(0) { $0 + $1.tabs.count }
            if new.isEmpty {
                info("Schon übernommen", "Alle Tab-Gruppen aus Safari sind bereits in Rook Search.")
            } else {
                info(new.count == 1 ? "1 Tab-Gruppe übernommen" : "\(new.count) Tab-Gruppen übernommen",
                     "Mit \(tabCount) Tabs. Oben links neben den Pfeilen wechselst du zwischen deinen Gruppen. Den Festplattenvollzugriff kannst du jetzt wieder ausschalten.")
            }
        }
    }

    /// Opens the Full Disk Access list and continues once Rook Search becomes active again.
    private static func openSettingsAndWait() {
        if let returnObserver { NotificationCenter.default.removeObserver(returnObserver) }
        returnObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            if let returnObserver { NotificationCenter.default.removeObserver(returnObserver) }
            returnObserver = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { importFromSafari(afterSettings: true) }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Starts Rook Search again and continues the import after the restart (open tabs are saved first).
    private static func relaunchAndResume() {
        UserDefaults.standard.set(true, forKey: resumeKey)
        Session.save()
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this instance has quit, then open the app again.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
