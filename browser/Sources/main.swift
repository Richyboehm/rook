import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var pendingURLs: [URL] = []
    private var launched = false
    private let historyMenu = NSMenu(title: "Verlauf")
    private let protectionMenu = NSMenu(title: "Schutz")
    private var sessionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        ContentBlocker.shared.start()
        NSWindow.allowsAutomaticWindowTabbing = true
        DownloadManager.shared.webViewProvider = {
            ((NSApp.keyWindow?.windowController as? BrowserWindowController) ?? BrowserWindowController.all.first)?.webView
        }
        launched = true

        restoreSession()
        pendingURLs.forEach { open($0) }
        pendingURLs.removeAll()
        if BrowserWindowController.all.isEmpty { openWindow() }

        // Save open tabs regularly, so they survive a crash or power loss too.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in Session.save() }
        sessionTimer?.tolerance = 5
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = DownloadManager.shared.runningCount
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "Ein Download läuft noch" : "\(running) Downloads laufen noch"
        alert.informativeText = "Wenn du Rook jetzt beendest, werden sie abgebrochen."
        alert.addButton(withTitle: "Weiter laden")
        alert.addButton(withTitle: "Trotzdem beenden")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Session.save()
        History.shared.save()
    }

    /// Links from other apps (when Rook is the default browser) open as a new tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        urls.forEach { open($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private var current: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? BrowserWindowController.all.last { !$0.isPrivate }
    }

    private func open(_ url: URL) {
        // Links from other apps never end up in a private window.
        if let current, !current.isPrivate {
            current.openAsTab(BrowserWindowController(url: url))
        } else {
            BrowserWindowController(url: url).showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreSession() {
        for group in Session.load() {
            let first = BrowserWindowController(url: group[0])
            first.window?.tabbingMode = .disallowed
            first.showWindow(nil)
            first.window?.tabbingMode = .preferred
            for url in group.dropFirst() {
                first.openAsTab(BrowserWindowController(url: url), inBackground: true)
            }
        }
    }

    @objc func openWindow() {
        show(BrowserWindowController())
    }

    @objc func openPrivateWindow() {
        show(BrowserWindowController(isPrivate: true))
    }

    private func show(_ controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        window.tabbingMode = .disallowed      // a real new window …
        controller.showWindow(nil)
        window.tabbingMode = .preferred       // … but later tabs may join it
    }

    @objc func newTab() {
        if let current { current.newTab() } else { openWindow() }
    }

    @objc func reopenClosedTab() {
        guard let url = BrowserWindowController.closedTabs.popLast() else { NSSound.beep(); return }
        let tab = BrowserWindowController(url: url)
        if let current, !current.isPrivate { current.openAsTab(tab) } else { show(tab) }
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow else { return }
        let tabs = window.tabbedWindows ?? [window]
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1   // ⌘9 = last tab, like Safari
        if tabs.indices.contains(index) { tabs[index].makeKeyAndOrderFront(nil) }
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let current { current.load(url) } else { open(url) }
    }

    @objc func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Verlauf löschen?"
        alert.informativeText = "Alle besuchten Seiten und die Liste geschlossener Tabs werden von diesem Mac entfernt. Cookies und Anmeldungen bleiben erhalten."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        History.shared.clear()
        BrowserWindowController.closedTabs.removeAll()
    }

    @objc func clearWebsiteData() {
        let alert = NSAlert()
        alert.messageText = "Cookies und Website-Daten löschen?"
        alert.informativeText = "Du wirst auf allen Websites abgemeldet, und gespeicherte Website-Daten sowie der Cache werden gelöscht. Deine Rook-Startseite (Favoriten, Einstellungen) bleibt erhalten."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            // The start page lives under rook:// – keep it.
            let websites = records.filter { !Rook.isStartPageRecord($0.displayName) }
            store.removeData(ofTypes: types, for: websites) {}
        }
    }

    @objc func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
        }
    }

    // MARK: Protection menu (ad & tracker blocker)

    private var currentPageURL: URL? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.webView.url
    }

    private func updateProtectionMenu() {
        let menu = protectionMenu
        menu.removeAllItems()
        let blocker = ContentBlocker.shared
        menu.addItem(withTitle: blocker.status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let toggle = item(menu, "Werbung und Tracker blockieren", #selector(toggleBlocker), "", target: self)
        toggle.state = blocker.isEnabled ? .on : .off
        // Always the same action, so ⌥⌘B also works before the menu was ever opened.
        let site = ContentBlocker.site(of: currentPageURL)
        let allow = item(menu, site.map { "Auf \($0) nicht blockieren" } ?? "Auf dieser Website nicht blockieren",
                         #selector(toggleSiteBlocking), "b", target: self)
        allow.keyEquivalentModifierMask = [.command, .option]
        allow.state = blocker.isAllowed(currentPageURL) ? .on : .off
        menu.addItem(.separator())
        item(menu, "Filterlisten jetzt aktualisieren", #selector(updateFilterLists), "", target: self)
        item(menu, "Über den Werbeblocker …", #selector(aboutBlocker), "", target: self)
    }

    @objc func toggleBlocker() {
        ContentBlocker.shared.isEnabled.toggle()
        reloadCurrentTab()
    }

    @objc func toggleSiteBlocking() {
        let url = currentPageURL
        guard ContentBlocker.shared.isEnabled, ContentBlocker.site(of: url) != nil else { NSSound.beep(); return }
        ContentBlocker.shared.toggleSite(of: url) { [weak self] in self?.reloadCurrentTab() }
    }

    @objc func updateFilterLists() {
        ContentBlocker.shared.updateNow { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Filterlisten"
            alert.informativeText = ContentBlocker.shared.status
            alert.runModal()
            self?.reloadCurrentTab()
        }
    }

    @objc func aboutBlocker() {
        let blocker = ContentBlocker.shared
        let alert = NSAlert()
        alert.messageText = "Werbe- und Trackingschutz"
        alert.informativeText = """
        Rook blockiert Werbung und Tracker mit den Filterlisten \(blocker.sources.map(\.name).joined(separator: ", ")) von easylist.to. \
        Die Listen werden einmal pro Woche direkt von easylist.to geladen – das ist die einzige Verbindung, die Rook selbst aufbaut. \
        Welche Seiten du besuchst, erfährt dabei niemand.

        Gut geblockt werden Werbebanner, Werbe-Pop-ups und die meisten Tracker.
        Nicht oder kaum möglich: Werbung in YouTube-Videos, Hinweise wie „Bitte Werbeblocker deaktivieren“ und gesponserte Beiträge, die wie normaler Inhalt aussehen.

        Funktioniert eine Seite nicht richtig, wähle im Menü Schutz „Auf … nicht blockieren“ (⌥⌘B).

        \(blocker.status)
        """
        alert.runModal()
    }

    private func reloadCurrentTab() {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.webView.reload()
    }

    // MARK: History menu (filled when opened)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === protectionMenu { updateProtectionMenu(); return }
        guard menu === historyMenu else { return }
        menu.removeAllItems()
        item(menu, "Zurück", #selector(BrowserWindowController.goBack), "[")
        item(menu, "Vorwärts", #selector(BrowserWindowController.goForward), "]")
        let home = item(menu, "Startseite", #selector(BrowserWindowController.goHome), "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        let reopen = item(menu, "Geschlossenen Tab wieder öffnen", #selector(reopenClosedTab), "t", target: self)
        reopen.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        let recent = History.shared.recent(15)
        if recent.isEmpty {
            menu.addItem(withTitle: "Noch kein Verlauf", action: nil, keyEquivalent: "").isEnabled = false
        }
        for entry in recent {
            let title = entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title
            let item = menu.addItem(withTitle: String(title.prefix(60)), action: #selector(openHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            item.toolTip = entry.url.absoluteString
        }
        menu.addItem(.separator())
        item(menu, "Verlauf löschen …", #selector(clearHistory), "", target: self)
        item(menu, "Cookies und Website-Daten löschen …", #selector(clearWebsiteData), "", target: self)
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Rook")
        app.addItem(withTitle: "Über Rook", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, "Rook als Standardbrowser festlegen …", #selector(makeDefaultBrowser), "", target: self)
        app.addItem(.separator())
        app.addItem(withTitle: "Rook ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Alle einblenden", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Rook beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "Ablage")
        item(file, "Neuer Tab", #selector(newTab), "t", target: self)
        item(file, "Neues Fenster", #selector(openWindow), "n", target: self)
        let priv = item(file, "Neues privates Fenster", #selector(openPrivateWindow), "n", target: self)
        priv.keyEquivalentModifierMask = [.command, .shift]
        item(file, "Adresse öffnen …", #selector(BrowserWindowController.focusAddress), "l")
        item(file, "Tab duplizieren", #selector(BrowserWindowController.duplicateTab), "")
        file.addItem(.separator())
        item(file, "Tab schließen", #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        item(file, "Drucken …", #selector(BrowserWindowController.printPage), "p")

        let edit = submenu(main, "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        item(edit, "Auf Seite suchen …", #selector(BrowserWindowController.showFindBar), "f")
        item(edit, "Weitersuchen", #selector(BrowserWindowController.findNext), "g")
        let back = item(edit, "Rückwärts suchen", #selector(BrowserWindowController.findPrevious), "g")
        back.keyEquivalentModifierMask = [.command, .shift]

        let view = submenu(main, "Darstellung")
        item(view, "Neu laden", #selector(BrowserWindowController.reloadPage), "r")
        let hard = item(view, "Neu laden ohne Cache", #selector(BrowserWindowController.reloadFromOrigin), "r")
        hard.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        item(view, "Vergrößern", #selector(BrowserWindowController.zoomIn), "+")
        item(view, "Verkleinern", #selector(BrowserWindowController.zoomOut), "-")
        item(view, "Originalgröße", #selector(BrowserWindowController.actualSize), "0")
        view.addItem(.separator())
        let downloads = item(view, "Downloads", #selector(BrowserWindowController.showDownloads), "l")
        downloads.keyEquivalentModifierMask = [.command, .option]
        let fullscreen = view.addItem(withTitle: "Vollbild", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]

        main.addItem(withTitle: "Verlauf", action: nil, keyEquivalent: "").submenu = historyMenu
        historyMenu.delegate = self
        menuNeedsUpdate(historyMenu)

        main.addItem(withTitle: "Schutz", action: nil, keyEquivalent: "").submenu = protectionMenu
        protectionMenu.delegate = self
        updateProtectionMenu()

        let window = submenu(main, "Fenster")
        window.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoomen", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let next = window.addItem(withTitle: "Nächster Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
        next.keyEquivalentModifierMask = [.control]
        let previous = window.addItem(withTitle: "Vorheriger Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        for n in 1...9 {
            let tab = item(window, n == 9 ? "Letzter Tab" : "Tab \(n)", #selector(selectTab(_:)), "\(n)", target: self)
            tab.tag = n
        }
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
