import AppKit
import WebKit

/// Rook's ad and tracker blocker, built on WebKit's own content blocker (like Safari content blockers).
///
/// - The filter lists are downloaded from easylist.to (not bundled, because of their share-alike licence)
///   and refreshed once a week. These downloads are the only connections Rook itself makes.
/// - The lists are converted (FilterConverter) and compiled by WebKit, which then blocks requests and
///   hides ad elements before a page is shown. Rook never sees which pages are visited for this.
/// - Compiled lists are kept by WebKit, so the blocker is active right after the next start, offline too.
final class ContentBlocker {
    static let shared = ContentBlocker()

    struct Source {
        let id: String
        let name: String
        let url: URL
    }

    let sources = [
        Source(id: "easylist", name: "EasyList (Werbung)", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        Source(id: "easyprivacy", name: "EasyPrivacy (Tracker)", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        Source(id: "easylistgermany", name: "EasyList Germany", url: URL(string: "https://easylist.to/easylistgermany/easylistgermany.txt")!)
    ]

    private let store = WKContentRuleListStore.default()!
    private var lists: [String: WKContentRuleList] = [:]
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var working = false
    private(set) var ruleCount = 0
    private(set) var problem: String?

    private let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rook/filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "blockerEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "blockerEnabled"); applyAll() }
    }

    /// Sites (host names without "www.") where the user switched blocking off.
    var allowedSites: [String] {
        get { UserDefaults.standard.stringArray(forKey: "blockerAllowedSites") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "blockerAllowedSites") }
    }

    static func site(of url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), url?.scheme?.hasPrefix("http") == true else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func isAllowed(_ url: URL?) -> Bool {
        guard let site = Self.site(of: url) else { return false }
        return allowedSites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// Switches blocking off or on again for one site. Takes a few seconds (lists are recompiled).
    func toggleSite(of url: URL?, done: @escaping () -> Void) {
        guard let site = Self.site(of: url) else { return }
        var sites = allowedSites
        if let i = sites.firstIndex(where: { site == $0 || site.hasSuffix("." + $0) }) { sites.remove(at: i) } else { sites.append(site) }
        allowedSites = sites
        rebuild(download: false, done: done)
    }

    var lastUpdate: Date? { UserDefaults.standard.object(forKey: "blockerLastUpdate") as? Date }

    /// Short status for the menu.
    var status: String {
        if !isEnabled { return "Werbeblocker aus" }
        if let problem { return problem }
        if lists.isEmpty { return working ? "Filterlisten werden geladen …" : "Noch keine Filterlisten" }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "de_DE")
        let date = lastUpdate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "–"
        return "Aktiv · \(f.string(from: NSNumber(value: ruleCount)) ?? "\(ruleCount)") Regeln · Stand \(date)"
    }

    // MARK: Start

    /// Every web view configuration registers here, so the lists apply to all tabs (also private ones).
    func register(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    func start() {
        // 1. Use the lists compiled last time – the blocker works immediately, also offline.
        let group = DispatchGroup()
        let upToDate = UserDefaults.standard.integer(forKey: "blockerConverterVersion") == FilterConverter.version
        if upToDate {
            for source in sources {
                group.enter()
                store.lookUpContentRuleList(forIdentifier: identifier(source)) { [weak self] list, _ in
                    if let list { self?.lists[source.id] = list }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.ruleCount = UserDefaults.standard.integer(forKey: "blockerRuleCount")
            self.applyAll()
            // 2. Refresh in the background if older than a week (or never loaded / converter changed).
            let old = self.lastUpdate.map { Date().timeIntervalSince($0) > 7 * 24 * 3600 } ?? true
            if self.lists.isEmpty || old || !upToDate { self.rebuild(download: old || self.lists.isEmpty, done: {}) }
        }
    }

    func updateNow(done: @escaping () -> Void = {}) {
        rebuild(download: true, done: done)
    }

    // MARK: Building

    private func identifier(_ source: Source) -> String { "rook-\(source.id)" }
    private func file(_ source: Source) -> URL { folder.appendingPathComponent("\(source.id).txt") }

    /// Downloads (optional), converts and compiles all lists, then swaps them in.
    private func rebuild(download: Bool, done: @escaping () -> Void) {
        guard !working else { done(); return }
        working = true
        problem = nil
        let allowed = allowedSites
        DispatchQueue.global(qos: .utility).async { [self] in
            var downloadFailed = false
            if download {
                for source in sources where !self.download(source) { downloadFailed = true }
            }
            // Convert every list that is available on disk.
            var converted: [(Source, String, Int)] = []
            for source in sources {
                guard let text = try? String(contentsOf: file(source), encoding: .utf8) else { continue }
                let result = FilterConverter.convert(text, allowedSites: allowed)
                converted.append((source, FilterConverter.json(result.rules), result.blocking + result.hiding))
            }
            DispatchQueue.main.async {
                if converted.isEmpty {
                    self.working = false
                    self.problem = downloadFailed ? "Filterlisten konnten nicht geladen werden – keine Internetverbindung?" : nil
                    done()
                    return
                }
                self.compile(converted, downloadFailed: download && downloadFailed, done: done)
            }
        }
    }

    private func compile(_ items: [(Source, String, Int)], downloadFailed: Bool, done: @escaping () -> Void) {
        let group = DispatchGroup()
        var newLists: [String: WKContentRuleList] = [:]
        var count = 0
        var errors: [String] = []
        for (source, json, rules) in items {
            group.enter()
            store.compileContentRuleList(forIdentifier: identifier(source), encodedContentRuleList: json) { list, error in
                if let list { newLists[source.id] = list; count += rules } else { errors.append(source.name) }
                if let error { NSLog("Rook blocker: \(source.id) failed: \(error.localizedDescription)") }
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            // A list that failed to compile keeps its previous version.
            for (id, list) in newLists { lists[id] = list }
            if !newLists.isEmpty {
                ruleCount = count
                UserDefaults.standard.set(count, forKey: "blockerRuleCount")
                UserDefaults.standard.set(FilterConverter.version, forKey: "blockerConverterVersion")
                if !downloadFailed { UserDefaults.standard.set(Date(), forKey: "blockerLastUpdate") }
            }
            if !errors.isEmpty { problem = "Fehler in: " + errors.joined(separator: ", ") }
            else if downloadFailed { problem = "Aktualisierung fehlgeschlagen – ältere Listen aktiv" }
            working = false
            applyAll()
            done()
        }
    }

    /// Downloads one list over HTTPS without cookies. Keeps the old file if anything looks wrong.
    private func download(_ source: Source) -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Rook"]
        let session = URLSession(configuration: config)
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: source.url) { [self] data, response, _ in
            defer { semaphore.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count > 10_000,
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("[Adblock") else { return }
            ok = (try? data.write(to: file(source), options: .atomic)) != nil
        }.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        return ok
    }

    // MARK: Applying

    private func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        guard isEnabled else { return }
        for source in sources { if let list = lists[source.id] { controller.add(list) } }
    }

    private func applyAll() {
        controllers.allObjects.forEach(apply)
    }
}
