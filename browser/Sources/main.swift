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
        NSWindow.allowsAutomaticWindowTabbing = false   // Rook has its own tab bar
        DownloadManager.shared.webViewProvider = {
            ((NSApp.keyWindow?.windowController as? BrowserWindowController) ?? BrowserWindowController.all.first)?.webView
        }
        HistoryWindowController.shared.open = { [weak self] url in self?.open(url) }
        launched = true

        restoreSession()
        pendingURLs.forEach { open($0) }
        pendingURLs.removeAll()
        if BrowserWindowController.all.isEmpty { openWindow() }

        // Save open tabs regularly, so they survive a crash or power loss too.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in Session.save() }
        sessionTimer?.tolerance = 5

        // An import that needed a restart for the permission continues now.
        TabGroupDialogs.resumeAfterRestart()

        // Already set up before tab groups existed: offer Safari's tab groups once now.
        if Settings.welcomeShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.offerSafariTabGroups() }
        }

        // After the start page's first setup, offer once to become the default browser.
        NotificationCenter.default.addObserver(forName: .rookOnboardingDone, object: nil, queue: .main) { [weak self] _ in
            guard !Settings.welcomeShown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.showWelcome() }
        }
    }

    /// First start: offer to make Rook the default browser and to import bookmarks.
    private func showWelcome() {
        Settings.welcomeShown = true
        guard let window = current?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rook Search als Standardbrowser?"
        alert.informativeText = "Links aus anderen Apps, zum Beispiel aus Mail, öffnen sich dann in Rook Search. Lesezeichen aus einem anderen Browser kannst du hier ebenfalls übernehmen."
        alert.addButton(withTitle: "Als Standardbrowser verwenden")
        alert.addButton(withTitle: "Lesezeichen importieren …")
        alert.addButton(withTitle: "Später")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: Settings.makeDefaultBrowser()
            case .alertSecondButtonReturn: DispatchQueue.main.async { self?.importBookmarks() }
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.offerSafariTabGroups() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = DownloadManager.shared.runningCount
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "Ein Download läuft noch" : "\(running) Downloads laufen noch"
        alert.informativeText = "Wenn du Rook Search jetzt beendest, werden sie abgebrochen."
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

    /// Opens an address as a new tab in the front (normal) window.
    private func open(_ url: URL) {
        // Links from other apps never end up in a private window.
        if let current, !current.isPrivate {
            current.openTab(url: url, configuration: nil, background: false)
            current.window?.makeKeyAndOrderFront(nil)
        } else {
            BrowserWindowController(urls: [url]).showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreSession() {
        guard Settings.restoreSession else { return }
        for group in Session.load().reversed() {
            BrowserWindowController(urls: group.urls, pinned: group.pinned, groupID: group.groupID).showWindow(nil)
        }
    }

    @objc func openWindow() { BrowserWindowController().showWindow(nil) }
    @objc func openPrivateWindow() { BrowserWindowController(isPrivate: true).showWindow(nil) }

    @objc func newTab() {
        if let current { current.newTab() } else { openWindow() }
    }

    @objc func reopenClosedTab() {
        guard let url = BrowserWindowController.closedTabs.popLast() else { NSSound.beep(); return }
        open(url)
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        current?.selectTab(number: sender.tag)
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let tab = current?.currentTab { tab.load(url) } else { open(url) }
    }

    @objc func showHistory() { HistoryWindowController.shared.show() }
    @objc func clearHistory() { Privacy.confirmClearHistory(in: NSApp.keyWindow) }
    @objc func clearWebsiteData() { Privacy.confirmClearWebsiteData(in: NSApp.keyWindow) }
    @objc func makeDefaultBrowser() { Settings.makeDefaultBrowser() }
    @objc func showSettings() {
        if let current { current.showSettings() } else { BrowserWindowController(urls: [URL(string: "rook://start/#settings")!]).showWindow(nil) }
    }

    /// Imports bookmarks from an HTML file (Safari: Ablage › Exportieren › Lesezeichen;
    /// Chrome: Lesezeichen-Manager › Lesezeichen exportieren).
    @objc func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.message = "Wähle eine Lesezeichen-Datei (HTML). In Safari: Ablage › Exportieren › Lesezeichen …"
        panel.prompt = "Importieren"
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = Favorites.importBookmarks(html: html)
        let alert = NSAlert()
        alert.messageText = count == 0 ? "Keine neuen Lesezeichen gefunden" : "\(count) Lesezeichen importiert"
        alert.informativeText = count == 0
            ? "Die Datei enthielt keine Webadressen, oder sie sind schon in deinen Favoriten."
            : "Sie erscheinen beim nächsten neuen Tab auf deiner Startseite. Die Startseite zeigt höchstens 60 Favoriten, Ordner werden nicht übernommen."
        alert.runModal()
        newTab()
    }

    @objc func importSafariTabGroups() {
        Settings.safariTabGroupsOffered = true
        TabGroupDialogs.importFromSafari()
    }

    /// macOS hands saved passwords only to Safari, so Rook Search opens Apple's Passwords app instead
    /// (on older systems its page in System Settings), where a password can be copied.
    @objc func openPasswords() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let settings = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            NSWorkspace.shared.open(settings)
        }
    }

    /// Once (also for people who already use Rook Search): if Safari has tab groups, offer to take them over.
    private func offerSafariTabGroups() {
        guard !Settings.safariTabGroupsOffered, SafariTabGroups.exist, let window = current?.window else { return }
        Settings.safariTabGroupsOffered = true
        let alert = NSAlert()
        alert.messageText = "Tab-Gruppen aus Safari übernehmen?"
        alert.informativeText = "Deine Tab-Gruppen aus Safari kannst du in Rook Search weiterverwenden. Dafür fragt macOS einmal nach Zugriff. Später geht das auch über den Knopf oben links."
        alert.addButton(withTitle: "Übernehmen …")
        alert.addButton(withTitle: "Nicht jetzt")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { TabGroupDialogs.importFromSafari() }
        }
    }

    // MARK: Protection menu (ad & tracker blocker)

    private var currentPageURL: URL? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.currentTab?.displayURL
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
        Rook Search blockiert Werbung und Tracker mit den Filterlisten \(blocker.sources.map(\.name).joined(separator: ", ")) von easylist.to. \
        Die Listen werden einmal pro Woche direkt von easylist.to geladen. Das ist die einzige Verbindung, die Rook Search selbst aufbaut. \
        Welche Seiten du besuchst, erfährt dabei niemand.

        Gut geblockt werden Werbebanner, Werbe-Pop-ups und die meisten Tracker.
        Nicht oder kaum möglich: Werbung in YouTube-Videos, Hinweise wie „Bitte Werbeblocker deaktivieren“ und gesponserte Beiträge, die wie normaler Inhalt aussehen.

        Funktioniert eine Seite nicht richtig, wähle im Menü Schutz „Auf … nicht blockieren“ (⌥⌘B).

        \(blocker.status)
        """
        alert.runModal()
    }

    private func reloadCurrentTab() {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.webView?.reload()
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
        item(menu, "Gesamten Verlauf anzeigen", #selector(showHistory), "y", target: self)
        item(menu, "Verlauf löschen …", #selector(clearHistory), "", target: self)
        item(menu, "Cookies und Website-Daten löschen …", #selector(clearWebsiteData), "", target: self)
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Rook Search")
        app.addItem(withTitle: "Über Rook Search", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, "Einstellungen …", #selector(showSettings), ",", target: self)
        item(app, "Rook Search als Standardbrowser festlegen …", #selector(makeDefaultBrowser), "", target: self)
        app.addItem(.separator())
        app.addItem(withTitle: "Rook Search ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Alle einblenden", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Rook Search beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "Ablage")
        item(file, "Neuer Tab", #selector(newTab), "t", target: self)
        item(file, "Neues Fenster", #selector(openWindow), "n", target: self)
        let priv = item(file, "Neues privates Fenster", #selector(openPrivateWindow), "n", target: self)
        priv.keyEquivalentModifierMask = [.command, .shift]
        item(file, "Adresse öffnen …", #selector(BrowserWindowController.focusAddress), "l")
        item(file, "Tab duplizieren", #selector(BrowserWindowController.duplicateTab), "")
        item(file, "Tab anheften / lösen", #selector(BrowserWindowController.togglePinCurrentTab), "")
        file.addItem(.separator())
        item(file, "Tab schließen", #selector(BrowserWindowController.closeCurrentTab), "w")
        let closeWindow = item(file, "Fenster schließen", #selector(NSWindow.performClose(_:)), "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        item(file, "Zu Favoriten hinzufügen", #selector(BrowserWindowController.addToFavorites), "d")
        item(file, "Lesezeichen importieren …", #selector(importBookmarks), "", target: self)
        item(file, "Tab-Gruppen aus Safari übernehmen …", #selector(importSafariTabGroups), "", target: self)
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
        let copyAddress = item(edit, "Adresse kopieren", #selector(BrowserWindowController.copyCurrentAddress), "c")
        copyAddress.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        let passwords = item(edit, "Passwörter …", #selector(openPasswords), "p", target: self)
        passwords.keyEquivalentModifierMask = [.command, .option]
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
        let sidebar = item(view, "Seitenleiste mit Tab-Gruppen", #selector(BrowserWindowController.toggleSidebar), "l")
        sidebar.keyEquivalentModifierMask = [.command, .shift]
        let favorites = item(view, "Favoritenleiste", #selector(BrowserWindowController.toggleFavoritesBar), "b")
        favorites.keyEquivalentModifierMask = [.command, .shift]
        let reader = item(view, "Leseansicht", #selector(BrowserWindowController.toggleReader), "r")
        reader.keyEquivalentModifierMask = [.command, .shift]
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
        let next = item(window, "Nächster Tab", #selector(BrowserWindowController.showNextTab), "\t")
        next.keyEquivalentModifierMask = [.control]
        let previous = item(window, "Vorheriger Tab", #selector(BrowserWindowController.showPreviousTab), "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        let next2 = item(window, "Nächster Tab", #selector(BrowserWindowController.showNextTab), "}")
        next2.isAlternate = false
        next2.isHidden = true
        next2.allowsKeyEquivalentWhenHidden = true
        let previous2 = item(window, "Vorheriger Tab", #selector(BrowserWindowController.showPreviousTab), "{")
        previous2.isHidden = true
        previous2.allowsKeyEquivalentWhenHidden = true
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
