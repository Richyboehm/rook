import AppKit
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let rookDownloadStarted = Notification.Name("RookDownloadStarted")
    /// Sent twice a second while downloads run (for the progress ring on the toolbar button).
    static let rookDownloadsChanged = Notification.Name("RookDownloadsChanged")
}

/// One download with its progress.
final class DownloadItem {
    enum State { case running, paused, finished, failed, cancelled }

    var download: WKDownload
    let source: URL?
    var file: URL?
    var name: String
    var state: State = .running
    var resumeData: Data?

    init(download: WKDownload, name: String) {
        self.download = download
        self.source = download.originalRequest?.url
        self.name = name
    }

    var progress: Progress { download.progress }
}

/// Saves downloads to the Downloads folder and keeps the list for the download bar.
/// Thanks to LSFileQuarantineEnabled in Info.plist, macOS marks downloaded files as
/// "from the internet", so Gatekeeper checks them before opening – like in Safari.
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []

    /// A web view that can restart or resume downloads (any open tab will do).
    var webViewProvider: () -> WKWebView? = { nil }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // A resumed download already has its file and list entry.
        if let existing = item(for: download), let file = existing.file {
            completionHandler(file)
            return
        }
        let folder = Settings.effectiveDownloadFolder
        let target = Rook.uniqueDestination(in: folder, suggestedName: suggestedFilename)
        guard Settings.askWhereToSave else {
            guard FileManager.default.isWritableFile(atPath: folder.path) else {
                completionHandler(nil)   // cancels; no permission to write into the folder
                return
            }
            start(download, at: target, completionHandler: completionHandler)
            return
        }
        // Ask like Safari: the save panel slides out of the window as a sheet. WebKit waits for the
        // answer, so nothing blocks while the panel is open (no nested modal loop inside WebKit's call).
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = target.lastPathComponent
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let chosen = panel.url, let self else { completionHandler(nil); return }
            // NSSavePanel already asked before replacing an existing file.
            try? FileManager.default.removeItem(at: chosen)
            self.start(download, at: chosen, completionHandler: completionHandler)
        }
        if let window = download.webView?.window, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func start(_ download: WKDownload, at target: URL, completionHandler: @escaping (URL?) -> Void) {
        let item = DownloadItem(download: download, name: target.lastPathComponent)
        item.file = target
        items.insert(item, at: 0)
        completionHandler(target)
        startTicking()
        // Announced a moment later, when the save panel is gone and the window is calm again.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .rookDownloadStarted, object: item)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.resumeData = nil
        if let file = item.file {
            markAsDownloaded(file, from: item.source)
            // Lets the Downloads stack in the Dock bounce, like Safari does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.resumeData = resumeData
        if item.state == .paused || item.state == .cancelled { return }
        item.state = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed
    }

    /// Gatekeeper only checks files that carry the "downloaded from the internet" mark (quarantine).
    /// macOS normally adds it because of LSFileQuarantineEnabled; this makes sure it is really there.
    private func markAsDownloaded(_ file: URL, from source: URL?) {
        var url = file
        if let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]), values.quarantineProperties != nil { return }
        var properties: [String: Any] = [kLSQuarantineAgentNameKey as String: "Rook",
                                         kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try? url.setResourceValues(values)
    }

    func cancel(_ item: DownloadItem) {
        item.state = .cancelled
        item.download.cancel { _ in }
        if let file = item.file { try? FileManager.default.removeItem(at: file) }   // no half files left behind
    }

    func pause(_ item: DownloadItem) {
        item.state = .paused
        item.download.cancel { data in item.resumeData = data }
    }

    /// Continues a paused or failed download – from where it stopped if the server allows it,
    /// otherwise from the beginning.
    func resume(_ item: DownloadItem) {
        guard let webView = webViewProvider() else { return }
        item.state = .running
        if let data = item.resumeData {
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                download.delegate = self
                item.download = download
            }
        } else if let source = item.source {
            if let file = item.file { try? FileManager.default.removeItem(at: file) }
            webView.startDownload(using: URLRequest(url: source)) { [weak self] download in
                download.delegate = self
                item.download = download
            }
        }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    var hasRunning: Bool { items.contains { $0.state == .running } }

    /// Asked before quitting: running downloads would be lost.
    var runningCount: Int { items.filter { $0.state == .running }.count }

    /// Combined progress of all running downloads, nil if none is running.
    var overallProgress: Double? {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return nil }
        let total = running.reduce(Int64(0)) { $0 + max(0, $1.progress.totalUnitCount) }
        let done = running.reduce(Int64(0)) { $0 + max(0, $1.progress.completedUnitCount) }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    private var ticker: Timer?

    /// Keeps the progress ring up to date while something downloads, then stops (no idle work).
    func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            NotificationCenter.default.post(name: .rookDownloadsChanged, object: nil)
            if self?.hasRunning != true { timer.invalidate(); self?.ticker = nil }
        }
    }
}

/// The download bar: a popover under the toolbar button, like in Safari.
final class DownloadsViewController: NSViewController {
    private let stack = NSStackView()
    private var timer: Timer?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))

        let title = NSTextField(labelWithString: "Downloads")
        title.font = .boldSystemFont(ofSize: 13)
        let clear = NSButton(title: "Liste leeren", target: self, action: #selector(clearList))
        clear.bezelStyle = .inline
        let header = NSStackView(views: [title, NSView(), clear])
        header.orientation = .horizontal

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = clip

        let outer = NSStackView(views: [header, scroll])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(equalToConstant: 260),
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.rebuild() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    @objc private func clearList() {
        DownloadManager.shared.clearFinished()
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = DownloadManager.shared.items
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "Noch keine Downloads")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        items.forEach { stack.addArrangedSubview(row(for: $0)) }
    }

    private func row(for item: DownloadItem) -> NSView {
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: .init(filenameExtension: (item.name as NSString).pathExtension) ?? .data))
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let name = NSTextField(labelWithString: item.name)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12, weight: .medium)

        let status = NSTextField(labelWithString: statusText(for: item))
        status.font = .systemFont(ofSize: 11)
        status.textColor = item.state == .failed ? .systemRed : .secondaryLabelColor

        let texts = NSStackView(views: [name, status])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if item.state == .running {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.controlSize = .small
            bar.isIndeterminate = item.progress.totalUnitCount <= 0
            bar.doubleValue = item.progress.fractionCompleted * 100
            if bar.isIndeterminate { bar.startAnimation(nil) }
            bar.widthAnchor.constraint(equalToConstant: 230).isActive = true
            texts.insertArrangedSubview(bar, at: 1)
        }

        let index = DownloadManager.shared.items.firstIndex { $0 === item } ?? -1
        var buttons: [NSButton] = []
        switch item.state {
        case .running:
            buttons = [button("pause.circle.fill", "Pausieren", #selector(pause(_:)), index),
                       button("xmark.circle.fill", "Abbrechen", #selector(cancel(_:)), index)]
        case .paused, .failed:
            buttons = [button("arrow.clockwise.circle.fill", item.state == .paused ? "Fortsetzen" : "Erneut versuchen",
                              #selector(resume(_:)), index),
                       button("xmark.circle.fill", "Abbrechen", #selector(cancel(_:)), index)]
        case .finished:
            buttons = [button("magnifyingglass.circle.fill", "Im Finder zeigen", #selector(reveal(_:)), index)]
        case .cancelled:
            break
        }

        let row = NSStackView(views: [icon, texts, NSView()] + buttons)
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 350).isActive = true
        return row
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector, _ index: Int) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.tag = index
        return b
    }

    private func statusText(for item: DownloadItem) -> String {
        let f = ByteCountFormatter()
        switch item.state {
        case .finished:
            let size = (try? item.file?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            return "Fertig · " + f.string(fromByteCount: Int64(size))
        case .failed: return "Fehlgeschlagen, Verbindung unterbrochen"
        case .cancelled: return "Abgebrochen"
        case .paused: return "Pausiert · " + f.string(fromByteCount: item.progress.completedUnitCount)
        case .running:
            let done = f.string(fromByteCount: item.progress.completedUnitCount)
            return item.progress.totalUnitCount > 0
                ? "\(done) von \(f.string(fromByteCount: item.progress.totalUnitCount))"
                : done
        }
    }

    private func item(at index: Int) -> DownloadItem? {
        let items = DownloadManager.shared.items
        return items.indices.contains(index) ? items[index] : nil
    }

    @objc private func cancel(_ sender: NSButton) {
        if let item = item(at: sender.tag) { DownloadManager.shared.cancel(item) }
        rebuild()
    }

    @objc private func pause(_ sender: NSButton) {
        if let item = item(at: sender.tag) { DownloadManager.shared.pause(item) }
        rebuild()
    }

    @objc private func resume(_ sender: NSButton) {
        if let item = item(at: sender.tag) { DownloadManager.shared.resume(item) }
        rebuild()
    }

    /// Only shows the file in the Finder – Rook never opens or runs downloads by itself.
    @objc private func reveal(_ sender: NSButton) {
        if let file = item(at: sender.tag)?.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}

/// Lets the download list grow from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
