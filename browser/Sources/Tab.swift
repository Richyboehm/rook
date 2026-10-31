import AppKit
import WebKit

/// The window that shows tabs. A tab reports changes to it and asks it to open or close tabs.
protocol TabOwner: AnyObject {
    var window: NSWindow? { get }
    func tabChanged(_ tab: BrowserTab)
    func openTab(url: URL?, configuration: WKWebViewConfiguration?, background: Bool) -> BrowserTab
    func closeTab(_ tab: BrowserTab)
}

/// One tab: its web view and everything that happens inside it (navigation, pop-ups, dialogs,
/// downloads, permissions, error pages).
final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let isPrivate: Bool
    weak var owner: TabOwner?
    var isPinned = false
    private(set) var favicon: NSImage?
    /// The address that failed to load while an error page is shown (for the address bar and ⌘R).
    private(set) var failedURL: URL?
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration? = nil, url: URL? = Rook.startURL, isPrivate: Bool) {
        self.isPrivate = isPrivate
        let config = configuration ?? (isPrivate ? Rook.privateConfiguration : Rook.configuration)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        let notify: (WKWebView) -> Void = { [weak self] _ in
            guard let self else { return }
            self.owner?.tabChanged(self)
        }
        observations = [
            webView.observe(\.title) { [weak self] web, _ in
                notify(web)
                if let self, !self.isPrivate, let url = web.url { History.shared.updateTitle(url: url, title: web.title ?? "") }
            },
            webView.observe(\.url) { web, _ in notify(web) },
            webView.observe(\.hasOnlySecureContent) { web, _ in notify(web) },
            webView.observe(\.canGoBack) { web, _ in notify(web) },
            webView.observe(\.canGoForward) { web, _ in notify(web) },
            webView.observe(\.isLoading) { web, _ in notify(web) },
            webView.observe(\.estimatedProgress) { web, _ in notify(web) },
            webView.observe(\.cameraCaptureState) { web, _ in notify(web) },
            webView.observe(\.microphoneCaptureState) { web, _ in notify(web) }
        ]
        if let url { load(url) }
    }

    func close() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: State

    var isStartPage: Bool { webView.url?.scheme == "rook" || (webView.url == nil && failedURL == nil) }

    var title: String {
        let t = webView.title ?? ""
        if !t.isEmpty { return t }
        if isStartPage { return "Neuer Tab" }
        return webView.url?.host ?? failedURL?.host ?? "Lädt …"
    }

    var isUsingCameraOrMicrophone: Bool {
        webView.cameraCaptureState == .active || webView.microphoneCaptureState == .active
    }

    /// The address shown in the address bar (the failed one on error pages).
    var displayURL: URL? {
        if let failedURL, webView.url?.absoluteString == "about:blank" { return failedURL }
        return isStartPage ? nil : webView.url
    }

    /// What is saved for "restore tabs after restart".
    var sessionURL: String? {
        guard let url = displayURL ?? (isStartPage ? Rook.startURL : nil) else { return nil }
        switch Rook.linkKind(for: url) {
        case .web where ["http", "https"].contains(url.scheme?.lowercased() ?? ""): return url.absoluteString
        case .startPage: return Rook.startURL.absoluteString
        default: return nil
        }
    }

    // MARK: Actions

    func load(_ url: URL) {
        failedURL = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        if webView.isLoading { webView.stopLoading() }
        else if let failedURL { load(failedURL) }      // on an error page: try the real address again
        else { webView.reload() }
    }

    func setZoom(_ zoom: Double) {
        webView.pageZoom = (zoom * 10).rounded() / 10
        if !isPrivate, let site = Settings.site(webView.url) { Settings.setZoom(webView.pageZoom, for: site) }
    }

    // MARK: Favicon

    private static var faviconCache: [String: NSImage] = [:]

    private func loadFavicon() {
        guard let url = webView.url, let host = url.host, ["http", "https"].contains(url.scheme ?? "") else {
            favicon = nil; return
        }
        if let cached = Self.faviconCache[host] { favicon = cached; owner?.tabChanged(self); return }
        let js = "(document.querySelector('link[rel~=\"icon\"][sizes=\"32x32\"]') || document.querySelector('link[rel~=\"icon\"]') || {}).href || ''"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let href = (result as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                ?? URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL
            guard let iconURL = href, ["http", "https"].contains(iconURL.scheme ?? "") else { return }
            let session = URLSession(configuration: .ephemeral)
            session.dataTask(with: iconURL) { data, _, _ in
                guard let data, data.count < 500_000, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    Self.faviconCache[host] = image
                    self.favicon = image
                    self.owner?.tabChanged(self)
                }
            }.resume()
            session.finishTasksAndInvalidate()
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
            // Always ask first – a website must never start apps silently.
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true {
                askToOpenInOtherApp(url, from: action.sourceFrame.request.url?.host)
            }
            return
        case .startPage:
            // Websites may not embed Rook's own page; opening it in a tab is fine.
            // The settings interface (/api/) can never be opened as a page – only the start page uses it.
            if action.targetFrame?.isMainFrame == false || url.path.hasPrefix("/api/") {
                decisionHandler(.cancel, preferences); return
            }
        case .web:
            break
        }
        // ⌘-click opens the link in a new tab in the background, like Safari.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            _ = owner?.openTab(url: url, configuration: nil, background: !action.modifierFlags.contains(.shift))
            decisionHandler(.cancel, preferences); return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences); return
        }
        decisionHandler(.allow, preferences)
    }

    private func askToOpenInOtherApp(_ url: URL, from host: String?) {
        guard let window = owner?.window else { return }
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
        // A tab that was opened only to download a file would stay empty – close it, like Safari.
        if webView.backForwardList.currentItem == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.owner?.closeTab(self)
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.absoluteString != "about:blank" { failedURL = nil }
        // Remembered zoom level of this website.
        webView.pageZoom = (isPrivate ? nil : Settings.site(webView.url).flatMap(Settings.zoom(for:))) ?? 1
        favicon = nil
        owner?.tabChanged(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isPrivate, let url = webView.url { History.shared.add(url: url, title: webView.title ?? "") }
        loadFavicon()
        if webView.url?.scheme == "rook" {
            // Take over the search engine chosen in Rook's start page settings for the address bar.
            webView.evaluateJavaScript("(JSON.parse(localStorage.getItem('rook.v1') || '{}').engine) || ''") { result, _ in
                if let engine = result as? String, !engine.isEmpty { Rook.engine = engine }
            }
        }
        owner?.tabChanged(self)
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
        owner?.tabChanged(self)
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
        return owner?.openTab(url: nil, configuration: configuration, background: false).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.closeTab(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = owner?.window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "Rook" : frame.securityOrigin.host
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = owner?.window else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "Rook" : frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window = owner?.window else { completionHandler(nil); return }
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
        guard let window = owner?.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// Camera and microphone: Rook asks per website (bound to the requesting origin's host) and can
    /// remember the answer. Remembered answers are listed – and can be withdrawn – in Settings › Websites.
    /// Private windows always ask and never remember.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let site = origin.host.hasPrefix("www.") ? String(origin.host.dropFirst(4)) : origin.host
        let wanted: [Settings.Permission]
        switch type {
        case .camera: wanted = [.camera]
        case .microphone: wanted = [.microphone]
        default: wanted = [.camera, .microphone]
        }
        if !isPrivate {
            let stored = wanted.map { Settings.decision($0, for: site) }
            if stored.allSatisfy({ $0 == .allow }) { decisionHandler(.grant); return }
            if stored.contains(.deny) { decisionHandler(.deny); return }
        }
        guard let window = owner?.window else { decisionHandler(.deny); return }
        let what = wanted.count == 2 ? "Kamera und Mikrofon" : (wanted[0] == .camera ? "Kamera" : "Mikrofon")
        let alert = NSAlert()
        alert.messageText = "„\(site)“ möchte deine \(what) verwenden"
        alert.informativeText = "Erlaube das nur Websites, denen du vertraust, zum Beispiel für Videoanrufe."
        alert.addButton(withTitle: "Erlauben")
        alert.addButton(withTitle: "Nicht erlauben")
        let remember = NSButton(checkboxWithTitle: "Für diese Website merken", target: nil, action: nil)
        remember.state = isPrivate ? .off : .on
        remember.isEnabled = !isPrivate
        alert.accessoryView = remember
        alert.beginSheetModal(for: window) { [isPrivate] response in
            let allow = response == .alertFirstButtonReturn
            if !isPrivate, remember.state == .on {
                wanted.forEach { Settings.setDecision(allow ? .allow : .deny, $0, for: site) }
            }
            decisionHandler(allow ? .grant : .deny)
        }
    }
}
