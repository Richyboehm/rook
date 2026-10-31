import AppKit
import WebKit

/// Everything that is shared between all tabs: the WebKit configuration, the bundled start page,
/// search and downloads.
enum Rook {
    static let startURL = URL(string: "rook://start/")!

    /// One configuration for all normal tabs, so cookies and logins are shared (persistent data store).
    static let configuration = makeConfiguration(store: .default())

    /// Private windows: cookies, website storage and cache live only in memory and are gone when the
    /// last private window closes. Downloads and things the user saves on purpose remain on disk.
    static var privateConfiguration: WKWebViewConfiguration {
        if let config = _privateConfiguration { return config }
        let config = makeConfiguration(store: .nonPersistent())
        _privateConfiguration = config
        return config
    }
    private static var _privateConfiguration: WKWebViewConfiguration?

    /// Called when the last private window closed, so the next one starts empty.
    static func discardPrivateSession() { _privateConfiguration = nil }

    private static func makeConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.setURLSchemeHandler(StartPageHandler.shared, forURLScheme: "rook")
        config.preferences.isFraudulentWebsiteWarningEnabled = true   // Apple's Safe Browsing warning, like in Safari
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        // Present ourselves like Safari, so websites (e.g. Google sign-in) treat Rook like Safari.
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        ContentBlocker.shared.register(config.userContentController)   // ad & tracker blocking
        return config
    }

    static var safariVersion: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
           let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "18.0"
    }

    // MARK: Search

    static let engines: [String: String] = [
        "google": "https://www.google.com/search?q=",
        "duckduckgo": "https://duckduckgo.com/?q=",
        "startpage": "https://www.startpage.com/do/search?q=",
        "ecosia": "https://www.ecosia.org/search?q=",
        "bing": "https://www.bing.com/search?q=",
        "brave": "https://search.brave.com/search?q="
    ]

    /// The search engine chosen on the start page (synced from its settings).
    static var engine: String {
        get { UserDefaults.standard.string(forKey: "engine") ?? "google" }
        set { if engines[newValue] != nil { UserDefaults.standard.set(newValue, forKey: "engine") } }
    }

    /// Turns what was typed into the address bar into a URL: a web address or a search.
    static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "rook"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ") &&
            text.range(of: #"^[\w-]+(\.[\w-]+)+(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil
        if looksLikeHost || text.hasPrefix("localhost") {
            return URL(string: (text.hasPrefix("localhost") ? "http://" : "https://") + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?"))) ?? text
        return URL(string: (engines[engine] ?? engines["google"]!) + query)
    }

    // MARK: Link safety

    enum LinkKind: Equatable {
        case web            // shown inside Rook
        case startPage      // Rook's own start page
        case otherApp       // mailto:, tel:, zoommtg: … – only after the user agreed
        case blocked        // file:, javascript: and similar – never opened from a website
    }

    /// Decides how an address that a website wants to open is handled.
    static func linkKind(for url: URL) -> LinkKind {
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https", "about", "blob", "data": return .web
        case "rook": return .startPage
        case "file", "javascript", "vbscript", "": return .blocked
        default: return .otherApp
        }
    }

    /// Website data records that belong to Rook's own start page (kept when clearing website data).
    /// WebKit currently does not list the rook:// storage at all; this is an extra safeguard.
    static func isStartPageRecord(_ displayName: String) -> Bool {
        displayName.isEmpty || displayName == "start"
    }

    // MARK: Downloads

    /// A file name in `folder` that does not exist yet – existing files are never overwritten.
    static func uniqueDestination(in folder: URL, suggestedName: String,
                                  exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        // Only the last path part, no hidden files, no empty names.
        var name = (suggestedName as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Download" }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while exists(target) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return target
    }
}

/// Serves the Rook start page (bundled in the app) under rook://start/.
final class StartPageHandler: NSObject, WKURLSchemeHandler {
    static let shared = StartPageHandler()

    private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("start", isDirectory: true)
    private let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "svg": "image/svg+xml",
                         "jpg": "image/jpeg", "png": "image/png", "json": "application/json"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // Only files inside the bundled start page folder.
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

