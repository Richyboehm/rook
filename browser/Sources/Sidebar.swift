import AppKit

extension Notification.Name {
    /// Tab groups were added, renamed, deleted or their tabs changed.
    static let rookTabGroupsChanged = Notification.Name("RookTabGroupsChanged")
}

protocol SidebarDelegate: AnyObject {
    var groupID: String? { get }
    var tabs: [BrowserTab] { get }
    func switchGroup(to id: String?)
    func newGroup(fromCurrentTabs: Bool)
    func renameGroup(_ id: String)
    func deleteGroup(_ id: String)
    func copyLinks(of id: String?)
    func importSafariTabGroups()
}

/// The sidebar like in Safari: at the top the window's own tabs, below all tab groups.
/// A click switches, a right click renames, copies the links or deletes. At the bottom, always
/// visible: a new group and taking over Safari's tab groups.
final class SidebarView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let width: CGFloat = 230
    weak var delegate: SidebarDelegate?

    private enum Row {
        case loose
        case header
        case group(TabGroup)
        case empty
    }

    private var rows: [Row] = []
    /// Width of the sidebar; animated to 0 to fold it away.
    private(set) var widthConstraint: NSLayoutConstraint!
    private let table = NSTableView()
    private var shownTabCount = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.masksToBounds = true   // while folding, the content slides out instead of squeezing

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.focusRingType = .none
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Tab-Gruppen")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let newButton = Self.footerButton("Neue Tab-Gruppe", symbol: "plus", target: self, action: #selector(newGroupClicked))
        let importButton = Self.footerButton("Aus Safari übernehmen", symbol: "safari", target: self, action: #selector(importClicked))
        importButton.toolTip = "Deine Tab-Gruppen aus Safari einmal übernehmen"
        let separator = NSBox()
        separator.boxType = .separator
        let footer = NSStackView(views: [separator, newButton, importButton])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 4
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)

        for view in [scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            // Fixed inner width, only pinned on the left: folding the sidebar clips instead of squeezing.
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.widthAnchor.constraint(equalToConstant: Self.width),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: Self.width - 20),
            scroll.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.width)
        widthConstraint.isActive = true

        NotificationCenter.default.addObserver(self, selector: #selector(groupsChanged), name: .rookTabGroupsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private static func footerButton(_ title: String, symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: " " + title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: target, action: action)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    @objc private func groupsChanged() { reload() }

    /// Builds the rows again and marks the group this window shows.
    func reload() {
        let groups = TabGroups.all
        rows = [.loose, .header] + (groups.isEmpty ? [.empty] : groups.map(Row.group))
        shownTabCount = delegate?.tabs.count ?? 0
        table.reloadData()
        let selected = rows.firstIndex { row in
            switch row {
            case .loose: delegate?.groupID == nil
            case .group(let group): group.id == delegate?.groupID
            default: false
            }
        }
        if let selected { table.selectRowIndexes([selected], byExtendingSelection: false) }
    }

    /// The number of tabs in this window changed (cheap: only rebuilds when it really changed).
    func tabsChanged() {
        if delegate?.tabs.count != shownTabCount { reload() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .loose, .group: true
        default: false
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header:
            let label = NSTextField(labelWithString: "Tab-Gruppen")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .empty:
            let label = NSTextField(wrappingLabelWithString: "Noch keine Gruppen. Leg unten eine an oder übernimm sie aus Safari.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            return label
        case .loose:
            let count = delegate?.groupID == nil ? delegate?.tabs.count ?? 0 : nil
            return cell(symbol: "macwindow", title: count.map { $0 == 1 ? "1 Tab" : "\($0) Tabs" } ?? "Ohne Gruppe", count: nil)
        case .group(let group):
            let count = group.id == delegate?.groupID ? delegate?.tabs.count ?? group.tabs.count : group.tabs.count
            return cell(symbol: "square.on.square", title: group.name, count: count)
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .empty = rows[row] { return 46 }
        return 28
    }

    private func cell(symbol: String, title: String, count: Int?) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        var views: [NSView] = [icon, label]
        if let count {
            let number = NSTextField(labelWithString: "\(count)")
            number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            number.textColor = .tertiaryLabelColor
            number.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views += [NSView(), number]
        }
        let stack = NSStackView(views: views)
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 6)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(title)
        return stack
    }

    /// The group under a point in the window (nil for none, "" for the loose tabs); for dropping tabs.
    func groupID(at windowPoint: NSPoint) -> String? {
        guard !isHidden else { return nil }
        let point = table.convert(windowPoint, from: nil)
        let row = table.row(at: point)
        guard table.bounds.contains(point), rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .group(let group): return group.id
        case .loose: return ""
        default: return nil
        }
    }

    /// Marks the row a tab would be dropped on (or the current group again when none).
    func highlightDrop(at windowPoint: NSPoint) {
        let point = table.convert(windowPoint, from: nil)
        let row = table.bounds.contains(point) ? table.row(at: point) : -1
        if rows.indices.contains(row), tableView(table, shouldSelectRow: row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            reload()
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .loose: delegate?.switchGroup(to: nil)
        case .group(let group): delegate?.switchGroup(to: group.id)
        default: break
        }
        reload()
    }

    @objc private func newGroupClicked() { delegate?.newGroup(fromCurrentTabs: false) }
    @objc private func importClicked() { delegate?.importSafariTabGroups() }

    // MARK: Right click

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        func add(_ title: String, _ action: @escaping () -> Void) { menu.addItem(ClosureMenuItem(title: title, action: action)) }
        switch rows[row] {
        case .loose:
            if delegate?.groupID == nil {
                add("Neue Gruppe aus diesen Tabs …") { [weak self] in self?.delegate?.newGroup(fromCurrentTabs: true) }
                add("Links kopieren") { [weak self] in self?.delegate?.copyLinks(of: nil) }
            }
        case .group(let group):
            add("Öffnen") { [weak self] in self?.delegate?.switchGroup(to: group.id) }
            add("Umbenennen …") { [weak self] in self?.delegate?.renameGroup(group.id) }
            add("Links kopieren") { [weak self] in self?.delegate?.copyLinks(of: group.id) }
            menu.addItem(.separator())
            add("Gruppe löschen …") { [weak self] in self?.delegate?.deleteGroup(group.id) }
        default:
            break
        }
    }
}
