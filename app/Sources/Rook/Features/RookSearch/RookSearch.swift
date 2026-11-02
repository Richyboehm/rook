import AppKit

/// Rook Search, der Browser, gehört zu Rook wie die Notch: Er steckt fertig in Rook
/// (Contents/Helpers) und kommt mit jedem Rook-Update mit. Eingeschaltet legt Rook ihn nach
/// Programme, denn nur dort führt macOS ihn als Standardbrowser, im Dock und in Spotlight.
/// Ausgeschaltet kommt er in den Papierkorb; Tabs, Favoriten und Verlauf bleiben auf dem Mac.
@MainActor
final class RookSearch: ObservableObject {
    static let bundleID = "de.richyboehm.rook"
    static let target = URL(fileURLWithPath: "/Applications/Rook Search.app")
    /// Der Browser, der in diesem Rook steckt.
    static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Rook Search.app") }

    /// Version des Browsers in Programme; nil, wenn er dort nicht liegt.
    @Published private(set) var installedVersion: String?
    @Published private(set) var busy = false
    @Published private(set) var problem: String?
    /// Eine neue Version liegt bereit und kommt, sobald Rook Search beendet wird.
    @Published private(set) var waitingForQuit = false

    /// Was passiert, sobald der laufende Browser beendet ist (Update einspielen oder wegräumen).
    private var afterQuit: (() -> Void)?
    private var quitObserver: NSObjectProtocol?

    init() { refresh() }

    var isInstalled: Bool { installedVersion != nil }

    func refresh() {
        let info = AppFiles.info(of: Self.target)
        installedVersion = info?.id == Self.bundleID ? info?.version : nil
    }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    func open() {
        open(attempt: 1)
    }

    /// Direkt nach dem Austauschen kennt macOS die neue App manchmal noch nicht; dann kurz warten
    /// und nochmal versuchen.
    private func open(attempt: Int) {
        NSWorkspace.shared.openApplication(at: Self.target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.write("Rook Search öffnen, Versuch \(attempt): \(error.localizedDescription)") }
            guard attempt < 4 else { return }
            // Läuft er nach kurzer Zeit nicht, nochmal (macOS meldet nicht jeden Fehlschlag).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated {
                    if self.running == nil { self.open(attempt: attempt + 1) }
                }
            }
        }
    }

    /// Eingeschaltet: den Browser aus Rook nach Programme legen.
    func place() {
        afterQuit = nil
        waitingForQuit = false
        install(thenOpen: false)
    }

    /// Beim Start von Rook: Liegt in Programme eine ältere Version als in Rook, wird sie ersetzt;
    /// läuft der Browser gerade, erst wenn er beendet wird (nichts geht dabei verloren).
    func updateIfNeeded() {
        refresh()
        guard let bundled = AppFiles.info(of: Self.bundled), let installed = AppFiles.info(of: Self.target),
              installed.id == Self.bundleID, bundled.build > installed.build else { return }
        whenQuit { [weak self] reopen in self?.install(thenOpen: reopen) }
    }

    /// Den wartenden Browser jetzt beenden, aktualisieren und wieder öffnen.
    func restartNow() {
        running?.terminate()
    }

    /// Ausgeschaltet: Browser beenden und in den Papierkorb legen.
    func remove() {
        whenQuit { [weak self] _ in
            guard let self, AppFiles.info(of: Self.target)?.id == Self.bundleID else { return }
            try? FileManager.default.trashItem(at: Self.target, resultingItemURL: nil)
            self.refresh()
        }
        running?.terminate()
    }

    /// Führt `action` aus, sobald Rook Search nicht mehr läuft (sofort, wenn er gar nicht läuft).
    /// `action` erfährt, ob der Browser gerade lief, damit er nach einem Update wieder aufgeht.
    private func whenQuit(_ action: @escaping (_ wasRunning: Bool) -> Void) {
        guard running != nil else {
            afterQuit = nil
            waitingForQuit = false
            action(false)
            return
        }
        afterQuit = { action(true) }
        waitingForQuit = true
        guard quitObserver == nil else { return }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
                self.quitObserver = nil
                self.waitingForQuit = false
                let action = self.afterQuit
                self.afterQuit = nil
                action?()
            }
        }
    }

    private func install(thenOpen: Bool) {
        let source = Self.bundled
        guard FileManager.default.fileExists(atPath: source.path) else {
            problem = "In diesem Rook steckt kein Browser. Bitte Rook von der Download-Seite laden."
            return
        }
        if let info = AppFiles.info(of: Self.target), info.id != Self.bundleID {
            problem = "Unter Programme liegt schon eine andere App namens „Rook Search“."
            return
        }
        busy = true
        problem = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = AppFiles.replace(Self.target, with: source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.problem = problem
                    self.refresh()
                    guard problem == nil else { return }
                    // Sofort bei macOS anmelden, damit er als Standardbrowser wählbar ist.
                    LSRegisterURL(Self.target as CFURL, true)
                    if thenOpen { self.open() }
                }
            }
        }
    }
}
