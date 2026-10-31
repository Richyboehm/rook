import AppKit
import WebKit

/// Browsing history, stored only on this Mac (Application Support/Rook/history.json).
final class History {
    struct Entry: Codable {
        let url: URL
        var title: String
        var date: Date
    }

    static let shared = History()

    private(set) var entries: [Entry] = []
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rook", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }()
    private var saveScheduled = false

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let first = entries.first, first.url == url {
            entries[0].title = title.isEmpty ? first.title : title
            entries[0].date = Date()
        } else {
            entries.insert(Entry(url: url, title: title, date: Date()), at: 0)
            if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
        }
        scheduleSave()
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let i = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[i].title = title
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// The most recent pages, each address only once.
    func recent(_ count: Int) -> [Entry] {
        var seen = Set<URL>(), result: [Entry] = []
        for e in entries where !seen.contains(e.url) {
            seen.insert(e.url)
            result.append(e)
            if result.count == count { break }
        }
        return result
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}

/// Open tabs are remembered when Rook quits and restored on the next start.
enum Session {
    private static let key = "session"

    /// One array of addresses per window (in tab order). Private windows are never saved.
    static func save() {
        var groups: [[String]] = []
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? BrowserWindowController, !controller.isPrivate else { continue }
            let tabs = window.tabbedWindows ?? [window]
            let id = ObjectIdentifier(tabs.first!)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let urls = tabs.compactMap { ($0.windowController as? BrowserWindowController)?.currentURLForSession }
            if !urls.isEmpty { groups.append(urls) }
        }
        UserDefaults.standard.set(groups, forKey: key)
    }

    static func load() -> [[URL]] {
        let groups = UserDefaults.standard.array(forKey: key) as? [[String]] ?? []
        return groups.map { $0.compactMap(URL.init(string:)) }.filter { !$0.isEmpty }
    }
}
