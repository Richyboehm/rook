import AppKit

/// Favorites live on the start page (its own storage). The browser hands new favorites over to it:
/// ⌘D and imports are queued here and picked up by the start page the next time it is shown
/// (rook://start/api/native.json). The start page reports its favorites back for the suggestions.
enum Favorites {
    struct Item: Codable, Equatable {
        let name: String
        let url: String
    }

    private static let pendingKey = "pendingFavorites"
    private static let knownKey = "knownFavorites"

    static var pending: [Item] {
        get { (UserDefaults.standard.data(forKey: pendingKey)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? [] }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: pendingKey)
            NotificationCenter.default.post(name: .rookFavoritesChanged, object: nil)
        }
    }

    /// Favorites as last seen on the start page (used for address bar suggestions).
    static var known: [Item] {
        get { (UserDefaults.standard.data(forKey: knownKey)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? [] }
        set {
            guard newValue != known else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: knownKey)
            NotificationCenter.default.post(name: .rookFavoritesChanged, object: nil)
        }
    }

    static func add(name: String, url: URL) {
        let item = Item(name: String(name.prefix(40)), url: url.absoluteString)
        guard !pending.contains(where: { $0.url == item.url }), !known.contains(where: { $0.url == item.url }) else { return }
        pending.append(item)
    }

    /// Imports bookmarks from an HTML export (Safari, Chrome, Firefox and Edge all use this format).
    /// Returns how many new favorites were found.
    static func importBookmarks(html: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"<A[^>]*HREF="([^"]+)"[^>]*>([^<]*)</A>"#, options: [.caseInsensitive]) else { return 0 }
        let range = NSRange(html.startIndex..., in: html)
        var added = 0
        for match in regex.matches(in: html, range: range) {
            guard let urlRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: decodeEntities(String(html[urlRange]))),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let title = decodeEntities(String(html[titleRange])).trimmingCharacters(in: .whitespaces)
            let before = pending.count
            add(name: title.isEmpty ? (url.host ?? "Favorit") : title, url: url)
            if pending.count > before { added += 1 }
        }
        return added
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Address bar suggestions: matching favorites and history entries, searched only on this Mac.
final class SuggestionsPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Suggestion {
        let title: String
        let detail: String
        let url: URL
        let symbol: String
    }

    private weak var field: NSTextField?
    private let open: (URL) -> Void
    private var panel: NSPanel?
    private let table = NSTableView()
    private(set) var items: [Suggestion] = []
    private var selected = -1

    init(field: NSTextField, open: @escaping (URL) -> Void) {
        self.field = field
        self.open = open
        super.init()
        let column = NSTableColumn(identifier: .init("s"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.target = self
        table.action = #selector(clicked)
    }

    /// The suggestion chosen with the arrow keys (nil = use what was typed).
    var selectedURL: URL? { selected > 0 && items.indices.contains(selected) ? items[selected].url : nil }

    static func matches(for text: String, history: [History.Entry], favorites: [Favorites.Item], limit: Int = 6) -> [Suggestion] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard query.count >= 1 else { return [] }
        var result: [Suggestion] = [], seen = Set<String>()
        func score(_ title: String, _ url: String) -> Int? {
            let host = URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
            if host.hasPrefix(query) { return 3 }
            if title.lowercased().hasPrefix(query) { return 2 }
            if host.contains(query) || title.lowercased().contains(query) { return 1 }
            return nil
        }
        var scored: [(Int, Suggestion)] = []
        for fav in favorites {
            if let s = score(fav.name, fav.url), let url = URL(string: fav.url), seen.insert(fav.url).inserted {
                scored.append((s + 10, Suggestion(title: fav.name, detail: BrowserWindowController.shortAddress(url), url: url, symbol: "star.fill")))
            }
        }
        for entry in history {
            let key = entry.url.absoluteString
            if let s = score(entry.title, key), seen.insert(key).inserted {
                scored.append((s, Suggestion(title: entry.title.isEmpty ? key : entry.title,
                                             detail: BrowserWindowController.shortAddress(entry.url), url: entry.url, symbol: "clock")))
            }
            if scored.count > 200 { break }
        }
        result = scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        return result
    }

    func update(for text: String, includeHistory: Bool) {
        guard let typed = Rook.url(forInput: text), !text.trimmingCharacters(in: .whitespaces).isEmpty else { hide(); return }
        let isSearch = typed.host == URL(string: (Rook.engines[Rook.engine] ?? ""))?.host
        let first = Suggestion(title: isSearch ? "„\(text)“ suchen" : "Gehe zu \(BrowserWindowController.shortAddress(typed))",
                               detail: isSearch ? Rook.engineName : typed.absoluteString, url: typed,
                               symbol: isSearch ? "magnifyingglass" : "arrow.right.circle")
        items = [first] + Self.matches(for: text, history: includeHistory ? History.shared.entries : [], favorites: Favorites.known)
        selected = 0
        show()
    }

    @discardableResult
    func move(by delta: Int) -> Bool {
        guard panel?.isVisible == true, !items.isEmpty else { return false }
        selected = max(0, min(items.count - 1, selected + delta))
        table.selectRowIndexes([selected], byExtendingSelection: false)
        table.scrollRowToVisible(selected)
        return true
    }

    func hide() {
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        selected = -1
    }

    private func show() {
        guard let field, let window = field.window else { return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            effect.layer?.masksToBounds = true
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = false
            scroll.autoresizingMask = [.width, .height]
            effect.addSubview(scroll)
            p.contentView = effect
            panel = p
        }
        guard let panel else { return }
        table.reloadData()
        table.selectRowIndexes([selected], byExtendingSelection: false)
        let frame = field.convert(field.bounds, to: nil)
        let screen = window.convertToScreen(frame)
        let height = CGFloat(items.count) * (table.rowHeight + 2) + 8
        panel.setFrame(NSRect(x: screen.minX, y: screen.minY - height - 4, width: max(screen.width, 420), height: height), display: true)
        (panel.contentView?.subviews.first as? NSScrollView)?.frame = panel.contentView!.bounds.insetBy(dx: 0, dy: 4)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        open(items[row].url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = item.symbol == "star.fill" ? .systemYellow : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let row = NSStackView(views: [icon, texts])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.spacing = 10
        return row
    }
}
