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

    /// Removes single entries (all visits of these addresses).
    func remove(urls: Set<URL>) {
        entries.removeAll { urls.contains($0.url) }
        save()
    }

    /// Removes everything visited since `date` (e.g. "the last hour", "today").
    func remove(since date: Date) {
        entries.removeAll { $0.date >= date }
        save()
    }

    func search(_ text: String) -> [Entry] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q) }
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

    /// Per window: its tabs in order, marked "pinned:" when pinned. Private windows are never saved.
    static func save() {
        var groups: [[String]] = []
        var groupIDs: [String] = []
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        for controller in ordered where !controller.isPrivate {
            let tabs = controller.tabs.compactMap { tab in tab.sessionURL.map { (tab.isPinned ? "pinned:" : "") + $0 } }
            if !tabs.isEmpty {
                groups.append(tabs)
                groupIDs.append(controller.groupID ?? "")
            }
        }
        UserDefaults.standard.set(groups, forKey: key)
        UserDefaults.standard.set(groupIDs, forKey: "sessionGroupIDs")
        TabGroups.saveOpenGroups()
    }

    static func load() -> [(urls: [URL], pinned: [Bool], groupID: String?)] {
        let groups = UserDefaults.standard.array(forKey: key) as? [[String]] ?? []
        let groupIDs = UserDefaults.standard.stringArray(forKey: "sessionGroupIDs") ?? []
        return groups.enumerated().compactMap { index, group in
            var urls: [URL] = [], pinned: [Bool] = []
            for entry in group {
                let isPinned = entry.hasPrefix("pinned:")
                guard let url = URL(string: isPinned ? String(entry.dropFirst(7)) : entry) else { continue }
                urls.append(url)
                pinned.append(isPinned)
            }
            let groupID = groupIDs.indices.contains(index) && !groupIDs[index].isEmpty ? groupIDs[index] : nil
            return urls.isEmpty ? nil : (urls, pinned, TabGroups.group(groupID) == nil ? nil : groupID)
        }
    }
}

/// History window (⌘Y): search, open and delete visited pages.
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = HistoryWindowController()

    private let search = NSSearchField()
    private let table = NSTableView()
    private var rows: [History.Entry] = []
    var open: (URL) -> Void = { _ in }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Verlauf"
        window.setFrameAutosaveName("RookHistory")
        super.init(window: window)

        search.placeholderString = "Verlauf durchsuchen"
        search.delegate = self
        for (id, title, width) in [("title", "Titel", 300.0), ("url", "Adresse", 280.0), ("date", "Besucht", 140.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let openButton = NSButton(title: "Öffnen", target: self, action: #selector(openSelected))
        let deleteButton = NSButton(title: "Auswahl löschen", target: self, action: #selector(deleteSelected))
        let range = NSPopUpButton()
        range.addItems(withTitles: ["Löschen …", "Letzte Stunde", "Heute", "Heute und gestern", "Alles"])
        range.target = self
        range.action = #selector(deleteRange(_:))
        let buttons = NSStackView(views: [openButton, deleteButton, NSView(), range])

        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        reload()
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(search)
    }

    private func reload() {
        rows = History.shared.search(search.stringValue)
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "url": text = entry.url.absoluteString
        case "date": text = dateFormatter.string(from: entry.date)
        default: text = entry.title.isEmpty ? (entry.url.host ?? "") : entry.title
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue != "title" { label.textColor = .secondaryLabelColor }
        return label
    }

    @objc private func openSelected() {
        let urls = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].url : nil }
        urls.forEach(open)
    }

    @objc private func deleteSelected() {
        let urls = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].url : nil })
        guard !urls.isEmpty else { NSSound.beep(); return }
        History.shared.remove(urls: urls)
        reload()
    }

    @objc private func deleteRange(_ sender: NSPopUpButton) {
        let calendar = Calendar.current
        let now = Date()
        switch sender.indexOfSelectedItem {
        case 1: History.shared.remove(since: now.addingTimeInterval(-3600))
        case 2: History.shared.remove(since: calendar.startOfDay(for: now))
        case 3: History.shared.remove(since: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!)
        case 4: Privacy.confirmClearHistory(in: window)
        default: break
        }
        sender.selectItem(at: 0)
        reload()
    }
}
