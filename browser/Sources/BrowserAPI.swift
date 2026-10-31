import AppKit
import WebKit

/// The start page's settings talk to the browser through rook://start/api/… .
///
/// Safety: answers are only given to the start page itself. A request is accepted only when the
/// page that sends it was loaded from rook:// (mainDocumentURL), and websites cannot navigate a tab
/// to an /api/ address (blocked in BrowserTab's navigation policy). So no website can read the
/// history or trigger actions like "delete history".
enum BrowserAPI {
    static func isAllowed(_ request: URLRequest) -> Bool {
        request.mainDocumentURL?.scheme == "rook" && request.url?.scheme == "rook"
    }

    static func handle(_ url: URL, task: WKURLSchemeTask, webView: WKWebView) {
        guard isAllowed(task.request) else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        let reply: (Any) -> Void = { body in respond(task, url: url, body: body) }

        switch url.path {
        case "/api/native.json":
            reply([
                "engine": Rook.engine,
                "engineChangedAt": UserDefaults.standard.double(forKey: "engineChangedAt"),
                "pendingFavorites": isPrivate ? [] : Favorites.pending.map { ["name": $0.name, "url": $0.url] },
                "recent": isPrivate ? [] : History.shared.recent(8).map { ["title": $0.title, "url": $0.url.absoluteString] },
                "private": isPrivate
            ] as [String: Any])

        case "/api/favorites-taken":
            Favorites.pending = Array(Favorites.pending.dropFirst(Int(query["count"] ?? "") ?? 0))
            reply(["ok": true])

        case "/api/favorites-known":
            if let data = query["list"]?.data(using: .utf8), let list = try? JSONDecoder().decode([Favorites.Item].self, from: data) {
                Favorites.known = Array(list.prefix(200))
            }
            reply(["ok": true])

        case "/api/settings.json":
            reply(settings(isPrivate: isPrivate))

        case "/api/set":
            switch query["key"] {
            case "engine": Rook.engine = query["value"] ?? ""
            case "askWhereToSave": Settings.askWhereToSave = query["value"] == "true"
            case "restoreSession": Settings.restoreSession = query["value"] == "true"
            case "blocker": ContentBlocker.shared.isEnabled = query["value"] == "true"
            default: break
            }
            reply(settings(isPrivate: isPrivate))

        case "/api/choose-download-folder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Auswählen"
            panel.message = "Wohin sollen Downloads gespeichert werden?"
            panel.directoryURL = Settings.effectiveDownloadFolder
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let folder = panel.url { Settings.downloadFolder = folder }
                reply(settings(isPrivate: isPrivate))
            }
            if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }

        case "/api/reset-download-folder":
            Settings.downloadFolder = nil
            reply(settings(isPrivate: isPrivate))

        case "/api/show-download-folder":
            NSWorkspace.shared.open(Settings.effectiveDownloadFolder)
            reply(["ok": true])

        case "/api/blocker-update":
            ContentBlocker.shared.updateNow { reply(settings(isPrivate: isPrivate)) }

        case "/api/blocker-remove-exception":
            if let site = query["site"], ContentBlocker.shared.allowedSites.contains(site) {
                ContentBlocker.shared.toggleSite(of: URL(string: "https://\(site)/")) { reply(settings(isPrivate: isPrivate)) }
            } else {
                reply(settings(isPrivate: isPrivate))
            }

        case "/api/forget-site":
            if let site = query["site"] { Settings.forget(site: site) }
            reply(settings(isPrivate: isPrivate))

        case "/api/clear-history":
            reply(["ok": true])
            // Afterwards, because tabs (maybe this start page too) are reloaded without history.
            DispatchQueue.main.async { Privacy.clearHistoryCompletely() }

        case "/api/clear-website-data":
            Privacy.clearWebsiteData { reply(["ok": true]) }

        case "/api/make-default":
            Settings.makeDefaultBrowser { reply(settings(isPrivate: isPrivate)) }

        case "/api/import-bookmarks":
            NSApp.sendAction(Selector(("importBookmarks")), to: nil, from: nil)   // handled by the app delegate
            reply(["ok": true])

        default:
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    /// Everything the start page's settings show about the browser.
    static func settings(isPrivate: Bool) -> [String: Any] {
        let blocker = ContentBlocker.shared
        let sites = Settings.sitesWithSettings.map { site -> [String: Any] in
            func text(_ d: Settings.Decision?) -> String { d == .allow ? "allow" : d == .deny ? "deny" : "" }
            return ["site": site,
                    "camera": text(Settings.decision(.camera, for: site)),
                    "microphone": text(Settings.decision(.microphone, for: site)),
                    "zoom": Settings.zoom(for: site).map { Int(($0 * 100).rounded()) } ?? 0]
        }
        return [
            "app": true,
            "private": isPrivate,
            "engine": Rook.engine,
            "downloadFolder": Settings.effectiveDownloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            "downloadFolderIsDefault": Settings.downloadFolder == nil,
            "askWhereToSave": Settings.askWhereToSave,
            "restoreSession": Settings.restoreSession,
            "isDefaultBrowser": Settings.isDefaultBrowser,
            "blocker": ["enabled": blocker.isEnabled, "status": blocker.status, "exceptions": blocker.allowedSites.sorted()],
            "sites": sites,
            "historyCount": History.shared.entries.count
        ]
    }

    /// Tasks the web view gave up on (page closed or navigated away) must not be answered anymore.
    static var stoppedTasks = Set<ObjectIdentifier>()

    private static func respond(_ task: WKURLSchemeTask, url: URL, body: Any) {
        if stoppedTasks.remove(ObjectIdentifier(task as AnyObject)) != nil { return }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!)
        task.didReceive(data)
        task.didFinish()
    }
}
