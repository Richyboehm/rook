import AppKit
import WebKit

/// One browser window with Rook's own tab bar. The window owns its tabs; the selected tab's web view
/// fills the area under the tab bar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate,
                                     NSSearchFieldDelegate, TabOwner, TabBarDelegate {
    static var all: [BrowserWindowController] = []
    /// Recently closed tabs (newest last) for ⇧⌘T. Private tabs are never remembered.
    static var closedTabs: [URL] = []

    let isPrivate: Bool
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedIndex = 0
    var currentTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    var webView: WKWebView? { currentTab?.webView }

    private let tabBar = TabBarView()
    private let webContainer = NSView()
    private let progressLine = ProgressLine()
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")

    private let addressField = AddressField()
    private let securityIcon = NSImageView()
    private let shieldButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let downloadsButton = DownloadButton()
    private lazy var suggestions = SuggestionsPopup(field: addressField) { [weak self] url in self?.go(to: url) }
    private lazy var downloadsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DownloadsViewController()
        return popover
    }()

    init(urls: [URL] = [Rook.startURL], pinned: [Bool] = [], isPrivate: Bool = false) {
        self.isPrivate = isPrivate
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

        for (i, url) in urls.enumerated() {
            let tab = makeTab(url: url)
            tab.isPinned = pinned.indices.contains(i) && pinned[i]
            tabs.append(tab)
        }
        if tabs.isEmpty { tabs.append(makeTab(url: Rook.startURL)) }
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

        let stack = NSStackView(views: [tabBar, findBar, webContainer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(progressLine)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            tabBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            findBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            webContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressLine.topAnchor.constraint(equalTo: webContainer.topAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2)
        ])
        window.contentView = content
    }

    // MARK: Toolbar

    private static let privateID = NSToolbarItem.Identifier("private")
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
        (isPrivate ? [Self.privateID] : []) +
            [Self.backID, Self.forwardID, Self.reloadID, .flexibleSpace, Self.addressID, .flexibleSpace, Self.downloadsID]
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
        case Self.backID: configure(backButton, item, "chevron.left", "Zurück", #selector(goBack))
        case Self.forwardID: configure(forwardButton, item, "chevron.right", "Vorwärts", #selector(goForward))
        case Self.reloadID: configure(reloadButton, item, "arrow.clockwise", "Neu laden", #selector(reloadPage))
        case Self.downloadsID: configure(downloadsButton, item, "arrow.down.circle", "Downloads", #selector(showDownloads))
        case Self.addressID:
            let box = NSStackView(views: [securityIcon, addressField, shieldButton])
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

    private func makeTab(url: URL?, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration, url: url, isPrivate: isPrivate)
        tab.owner = self
        return tab
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        currentTab?.webView.removeFromSuperview()
        selectedIndex = index
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
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(at: index)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if !isPrivate, let url = tab.displayURL, ["http", "https"].contains(url.scheme ?? "") {
            Self.closedTabs.append(url)
            if Self.closedTabs.count > 25 { Self.closedTabs.removeFirst() }
        }
        if tabs.count == 1 { window?.close(); return }
        tab.webView.removeFromSuperview()
        tab.close()
        tabs.remove(at: index)
        let next = index < selectedIndex ? selectedIndex - 1 : min(selectedIndex, tabs.count - 1)
        selectedIndex = -1
        select(index: next)
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
        downloadsPopover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .minY)
    }

    @objc private func downloadStarted() {
        guard window?.isKeyWindow == true, !downloadsPopover.isShown else { return }
        downloadsPopover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .minY)
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

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        suggestions.hide()
        for tab in tabs {
            if !isPrivate, let url = tab.displayURL, ["http", "https"].contains(url.scheme ?? "") { Self.closedTabs.append(url) }
            tab.close()
        }
        tabs.removeAll()
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
