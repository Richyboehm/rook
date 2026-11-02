import AppKit
import WebKit

/// One browser window with Rook's own tab bar. The window owns its tabs; the selected tab's web view
/// fills the area under the tab bar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate,
                                     NSSearchFieldDelegate, TabOwner, TabBarDelegate, SidebarDelegate, NSMenuItemValidation {
    static var all: [BrowserWindowController] = []
    /// Recently closed tabs (newest last) for ⇧⌘T. Private tabs are never remembered.
    static var closedTabs: [URL] = []

    let isPrivate: Bool
    /// The tab group this window shows; nil for the window's own loose tabs.
    private(set) var groupID: String?
    /// The loose tabs, kept while the window shows a group, so "Ohne Gruppe" brings them back.
    private var looseTabs: [TabGroup.Tab]?
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedIndex = 0
    var currentTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    var webView: WKWebView? { currentTab?.webView }

    private let tabBar = TabBarView()
    private let favoritesBar = FavoritesBar()
    private let sidebar = SidebarView()
    private let sidebarButton = NSButton()
    /// Writes the group's tabs shortly after the last change, so a group is always up to date.
    private var groupSave: DispatchWorkItem?
    private let webContainer = NSView()
    private let progressLine = ProgressLine()
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")

    private let addressField = AddressField()
    private let securityIcon = NSImageView()
    private let shieldButton = NSButton()
    private let readerButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let downloadsButton = DownloadButton()
    private let groupsButton = NSButton()
    private let shareButton = NSButton()
    private lazy var suggestions = SuggestionsPopup(field: addressField) { [weak self] url in self?.go(to: url) }
    private lazy var downloadsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DownloadsViewController()
        return popover
    }()

    init(urls: [URL] = [Rook.startURL], pinned: [Bool] = [], titles: [String] = [], isPrivate: Bool = false,
         groupID: String? = nil) {
        self.isPrivate = isPrivate
        self.groupID = isPrivate ? nil : groupID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed          // Rook draws its own tabs
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("RookWindow")
        if !window.setFrameUsingName("RookWindow") { window.center() }
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        super.init(window: window)
        window.delegate = self

        setUpLayout()
        setUpToolbar()
        NotificationCenter.default.addObserver(self, selector: #selector(downloadStarted), name: .rookDownloadStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsChanged), name: .rookDownloadsChanged, object: nil)
        BrowserWindowController.all.append(self)

        loadTabs(urls: urls, pinned: pinned, titles: titles)
        updateGroupsButton()
        sidebar.reload()
        NotificationCenter.default.addObserver(self, selector: #selector(groupsChanged), name: .rookTabGroupsChanged, object: nil)
    }

    /// A group was deleted elsewhere (e.g. in another window): this window keeps its tabs without the group.
    @objc private func groupsChanged() {
        if let groupID, TabGroups.group(groupID) == nil {
            self.groupID = nil
            updateGroupsButton()
        } else {
            updateGroupsButton()
        }
    }

    var sidebarVisible: Bool { !sidebar.isHidden }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSidebar) {
            item.title = sidebarVisible ? "Seitenleiste ausblenden" : "Seitenleiste einblenden"
            return !isPrivate
        }
        if item.action == #selector(toggleFavoritesBar) {
            item.title = favoritesBar.isHidden ? "Favoritenleiste einblenden" : "Favoritenleiste ausblenden"
            return !isPrivate
        }
        if item.action == #selector(toggleReader) {
            return currentTab?.displayURL.map { ["http", "https"].contains($0.scheme ?? "") } ?? false
        }
        return true
    }

    /// Slides the sidebar in or out (⇧⌘L, like Safari).
    @objc func toggleSidebar() {
        guard !isPrivate else { return }
        let show = sidebar.isHidden
        Settings.sidebarVisible = show
        if show {
            sidebar.reload()
            sidebar.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            sidebar.widthConstraint.animator().constant = show ? SidebarView.width : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            if !show { self?.sidebar.isHidden = true }
        })
        sidebarButton.state = show ? .on : .off
    }

    /// Shows or hides the favorites bar in all normal windows (⇧⌘B, like Safari).
    @objc func toggleFavoritesBar() {
        guard !isPrivate else { return }
        Settings.favoritesBarVisible = favoritesBar.isHidden
        for controller in Self.all where !controller.isPrivate {
            controller.favoritesBar.isHidden = !Settings.favoritesBarVisible
        }
    }

    /// Lays the article over the page in calm type, or closes it again (⇧⌘R, like Safari).
    @objc func toggleReader() {
        guard let web = webView else { return }
        Reader.toggle(in: web) { found in
            if !found { NSSound.beep() }
        }
    }

    /// Saves the group's tabs one second after the last change (tabs opened, closed, moved or navigated).
    private func scheduleGroupSave() {
        sidebar.tabsChanged()
        guard let groupID, !isPrivate else { return }
        groupSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.groupID == groupID else { return }
            TabGroups.update(groupID, tabs: self.snapshot())
        }
        groupSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Fills the window with tabs; only the first one loads right away, the others when they are shown.
    private func loadTabs(urls: [URL], pinned: [Bool], titles: [String]) {
        for (i, url) in urls.enumerated() {
            let tab = makeTab(url: url, deferred: i > 0)
            tab.isPinned = pinned.indices.contains(i) && pinned[i]
            if titles.indices.contains(i) { tab.pendingTitle = titles[i] }
            tabs.append(tab)
        }
        if tabs.isEmpty { tabs.append(makeTab(url: Rook.startURL)) }
        selectedIndex = -1
        select(index: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Layout

    private func setUpLayout() {
        guard let window else { return }
        let content = NSView()
        tabBar.delegate = self
        if isPrivate {
            tabBar.wantsLayer = true
            tabBar.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.14).cgColor
        }

        findField.placeholderString = "Auf Seite suchen"
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findNext)
        findField.sendsWholeSearchString = false
        findField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        findStatus.textColor = .secondaryLabelColor
        findStatus.font = .systemFont(ofSize: 11)
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Vorheriger Treffer")!, target: self, action: #selector(findPrevious))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Nächster Treffer")!, target: self, action: #selector(findNext))
        let done = NSButton(title: "Fertig", target: self, action: #selector(hideFindBar))
        [findField, findStatus, NSView(), previous, next, done].forEach(findBar.addArrangedSubview)
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        findBar.isHidden = true

        // Same dark as the start page, so a new tab never flashes white while it loads.
        webContainer.wantsLayer = true
        webContainer.layer?.backgroundColor = NSColor(srgbRed: 11 / 255, green: 11 / 255, blue: 13 / 255, alpha: 1).cgColor

        favoritesBar.isHidden = isPrivate || !Settings.favoritesBarVisible
        favoritesBar.open = { [weak self] url, newTab in
            guard let self else { return }
            if newTab { self.openTab(url: url, configuration: nil, background: true) } else { self.go(to: url) }
        }
        let stack = NSStackView(views: [favoritesBar, tabBar, findBar, webContainer])
        stack.orientation = .vertical
        stack.spacing = 0
        sidebar.delegate = self
        let showSidebar = !isPrivate && Settings.sidebarVisible
        sidebar.widthConstraint.constant = showSidebar ? SidebarView.width : 0
        sidebar.isHidden = !showSidebar
        let row = NSStackView(views: [sidebar, stack])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        sidebar.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        stack.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(progressLine)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            favoritesBar.heightAnchor.constraint(equalToConstant: FavoritesBar.height),
            favoritesBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            tabBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            findBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            webContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressLine.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressLine.topAnchor.constraint(equalTo: webContainer.topAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2)
        ])
        window.contentView = content
    }

    // MARK: Toolbar

    private static let privateID = NSToolbarItem.Identifier("private")
    private static let groupsID = NSToolbarItem.Identifier("groups")
    private static let sidebarID = NSToolbarItem.Identifier("sidebar")
    private static let shareID = NSToolbarItem.Identifier("share")
    private static let backID = NSToolbarItem.Identifier("back")
    private static let forwardID = NSToolbarItem.Identifier("forward")
    private static let reloadID = NSToolbarItem.Identifier("reload")
    private static let addressID = NSToolbarItem.Identifier("address")
    private static let downloadsID = NSToolbarItem.Identifier("downloads")

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: isPrivate ? "RookPrivateToolbar2" : "RookToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar

        addressField.placeholderString = isPrivate ? "Privat: Suchen oder Adresse eingeben" : "Suchen oder Adresse eingeben"
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 13)
        addressField.alignment = .center
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.isScrollable = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.setAccessibilityLabel("Adressleiste")
        addressField.onFocus = { [weak self] in self?.addressFocused() }

        securityIcon.imageScaling = .scaleProportionallyDown
        securityIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true

        shieldButton.isBordered = false
        shieldButton.target = self
        shieldButton.action = #selector(toggleBlockingForSite)
        shieldButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (isPrivate ? [Self.privateID] : [Self.sidebarID, Self.groupsID]) +
            [Self.backID, Self.forwardID, Self.reloadID, .flexibleSpace, Self.addressID, .flexibleSpace, Self.shareID, Self.downloadsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.privateID:
            let badge = NSButton(title: " Privat", image: NSImage(systemSymbolName: "theatermasks.fill", accessibilityDescription: nil)!,
                                 target: nil, action: nil)
            badge.isBordered = false
            badge.imagePosition = .imageLeading
            badge.contentTintColor = .systemPurple
            badge.font = .systemFont(ofSize: 12, weight: .semibold)
            badge.toolTip = "Privates Fenster: kein Verlauf, Cookies nur bis zum Schließen"
            item.view = badge
            item.label = "Privat"
        case Self.sidebarID: configure(sidebarButton, item, "sidebar.left", "Seitenleiste", #selector(toggleSidebar))
        case Self.groupsID:
            groupsButton.bezelStyle = .texturedRounded
            groupsButton.isBordered = false
            groupsButton.imagePosition = .imageLeading
            groupsButton.font = .systemFont(ofSize: 12, weight: .medium)
            groupsButton.target = self
            groupsButton.action = #selector(showGroupsMenu)
            groupsButton.toolTip = "Tab-Gruppen"
            groupsButton.setAccessibilityLabel("Tab-Gruppen")
            updateGroupsButton()
            item.view = groupsButton
            item.label = "Tab-Gruppen"
        case Self.backID: configure(backButton, item, "chevron.left", "Zurück", #selector(goBack))
        case Self.forwardID: configure(forwardButton, item, "chevron.right", "Vorwärts", #selector(goForward))
        case Self.reloadID: configure(reloadButton, item, "arrow.clockwise", "Neu laden", #selector(reloadPage))
        case Self.downloadsID: configure(downloadsButton, item, "arrow.down.circle", "Downloads", #selector(showDownloads))
        case Self.shareID: configure(shareButton, item, "square.and.arrow.up", "Teilen", #selector(showShareMenu))
        case Self.addressID:
            readerButton.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "Leseansicht")
            readerButton.isBordered = false
            readerButton.contentTintColor = .secondaryLabelColor
            readerButton.toolTip = "Leseansicht (⇧⌘R)"
            readerButton.target = self
            readerButton.action = #selector(toggleReader)
            readerButton.isHidden = true
            readerButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let box = NSStackView(views: [securityIcon, addressField, readerButton, shieldButton])
            box.spacing = 6
            item.view = box
            item.label = "Adresse"
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            addressField.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
            let preferred = addressField.widthAnchor.constraint(equalToConstant: 560)
            preferred.priority = .defaultLow
            preferred.isActive = true
        default: return nil
        }
        return item
    }

    private func configure(_ button: NSButton, _ item: NSToolbarItem, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        item.view = button
        item.label = label
    }

    // MARK: Tabs

    private func makeTab(url: URL?, configuration: WKWebViewConfiguration? = nil, deferred: Bool = false) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration, url: url, isPrivate: isPrivate, deferred: deferred)
        tab.owner = self
        (tab.webView as? RookWebView)?.pageMenuItems = { [weak self, weak tab] in
            guard let self, let tab, tab.displayURL != nil else { return [] }
            let copy = ClosureMenuItem(title: "Adresse kopieren") { [weak self] in self?.copyAddress(of: tab) }
            guard !self.isPrivate else { return [copy] }
            let group = NSMenuItem(title: "Zur Tab-Gruppe hinzufügen", action: nil, keyEquivalent: "")
            group.submenu = self.groupChoices { [weak self] id in self?.addPage(of: tab, toGroup: id) }
            return [copy, group]
        }
        return tab
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        currentTab?.webView.removeFromSuperview()
        selectedIndex = index
        tabs[index].loadIfNeeded()
        let web = tabs[index].webView
        web.frame = webContainer.bounds
        web.autoresizingMask = [.width, .height]
        webContainer.addSubview(web)
        tabBar.reload()
        updateToolbar()
        if findBar.isHidden == false { find(backwards: false) }
        if tabs[index].isStartPage { window?.makeFirstResponder(web) }
    }

    func selectTab(at index: Int) { select(index: index) }

    @discardableResult
    func openTab(url: URL?, configuration: WKWebViewConfiguration?, background: Bool) -> BrowserTab {
        let tab = makeTab(url: url, configuration: configuration)
        // New tabs open right after the current one (pinned tabs stay in front).
        let insertAt = max(tabs.lastIndex(where: \.isPinned).map { $0 + 1 } ?? 0, selectedIndex + 1)
        tabs.insert(tab, at: min(insertAt, tabs.count))
        if background {
            if insertAt <= selectedIndex { selectedIndex += 1 }
            tabBar.reload()
        } else {
            select(index: tabs.firstIndex { $0 === tab }!)
        }
        scheduleGroupSave()
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(at: index)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 { window?.close(); return }   // windowWillClose remembers the tab
        let tab = tabs[index]
        if !isPrivate, let url = tab.displayURL, ["http", "https"].contains(url.scheme ?? "") {
            Self.closedTabs.append(url)
            if Self.closedTabs.count > 25 { Self.closedTabs.removeFirst() }
        }
        tab.webView.removeFromSuperview()
        tab.close()
        tabs.remove(at: index)
        let next = index < selectedIndex ? selectedIndex - 1 : min(selectedIndex, tabs.count - 1)
        selectedIndex = -1
        select(index: next)
        scheduleGroupSave()
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let selected = currentTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        // Pinned tabs always stay in front.
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        selectedIndex = tabs.firstIndex { $0 === selected } ?? 0
        tabBar.reload()
        scheduleGroupSave()
    }

    func menuForTab(at index: Int) -> NSMenu {
        let menu = NSMenu()
        guard tabs.indices.contains(index) else { return menu }
        let tab = tabs[index]
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            menu.addItem(item)
        }
        add(tab.isPinned ? "Tab lösen" : "Tab anheften") { [weak self] in self?.togglePin(index) }
        add("Tab duplizieren") { [weak self] in
            guard let self else { return }
            self.select(index: index)
            self.duplicateTab()
        }
        add("In neues Fenster verschieben") { [weak self] in self?.moveToNewWindow(index) }
        if !isPrivate {
            let move = NSMenuItem(title: "In Tab-Gruppe verschieben", action: nil, keyEquivalent: "")
            move.submenu = groupChoices { [weak self, weak tab] id in
                guard let self, let tab, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
                self.moveTab(at: index, toGroup: id)
            }
            menu.addItem(move)
        }
        add("Adresse kopieren") { [weak self] in self?.copyAddress(of: tab) }
        if tab.isPlayingAudio || tab.isMuted {
            add(tab.isMuted ? "Ton wieder einschalten" : "Tab stummschalten") { tab.toggleMute() }
        }
        menu.addItem(.separator())
        add("Tab schließen") { [weak self] in self?.closeTab(at: index) }
        add("Andere Tabs schließen") { [weak self] in
            guard let self else { return }
            let keep = self.tabs[index]
            for t in self.tabs where t !== keep && !t.isPinned { self.closeTab(t) }
        }
        return menu
    }

    private func togglePin(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isPinned.toggle()
        moveTab(from: index, to: index)   // re-sorts pinned tabs to the front
    }

    private func moveToNewWindow(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index), let url = tabs[index].displayURL ?? Optional(Rook.startURL) else { return }
        closeTab(at: index)
        let controller = BrowserWindowController(urls: [url], isPrivate: isPrivate)
        controller.window?.setFrameTopLeftPoint(NSPoint(x: (window?.frame.minX ?? 0) + 40, y: (window?.frame.maxY ?? 0) - 40))
        controller.showWindow(nil)
    }

    /// "Delete history completely": open tabs keep their page but lose their back/forward list.
    func forgetBackForwardHistory() {
        for (i, tab) in tabs.enumerated() where tab.webView.canGoBack || tab.webView.canGoForward {
            let fresh = makeTab(url: tab.displayURL ?? Rook.startURL)
            fresh.isPinned = tab.isPinned
            if i == selectedIndex { tab.webView.removeFromSuperview() }
            tab.close()
            tabs[i] = fresh
        }
        let current = selectedIndex
        selectedIndex = -1
        select(index: current)
    }

    /// ⌘, opens the settings of the start page (the gear) in a new tab.
    @objc func showSettings() {
        openTab(url: URL(string: "rook://start/#settings"), configuration: nil, background: false)
    }

    func tabChanged(_ tab: BrowserTab) {
        tabBar.reload()
        if !tab.webView.isLoading { scheduleGroupSave() }
        if tab === currentTab { updateToolbar() }
    }

    // MARK: Toolbar state

    private func updateToolbar() {
        guard let tab = currentTab else { return }
        let web = tab.webView
        window?.title = (isPrivate ? "Privat · " : "") + tab.title
        backButton.isEnabled = web.canGoBack
        forwardButton.isEnabled = web.canGoForward
        reloadButton.image = NSImage(systemSymbolName: web.isLoading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: web.isLoading ? "Laden abbrechen" : "Neu laden")
        reloadButton.toolTip = web.isLoading ? "Laden abbrechen" : "Neu laden"
        progressLine.isLoading = web.isLoading
        progressLine.progress = web.estimatedProgress
        progressLine.color = isPrivate ? .systemPurple : .controlAccentColor
        updateAddress()
        updateSecurity()
        updateShield()
        readerButton.isHidden = !tab.readerAvailable
    }

    private var isEditingAddress: Bool { window?.firstResponder == addressField.currentEditor() }

    /// Like Safari: only the website's name while browsing, the full address while editing.
    private func updateAddress() {
        if isEditingAddress { return }
        addressField.alignment = .center
        addressField.stringValue = currentTab?.displayURL.map(Self.shortAddress) ?? ""
    }

    static func shortAddress(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func addressFocused() {
        addressField.alignment = .left
        addressField.stringValue = currentTab?.displayURL?.absoluteString ?? ""
        addressField.currentEditor()?.selectAll(nil)
    }

    private func updateSecurity() {
        guard let url = currentTab?.displayURL, url.scheme == "https" || url.scheme == "http" else {
            securityIcon.image = nil
            securityIcon.toolTip = nil
            return
        }
        if url.scheme == "https" && currentTab?.webView.hasOnlySecureContent == true {
            securityIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Sichere Verbindung")
            securityIcon.contentTintColor = .secondaryLabelColor
            securityIcon.toolTip = "Sichere Verbindung (verschlüsselt)"
        } else {
            securityIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Nicht sicher")
            securityIcon.contentTintColor = .systemOrange
            securityIcon.toolTip = "Nicht sicher. Die Verbindung ist ganz oder teilweise unverschlüsselt."
        }
    }

    /// Shield next to the address: blocker active (accent) or switched off for this site (crossed out).
    private func updateShield() {
        let blocker = ContentBlocker.shared
        guard blocker.isEnabled, let url = currentTab?.displayURL, ContentBlocker.site(of: url) != nil else {
            shieldButton.isHidden = true
            return
        }
        shieldButton.isHidden = false
        let allowed = blocker.isAllowed(url)
        shieldButton.image = NSImage(systemSymbolName: allowed ? "shield.slash" : "shield.lefthalf.filled",
                                     accessibilityDescription: allowed ? "Werbeblocker hier aus" : "Werbeblocker aktiv")
        shieldButton.contentTintColor = allowed ? .tertiaryLabelColor : (isPrivate ? .systemPurple : .controlAccentColor)
        shieldButton.toolTip = allowed ? "Werbung wird auf dieser Website nicht blockiert. Klicken zum Einschalten."
                                       : "Werbung und Tracker werden blockiert. Klicken, um sie hier zu erlauben."
    }

    @objc func toggleBlockingForSite() {
        guard let tab = currentTab, let url = tab.displayURL else { NSSound.beep(); return }
        shieldButton.isEnabled = false
        ContentBlocker.shared.toggleSite(of: url) { [weak self] in
            self?.shieldButton.isEnabled = true
            self?.updateShield()
            tab.webView.reload()
        }
    }

    // MARK: Address bar

    private func go(to url: URL) {
        suggestions.hide()
        currentTab?.load(url)
        window?.makeFirstResponder(currentTab?.webView)
        updateAddress()
    }

    @objc private func addressEntered() {
        if let url = suggestions.selectedURL ?? Rook.url(forInput: addressField.stringValue) { go(to: url) }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === findField { find(backwards: false); return }
        guard (obj.object as? NSTextField) === addressField else { return }
        suggestions.update(for: addressField.stringValue, includeHistory: !isPrivate)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addressField else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): return suggestions.move(by: 1)
        case #selector(NSResponder.moveUp(_:)): return suggestions.move(by: -1)
        case #selector(NSResponder.cancelOperation(_:)):
            suggestions.hide()
            window?.makeFirstResponder(currentTab?.webView)
            updateAddress()
            return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        DispatchQueue.main.async { [weak self] in
            self?.suggestions.hide()
            self?.updateAddress()
        }
    }

    // MARK: Actions (menus and toolbar)

    @objc func goBack() { currentTab?.webView.goBack() }
    @objc func goForward() { currentTab?.webView.goForward() }
    @objc func reloadPage() { currentTab?.reload() }
    @objc func reloadFromOrigin() { currentTab?.webView.reloadFromOrigin() }
    @objc func goHome() { currentTab?.load(Rook.startURL) }
    @objc func focusAddress() { window?.makeFirstResponder(addressField) }
    @objc func zoomIn() { if let t = currentTab { t.setZoom(min(t.webView.pageZoom + 0.1, 3)) } }
    @objc func zoomOut() { if let t = currentTab { t.setZoom(max(t.webView.pageZoom - 0.1, 0.5)) } }
    @objc func actualSize() { currentTab?.setZoom(1) }
    @objc func newTab() { openTab(url: Rook.startURL, configuration: nil, background: false) }
    @objc func closeCurrentTab() { closeTab(at: selectedIndex) }
    @objc func showNextTab() { select(index: (selectedIndex + 1) % max(tabs.count, 1)) }
    @objc func showPreviousTab() { select(index: (selectedIndex - 1 + tabs.count) % max(tabs.count, 1)) }
    @objc func togglePinCurrentTab() { togglePin(selectedIndex) }

    @objc func duplicateTab() {
        openTab(url: currentTab?.displayURL ?? Rook.startURL, configuration: nil, background: false)
    }

    /// ⌘1 … ⌘8 select a tab, ⌘9 the last one (like Safari).
    func selectTab(number: Int) {
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { select(index: index) } else { NSSound.beep() }
    }

    @objc func addToFavorites() {
        guard let tab = currentTab, let url = tab.displayURL, ["http", "https"].contains(url.scheme ?? "") else {
            NSSound.beep(); return
        }
        Favorites.add(name: tab.title, url: url)
        let popover = NSPopover()
        popover.behavior = .transient
        let label = NSTextField(labelWithString: "★ Zu Favoriten hinzugefügt")
        label.font = .systemFont(ofSize: 12)
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 34))
        label.frame = NSRect(x: 12, y: 9, width: 340, height: 16)
        vc.view.addSubview(label)
        popover.contentViewController = vc
        popover.show(relativeTo: addressField.bounds, of: addressField, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { popover.close() }
    }

    @objc func showDownloads() {
        guard let window, window.isVisible else { return }
        if downloadsPopover.isShown { downloadsPopover.close(); return }
        showDownloadsPopover()
    }

    @objc private func downloadStarted() {
        // Only for the window in front, and never while a sheet or dialog is open.
        guard let window, window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !downloadsPopover.isShown else { return }
        showDownloadsPopover()
    }

    /// AppKit stops the app if a popover is shown on a view that is not on screen, for example when the
    /// downloads button sits in the toolbar's » menu of a narrow window. Then the list opens below the
    /// top right corner of the page instead.
    private func showDownloadsPopover() {
        let button = downloadsButton
        if button.window != nil, !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty {
            downloadsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = window?.contentView, content.window != nil, !content.bounds.isEmpty {
            let corner = NSRect(x: content.bounds.maxX - 40, y: content.isFlipped ? 0 : content.bounds.maxY - 1, width: 24, height: 1)
            downloadsPopover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
    }

    @objc private func downloadsChanged() {
        downloadsButton.progress = DownloadManager.shared.overallProgress
    }

    @objc func printPage() {
        guard let window, let web = currentTab?.webView else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = web.printOperation(with: info)
        operation.view?.frame = web.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Find on page (⌘F)

    @objc func showFindBar() {
        findBar.isHidden = false
        window?.makeFirstResponder(findField)
    }

    @objc func hideFindBar() {
        findBar.isHidden = true
        window?.makeFirstResponder(currentTab?.webView)
    }

    @objc func findNext() { find(backwards: false) }
    @objc func findPrevious() { find(backwards: true) }

    private func find(backwards: Bool) {
        let text = findField.stringValue
        guard !text.isEmpty, let web = currentTab?.webView else { findStatus.stringValue = ""; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        web.find(text, configuration: config) { [weak self] result in
            self?.findStatus.stringValue = result.matchFound ? "" : "Nicht gefunden"
        }
    }

    // MARK: Tab groups

    /// The window's tabs as they would be saved (pages that cannot be restored are left out).
    func snapshot() -> [TabGroup.Tab] {
        tabs.compactMap { tab in
            tab.sessionURL.map { TabGroup.Tab(url: $0, title: tab.isStartPage ? "" : tab.title, pinned: tab.isPinned) }
        }
    }

    private func updateGroupsButton() {
        let name = TabGroups.group(groupID)?.name
        groupsButton.image = NSImage(systemSymbolName: name == nil ? "square.on.square" : "square.on.square.fill",
                                     accessibilityDescription: nil)
        groupsButton.title = name.map { " \($0)" } ?? ""
        groupsButton.toolTip = name.map { "Tab-Gruppe „\($0)“" } ?? "Tab-Gruppen"
        window?.title = name ?? "Rook Search"
    }

    @objc func showGroupsMenu() {
        let menu = NSMenu()
        func add(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            item.state = checked ? .on : .off
            menu.addItem(item)
            return item
        }
        _ = add("Ohne Gruppe", checked: groupID == nil) { [weak self] in self?.switchGroup(to: nil) }
        let groups = TabGroups.all
        if !groups.isEmpty { menu.addItem(.separator()) }
        for group in groups {
            let item = add(group.name, checked: group.id == groupID) { [weak self] in self?.switchGroup(to: group.id) }
            if #available(macOS 14, *) { item.badge = NSMenuItemBadge(count: group.tabs.count) }
        }
        menu.addItem(.separator())
        _ = add("Neue Tab-Gruppe …") { [weak self] in self?.newGroup(fromCurrentTabs: false) }
        if groupID == nil {
            _ = add("Neue Gruppe aus diesen Tabs …") { [weak self] in self?.newGroup(fromCurrentTabs: true) }
        } else {
            _ = add("Gruppe umbenennen …") { [weak self] in if let id = self?.groupID { self?.renameGroup(id) } }
            _ = add("Gruppe löschen …") { [weak self] in if let id = self?.groupID { self?.deleteGroup(id) } }
        }
        menu.addItem(.separator())
        _ = add("Tab-Gruppen aus Safari übernehmen …") { [weak self] in self?.importSafariTabGroups() }
        _ = add("Gruppe aus kopierten Links …") { [weak self] in self?.groupFromClipboard() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: groupsButton.bounds.height + 4), in: groupsButton)
    }

    /// Saves the current tabs where they belong, then shows the other group (or the loose tabs).
    func switchGroup(to id: String?) {
        guard id != groupID else { return }
        // A group can be open in only one window: then just bring that window to the front.
        if let id, let other = BrowserWindowController.all.first(where: { $0 !== self && $0.groupID == id }) {
            other.window?.makeKeyAndOrderFront(nil)
            return
        }
        let current = snapshot()
        if let groupID { TabGroups.update(groupID, tabs: current) } else { looseTabs = current }

        let target: [TabGroup.Tab]
        if let id {
            target = TabGroups.group(id)?.tabs ?? []
        } else {
            target = looseTabs ?? []
            looseTabs = nil
        }
        groupID = id
        replaceTabs(with: target)
        updateGroupsButton()
        sidebar.reload()
        Session.save()
    }

    /// Closes all tabs and opens the given ones (without remembering them as closed tabs).
    private func replaceTabs(with entries: [TabGroup.Tab]) {
        for tab in tabs {
            tab.webView.removeFromSuperview()
            tab.close()
        }
        tabs.removeAll()
        let urls = entries.compactMap { URL(string: $0.url) }
        loadTabs(urls: urls, pinned: entries.map(\.pinned), titles: entries.map(\.title))
    }

    func newGroup(fromCurrentTabs: Bool) {
        guard let name = TabGroupDialogs.askName(title: fromCurrentTabs ? "Gruppe aus diesen Tabs" : "Neue Tab-Gruppe",
                                                 button: "Anlegen", in: window) else { return }
        if fromCurrentTabs {
            groupID = TabGroups.add(name: name, tabs: snapshot()).id
            updateGroupsButton()
            sidebar.reload()
            Session.save()
        } else {
            let group = TabGroups.add(name: name, tabs: [TabGroup.Tab(url: Rook.startURL.absoluteString, title: "", pinned: false)])
            switchGroup(to: group.id)
        }
    }

    func renameGroup(_ id: String) {
        guard let group = TabGroups.group(id),
              let name = TabGroupDialogs.askName(title: "Gruppe umbenennen", button: "Umbenennen", initial: group.name, in: window)
        else { return }
        TabGroups.rename(id, to: name)
        updateGroupsButton()
    }

    /// Copies the addresses of a group (or of this window's loose tabs), one per line.
    func copyLinks(of id: String?) {
        let entries = id == groupID ? snapshot() : TabGroups.group(id)?.tabs ?? []
        let links = entries.map(\.url).filter { !$0.hasPrefix("rook:") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    func importSafariTabGroups() {
        Settings.safariTabGroupsOffered = true
        TabGroupDialogs.importFromSafari()
    }

    /// Deletes a group. If this window shows it, its tabs stay open here as loose tabs.
    func deleteGroup(_ id: String) {
        guard let group = TabGroups.group(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Gruppe „\(group.name)“ löschen?"
        alert.informativeText = id == groupID
            ? "Die Tabs bleiben in diesem Fenster offen, nur die Gruppe verschwindet."
            : "Die Gruppe und ihre \(group.tabs.count) Tabs werden entfernt."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if id == groupID {
            groupID = nil
            looseTabs = nil
        }
        TabGroups.delete(id)
        updateGroupsButton()
        Session.save()
    }

    private func groupFromClipboard() {
        let links = TabGroups.linksFromClipboard()
        guard !links.isEmpty else {
            return TabGroupDialogs.info("Keine Links in der Zwischenablage",
                                        "Klick in Safari mit der rechten Maustaste auf eine Tab-Gruppe und wähle „Links kopieren“. Dann hier nochmal.")
        }
        guard let name = TabGroupDialogs.askName(title: "\(links.count) Links als neue Gruppe", button: "Anlegen", in: window)
        else { return }
        switchGroup(to: TabGroups.add(name: name, tabs: links).id)
    }

    // MARK: Teilen, Adresse kopieren, Seiten in Gruppen

    /// ⇧⌘C: copies the address of the current page.
    @objc func copyCurrentAddress() {
        guard let tab = currentTab else { return }
        copyAddress(of: tab)
    }

    func copyAddress(of tab: BrowserTab) {
        guard let url = tab.displayURL else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        // Short confirmation on the share button.
        shareButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Kopiert")
        shareButton.toolTip = "Adresse kopiert"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Teilen")
            self?.shareButton.toolTip = "Teilen"
        }
    }

    @objc func showShareMenu() {
        let menu = NSMenu()
        guard let tab = currentTab, let url = tab.displayURL else {
            menu.addItem(withTitle: "Auf dieser Seite gibt es nichts zu teilen", action: nil, keyEquivalent: "").isEnabled = false
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: shareButton.bounds.height + 4), in: shareButton)
            return
        }
        let copy = ClosureMenuItem(title: "Adresse kopieren") { [weak self] in self?.copyAddress(of: tab) }
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copy)
        if !isPrivate {
            let group = NSMenuItem(title: "Zur Tab-Gruppe hinzufügen", action: nil, keyEquivalent: "")
            group.submenu = groupChoices { [weak self] id in self?.addPage(of: tab, toGroup: id) }
            menu.addItem(group)
            menu.addItem(ClosureMenuItem(title: "Zu Favoriten hinzufügen") { [weak self] in self?.addToFavorites() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Teilen …") { [weak self] in
            guard let self else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: self.shareButton.bounds, of: self.shareButton, preferredEdge: .minY)
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: shareButton.bounds.height + 4), in: shareButton)
    }

    /// Menu with all tab groups (except the one shown here) and "new group".
    private func groupChoices(_ chosen: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        let groups = TabGroups.all.filter { $0.id != groupID }
        for group in groups {
            menu.addItem(ClosureMenuItem(title: group.name) { chosen(group.id) })
        }
        if !groups.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Neue Tab-Gruppe …") { [weak self] in
            guard let name = TabGroupDialogs.askName(title: "Neue Tab-Gruppe", button: "Anlegen", in: self?.window) else { return }
            chosen(TabGroups.add(name: name, tabs: []).id)
        })
        return menu
    }

    private func entry(for tab: BrowserTab) -> TabGroup.Tab? {
        tab.sessionURL.map { TabGroup.Tab(url: $0, title: tab.isStartPage ? "" : tab.title, pinned: false) }
    }

    /// Adds a copy of the page to a group (the tab stays here). If the group is open in another
    /// window, the page opens there right away.
    func addPage(of tab: BrowserTab, toGroup id: String) {
        guard let entry = entry(for: tab), let group = TabGroups.group(id) else { return }
        if let other = BrowserWindowController.all.first(where: { $0 !== self && $0.groupID == id }),
           let url = URL(string: entry.url) {
            other.openTab(url: url, configuration: nil, background: true)
        } else {
            TabGroups.update(id, tabs: group.tabs + [entry])
        }
    }

    /// Moves a tab into a group: it leaves this window and appears in the group.
    func moveTab(at index: Int, toGroup id: String) {
        guard tabs.indices.contains(index), id != groupID else { return }
        let tab = tabs[index]
        addPage(of: tab, toGroup: id)
        if tabs.count == 1 { openTab(url: Rook.startURL, configuration: nil, background: true) }
        guard let current = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.webView.removeFromSuperview()
        tab.close()
        tabs.remove(at: current)
        let next = current < selectedIndex ? selectedIndex - 1 : min(selectedIndex, tabs.count - 1)
        selectedIndex = -1
        select(index: next)
        scheduleGroupSave()
    }

    // MARK: Tab auf eine Gruppe in der Seitenleiste ziehen

    func dragTab(over windowPoint: NSPoint) { sidebar.highlightDrop(at: windowPoint) }

    func dropTab(at index: Int, windowPoint: NSPoint) -> Bool {
        guard let target = sidebar.groupID(at: windowPoint) else { return false }
        if !target.isEmpty { moveTab(at: index, toGroup: target) }
        sidebar.reload()
        return !target.isEmpty
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        suggestions.hide()
        if let groupID { TabGroups.update(groupID, tabs: snapshot()) }
        for tab in tabs {
            if !isPrivate, let url = tab.displayURL, ["http", "https"].contains(url.scheme ?? "") { Self.closedTabs.append(url) }
            tab.close()
        }
        tabs.removeAll()
        tabBar.reload()   // the closing window may still lay out (e.g. leaving full screen)
        BrowserWindowController.all.removeAll { $0 === self }
        if isPrivate, !BrowserWindowController.all.contains(where: { $0.isPrivate }) {
            Rook.discardPrivateSession()   // next private window starts without any cookies
        }
    }
}

/// Address field that tells us when it gets the keyboard focus (to show the full address).
final class AddressField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { self.onFocus?() } }
        return ok
    }
}

/// Download button with a progress ring while downloads are running (like Safari).
final class DownloadButton: NSButton {
    var progress: Double? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let progress else { return }
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let center = NSPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.tertiaryLabelColor.setStroke()
        track.lineWidth = 2
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.03, progress)), clockwise: true)
        NSColor.controlAccentColor.setStroke()
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        arc.stroke()
    }
}

/// The thin loading bar at the top of the page.
final class ProgressLine: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var isLoading = false { didSet { needsDisplay = true } }
    var color: NSColor = .controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        guard isLoading, progress < 1 else { return }
        color.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * max(0.05, progress), height: bounds.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Menu item that runs a closure (for the tab context menu).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}
