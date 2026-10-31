import AppKit
import WebKit

/// All of Rook's own preferences (stored only on this Mac, in UserDefaults).
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var restoreSession: Bool {
        get { defaults.object(forKey: "restoreSession") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "restoreSession") }
    }

    /// nil = the normal Downloads folder.
    static var downloadFolder: URL? {
        get { defaults.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: "downloadFolder") }
    }

    static var effectiveDownloadFolder: URL {
        downloadFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static var askWhereToSave: Bool {
        get { defaults.bool(forKey: "askWhereToSave") }
        set { defaults.set(newValue, forKey: "askWhereToSave") }
    }

    static var welcomeShown: Bool {
        get { defaults.bool(forKey: "welcomeShown") }
        set { defaults.set(newValue, forKey: "welcomeShown") }
    }

    // MARK: Per website

    enum Permission: String { case camera, microphone }
    enum Decision: String { case allow, deny }

    /// The key for per-site settings: the host without "www.".
    static func site(_ url: URL?) -> String? { ContentBlocker.site(of: url) }

    static func decision(_ permission: Permission, for site: String) -> Decision? {
        let all = defaults.dictionary(forKey: "sitePermissions") as? [String: String] ?? [:]
        return all["\(site)|\(permission.rawValue)"].flatMap(Decision.init)
    }

    static func setDecision(_ decision: Decision?, _ permission: Permission, for site: String) {
        var all = defaults.dictionary(forKey: "sitePermissions") as? [String: String] ?? [:]
        all["\(site)|\(permission.rawValue)"] = decision?.rawValue
        defaults.set(all, forKey: "sitePermissions")
    }

    static func zoom(for site: String) -> Double? {
        (defaults.dictionary(forKey: "siteZoom") as? [String: Double])?[site]
    }

    static func setZoom(_ zoom: Double?, for site: String) {
        var all = defaults.dictionary(forKey: "siteZoom") as? [String: Double] ?? [:]
        all[site] = (zoom == nil || zoom == 1) ? nil : zoom
        defaults.set(all, forKey: "siteZoom")
    }

    /// Every site that has a stored permission or zoom level (for the "Websites" settings).
    static var sitesWithSettings: [String] {
        let permissions = (defaults.dictionary(forKey: "sitePermissions") as? [String: String] ?? [:]).keys
            .compactMap { $0.split(separator: "|").first.map(String.init) }
        let zooms = (defaults.dictionary(forKey: "siteZoom") as? [String: Double] ?? [:]).keys
        return Array(Set(permissions).union(zooms)).sorted()
    }

    static func forget(site: String) {
        setDecision(nil, .camera, for: site)
        setDecision(nil, .microphone, for: site)
        setZoom(nil, for: site)
    }

    // MARK: Default browser

    static var isDefaultBrowser: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeDefaultBrowser(done: @escaping () -> Void = {}) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                DispatchQueue.main.async(execute: done)
            }
        }
    }
}

/// Clearing data – used by the menu and the settings window.
enum Privacy {
    static func confirmClearHistory(in window: NSWindow?) {
        confirm("Verlauf restlos löschen?",
                "Alle besuchten Seiten, die Liste geschlossener Tabs, die Vorschläge in der Adressleiste und „Zuletzt besucht“ werden von diesem Mac entfernt. Cookies und Anmeldungen bleiben erhalten.",
                in: window) { clearHistoryCompletely() }
    }

    /// Everything Rook remembers about visited pages: history file, closed tabs, the back/forward
    /// lists of open tabs (by reloading them without history) and the saved session's history.
    static func clearHistoryCompletely() {
        History.shared.clear()
        BrowserWindowController.closedTabs.removeAll()
        for controller in BrowserWindowController.all where !controller.isPrivate {
            controller.forgetBackForwardHistory()
        }
        Session.save()
    }

    static func confirmClearWebsiteData(in window: NSWindow?) {
        confirm("Cookies und Website-Daten löschen?",
                "Du wirst auf allen Websites abgemeldet, und gespeicherte Website-Daten sowie der Cache werden gelöscht. Deine Rook-Startseite (Favoriten, Einstellungen) bleibt erhalten.",
                in: window) { clearWebsiteData {} }
    }

    static func clearWebsiteData(done: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let websites = records.filter { !Rook.isStartPageRecord($0.displayName) }
            store.removeData(ofTypes: types, for: websites) { done() }
        }
    }

    private static func confirm(_ title: String, _ text: String, in window: NSWindow?, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

