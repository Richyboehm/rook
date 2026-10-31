import AppKit
import WebKit

/// One tab = one window. macOS groups the windows into native tabs (like Safari),
/// so tab bar, ⌃⇥ switching, dragging tabs out and reordering come for free.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate,
                                     NSSearchFieldDelegate, WKNavigationDelegate, WKUIDelegate {
    static var all: [BrowserWindowController] = []
    /// Recently closed tabs (newest last) for ⇧⌘T. Private tabs are never remembered.
    static var closedTabs: [URL] = []

    let webView: WKWebView
    let isPrivate: Bool
    private let addressField = NSTextField()
    private let securityIcon = NSImageView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let downloadsButton = NSButton()
    private let progressLine = ProgressLine()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")
    private var findBar: NSTitlebarAccessoryViewController?
    private lazy var downloadsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DownloadsViewController()
        return popover
    }()
    private var observations: [NSKeyValueObservation] = []
    /// The address that failed to load while an error page is shown (for the address bar and ⌘R).
    private var failedURL: URL?

    init(configuration: WKWebViewConfiguration? = nil, url: URL? = Rook.startURL, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let config = configuration ?? (isPrivate ? Rook.privateConfiguration : Rook.configuration)
        webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Private tabs never mix with normal tabs.
        window.tabbingIdentifier = isPrivate ? "RookPrivateTab" : "RookTab"
        window.tabbingMode = .preferred
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("RookWindow")
        if !window.setFrameUsingName("RookWindow") { window.center() }
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        super.init(window: window)

        window.delegate = self
        window.contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        setUpToolbar()
        setUpProgressLine()
        observe()
        BrowserWindowController.all.append(self)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadStarted),
                                               name: .rookDownloadStarted, object: nil)
        if let url { load(url) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// What is saved for "restore tabs after restart".
    var currentURLForSession: String? {
        guard let url = webView.url else { return Rook.startURL.absoluteString }
        switch Rook.linkKind(for: url) {
        case .web where ["http", "https"].contains(url.scheme?.lowercased() ?? ""): return url.absoluteString
        case .startPage: return Rook.startURL.absoluteString
        default: return nil
        }
    }

    // MARK: Toolbar

    private static let backID = NSToolbarItem.Identifier("back")
    private static let forwardID = NSToolbarItem.Identifier("forward")
    private static let reloadID = NSToolbarItem.Identifier("reload")
    private static let addressID = NSToolbarItem.Identifier("address")
    private static let downloadsID = NSToolbarItem.Identifier("downloads")
    private static let newTabID = NSToolbarItem.Identifier("newTab")

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: isPrivate ? "RookPrivateToolbar" : "RookToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar

        addressField.placeholderString = isPrivate ? "Privat – suchen oder Adresse eingeben" : "Suchen oder Adresse eingeben"
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 13)
        addressField.alignment = .center
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.isScrollable = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.setAccessibilityLabel("Adressleiste")

        securityIcon.imageScaling = .scaleProportionallyDown
        securityIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backID, Self.forwardID, Self.reloadID, .flexibleSpace, Self.addressID, .flexibleSpace,
         Self.downloadsID, Self.newTabID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.backID: configure(backButton, item, "chevron.left", "Zurück", #selector(goBack))
        case Self.forwardID: configure(forwardButton, item, "chevron.right", "Vorwärts", #selector(goForward))
        case Self.reloadID: configure(reloadButton, item, "arrow.clockwise", "Neu laden", #selector(reloadPage))
        case Self.downloadsID: configure(downloadsButton, item, "arrow.down.circle", "Downloads", #selector(showDownloads))
        case Self.newTabID: configure(NSButton(), item, "plus", "Neuer Tab", #selector(newTab))
        case Self.addressID:
            let box = NSStackView(views: [securityIcon, addressField])
            box.spacing = 6
            item.view = box
            item.label = "Adresse"
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
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

    /// Thin loading bar directly under the toolbar.
    private func setUpProgressLine() {
        let accessory = NSTitlebarAccessoryViewController()
        progressLine.frame = NSRect(x: 0, y: 0, width: 100, height: 2)
        accessory.view = progressLine
        accessory.layoutAttribute = .bottom
        window?.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: State

    private func observe() {
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.updateTitle() },
            webView.observe(\.url) { [weak self] _, _ in
                self?.updateAddress()
                self?.updateSecurity()
            },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in self?.updateSecurity() },
            webView.observe(\.canGoBack) { [weak self] web, _ in self?.backButton.isEnabled = web.canGoBack },
            webView.observe(\.canGoForward) { [weak self] web, _ in self?.forwardButton.isEnabled = web.canGoForward },
            webView.observe(\.isLoading) { [weak self] web, _ in
                let symbol = web.isLoading ? "xmark" : "arrow.clockwise"
                self?.reloadButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: web.isLoading ? "Laden abbrechen" : "Neu laden")
                self?.reloadButton.toolTip = web.isLoading ? "Laden abbrechen" : "Neu laden"
                self?.progressLine.isLoading = web.isLoading
            },
            webView.observe(\.estimatedProgress) { [weak self] web, _ in self?.progressLine.progress = web.estimatedProgress },
            // Camera / microphone in use: shown in the tab title, like the indicator in Safari.
            webView.observe(\.cameraCaptureState) { [weak self] _, _ in self?.updateTitle() },
            webView.observe(\.microphoneCaptureState) { [weak self] _, _ in self?.updateTitle() }
        ]
    }

    private var isStartPage: Bool { webView.url?.scheme == "rook" }

    private func updateTitle() {
        let title = webView.title ?? ""
        var text = title.isEmpty ? (webView.url?.host ?? (isStartPage ? "Neuer Tab" : "Rook")) : title
        if webView.cameraCaptureState == .active || webView.microphoneCaptureState == .active { text = "● " + text }
        if isPrivate { text = "Privat · " + text }
        window?.title = text
        if !isPrivate, let url = webView.url { History.shared.updateTitle(url: url, title: title) }
    }

    private func updateAddress() {
        // Don't overwrite what the user is currently typing.
        if window?.firstResponder == addressField.currentEditor() { return }
        if let failedURL, webView.url?.absoluteString == "about:blank" {
            addressField.stringValue = failedURL.absoluteString
            return
        }
        addressField.stringValue = isStartPage ? "" : (webView.url?.absoluteString ?? "")
    }

    private func updateSecurity() {
        guard let url = webView.url, url.scheme == "https" || url.scheme == "http" else {
            securityIcon.image = nil
            securityIcon.toolTip = nil
            return
        }
        if url.scheme == "https" && webView.hasOnlySecureContent {
            securityIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Sichere Verbindung")
            securityIcon.contentTintColor = .secondaryLabelColor
            securityIcon.toolTip = "Sichere Verbindung (verschlüsselt)"
        } else {
            securityIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Nicht sicher")
            securityIcon.contentTintColor = .systemOrange
            securityIcon.toolTip = "Nicht sicher – die Verbindung ist ganz oder teilweise unverschlüsselt"
        }
    }

    // MARK: Actions

    func load(_ url: URL) {
        failedURL = nil
        webView.load(URLRequest(url: url))
    }

    @objc private func addressEntered() {
        guard let url = Rook.url(forInput: addressField.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(webView)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue { updateAddress() }
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func reloadPage() {
        if webView.isLoading { webView.stopLoading() }
        else if let failedURL { load(failedURL) }      // on an error page: try the real address again
        else { webView.reload() }
    }
    @objc func reloadFromOrigin() { webView.reloadFromOrigin() }
    @objc func goHome() { load(Rook.startURL) }
    @objc func focusAddress() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }
    @objc func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func actualSize() { webView.pageZoom = 1 }

    @objc func showDownloads() {
        guard let window, window.isVisible else { return }
        if downloadsPopover.isShown { downloadsPopover.close(); return }
        downloadsPopover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .minY)
    }

    @objc private func downloadStarted() {
        guard window?.isKeyWindow == true, !downloadsPopover.isShown else { return }
        downloadsPopover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .minY)
    }

    @objc func printPage() {
        guard let window else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// ⌘T and the “+” in the tab bar.
    @objc func newTab() {
        openAsTab(BrowserWindowController(isPrivate: isPrivate))
    }

    @objc func duplicateTab() {
        let tab = BrowserWindowController(url: webView.url ?? Rook.startURL, isPrivate: isPrivate)
        openAsTab(tab)
    }

    override func newWindowForTab(_ sender: Any?) { newTab() }

    func openAsTab(_ tab: BrowserWindowController, inBackground: Bool = false) {
        guard let window, let newWindow = tab.window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        if inBackground {
            window.makeKeyAndOrderFront(nil)
        } else {
            newWindow.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Find on page (⌘F)

    @objc func showFindBar() {
        guard let window else { return }
        if findBar == nil {
            findField.placeholderString = "Auf Seite suchen"
            findField.delegate = self
            findField.target = self
            findField.action = #selector(findNext)
            findField.sendsWholeSearchString = false
            findStatus.textColor = .secondaryLabelColor
            findStatus.font = .systemFont(ofSize: 11)
            let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Vorheriger Treffer")!,
                                    target: self, action: #selector(findPrevious))
            let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Nächster Treffer")!,
                                target: self, action: #selector(findNext))
            let done = NSButton(title: "Fertig", target: self, action: #selector(hideFindBar))
            [previous, next].forEach { $0.bezelStyle = .texturedRounded }
            done.bezelStyle = .rounded
            let bar = NSStackView(views: [findField, findStatus, NSView(), previous, next, done])
            bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
            findField.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = bar
            accessory.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(accessory)
            findBar = accessory
        }
        findBar?.isHidden = false
        window.makeFirstResponder(findField)
    }

    @objc func hideFindBar() {
        findBar?.isHidden = true
        window?.makeFirstResponder(webView)
    }

    @objc func findNext() { find(backwards: false) }
    @objc func findPrevious() { find(backwards: true) }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === findField { find(backwards: false) }
    }

    private func find(backwards: Bool) {
        let text = findField.stringValue
        guard !text.isEmpty else { findStatus.stringValue = ""; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            self?.findStatus.stringValue = result.matchFound ? "" : "Nicht gefunden"
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !isPrivate, let url = webView.url, ["http", "https"].contains(url.scheme ?? "") {
            Self.closedTabs.append(url)
            if Self.closedTabs.count > 25 { Self.closedTabs.removeFirst() }
        }
        observations.removeAll()
        webView.stopLoading()
        BrowserWindowController.all.removeAll { $0 === self }
        if isPrivate, !BrowserWindowController.all.contains(where: { $0.isPrivate }) {
            Rook.discardPrivateSession()   // next private window starts without any cookies
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        switch Rook.linkKind(for: url) {
        case .blocked:
            decisionHandler(.cancel, preferences)
            return
        case .otherApp:
            decisionHandler(.cancel, preferences)
            // Only react to real clicks, and always ask first – a website must never start apps silently.
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true {
                askToOpenInOtherApp(url, from: action.sourceFrame.request.url?.host)
            }
            return
        case .startPage:
            // Websites may not embed Rook's own page; opening it in a tab is fine.
            if action.targetFrame?.isMainFrame == false { decisionHandler(.cancel, preferences); return }
        case .web:
            break
        }
        // ⌘-click opens the link in a new tab in the background, like Safari.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            openAsTab(BrowserWindowController(url: url, isPrivate: isPrivate), inBackground: true)
            decisionHandler(.cancel, preferences); return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences); return
        }
        decisionHandler(.allow, preferences)
    }

    private func askToOpenInOtherApp(_ url: URL, from host: String?) {
        guard let window else { return }
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        let appName = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        let alert = NSAlert()
        if let appName {
            alert.messageText = "„\(appName)“ öffnen?"
            alert.informativeText = "\(host ?? "Diese Website") möchte die App „\(appName)“ öffnen.\n\(url.scheme ?? ""):-Link"
            alert.addButton(withTitle: "Öffnen")
            alert.addButton(withTitle: "Abbrechen")
        } else {
            alert.messageText = "Keine passende App"
            alert.informativeText = "Für diesen Link (\(url.scheme ?? "")) ist keine App installiert."
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { response in
            if appName != nil, response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Files the browser cannot show (or that the server marks as attachment) become downloads.
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if response.isForMainFrame && disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
        closeIfOnlyUsedForDownload()
    }

    /// A tab that was opened only to download a file would stay empty – close it, like Safari.
    private func closeIfOnlyUsedForDownload() {
        guard webView.backForwardList.currentItem == nil, let window,
              (window.tabbedWindows?.count ?? 1) > 1 else { return }
        DispatchQueue.main.async { window.close() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.absoluteString != "about:blank" { failedURL = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateAddress()
        updateSecurity()
        if !isPrivate, let url = webView.url { History.shared.add(url: url, title: webView.title ?? "") }
        if isStartPage {
            // New tab: focus the page so its search field can be used right away.
            if window?.firstResponder != addressField.currentEditor() { window?.makeFirstResponder(webView) }
            // Take over the search engine chosen in Rook's settings for the address bar.
            webView.evaluateJavaScript("(JSON.parse(localStorage.getItem('rook.v1') || '{}').engine) || ''") { result, _ in
                if let engine = result as? String, !engine.isEmpty { Rook.engine = engine }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    /// A crashed website only takes down its own tab. Reload it, so the rest of Rook keeps running.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads and "frame load interrupted" (downloads) are not real errors.
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? ""
        let (headline, hint) = Self.explain(ns)
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(escape(headline))</title>
        <style>body{font:15px -apple-system,sans-serif;background:#1c1c1e;color:#f5f5f7;display:flex;
        align-items:center;justify-content:center;height:100vh;margin:0;text-align:center}
        h1{font-size:22px}p{color:#98989d;max-width:480px;line-height:1.5}code{color:#c7c7cc}</style>
        <div><h1>\(escape(headline))</h1><p>\(escape(hint))</p>
        <p><code>\(escape(failing))</code></p><p>\(escape(ns.localizedDescription))</p></div>
        """
        failedURL = URL(string: failing)
        webView.loadHTMLString(html, baseURL: nil)
        if !failing.isEmpty { addressField.stringValue = failing }
    }

    /// Plain-language explanation for the most common errors. Certificate errors are never bypassed.
    static func explain(_ error: NSError) -> (String, String) {
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return ("Keine Internetverbindung", "Prüfe dein WLAN und lade die Seite danach neu (⌘R).")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ("Seite nicht gefunden", "Diese Adresse gibt es nicht. Ist sie richtig geschrieben?")
        case NSURLErrorTimedOut:
            return ("Zeitüberschreitung", "Die Seite antwortet nicht. Versuche es später noch einmal.")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorSecureConnectionFailed:
            return ("Verbindung nicht sicher",
                    "Das Sicherheitszertifikat dieser Seite ist ungültig. Jemand könnte versuchen, deine Daten mitzulesen. Rook öffnet die Seite deshalb nicht.")
        default:
            return ("Seite nicht erreichbar", "Die Seite konnte nicht geladen werden.")
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: WKUIDelegate

    /// Links with target="_blank" and pop-ups (e.g. "Sign in with Google") open as a new tab.
    /// Pop-ups without a click are already blocked (javaScriptCanOpenWindowsAutomatically = false).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, Rook.linkKind(for: url) == .blocked { return nil }
        let tab = BrowserWindowController(configuration: configuration, url: nil, isPrivate: isPrivate)
        openAsTab(tab)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "Rook" : frame.securityOrigin.host
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "Rook" : frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let alert = NSAlert()
        alert.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// Camera and microphone: WebKit asks the user per website (origin), like Safari.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

/// The thin loading bar under the toolbar.
final class ProgressLine: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var isLoading = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard isLoading, progress < 1 else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * max(0.05, progress), height: bounds.height).fill()
    }
}
