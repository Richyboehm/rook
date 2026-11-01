import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum Placement: String, CaseIterable {
    case top = "Oben", middle = "Mitte", bottom = "Unten"
}

/// Rahmenloses Fenster, das nie den Fokus stiehlt.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotify = Spotify()
    private let layout = WidgetLayout()
    private lazy var standby = StandByController(spotify: spotify)
    private let power = PowerMonitor()
    private var calendar: CalendarWatcher?
    private var panel: WidgetPanel!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var hideWork: DispatchWorkItem?
    private var visible = false
    private var screensAsleep = false { didSet { updateTicking() } }

    private var isLocked = false { didSet { widgetNeededChanged() } }
    /// Zeigt das Widget zum Ausprobieren auch auf dem Schreibtisch.
    private var preview = CommandLine.arguments.contains("--preview") { didSet { widgetNeededChanged() } }

    private var placement: Placement {
        get { Placement(rawValue: UserDefaults.standard.string(forKey: "placement") ?? "") ?? .middle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "placement"); layout.placement = newValue }
    }

    /// Freier Bereich des Sperrbildschirms zwischen Uhr und Benutzerfeld,
    /// als Anteil der Bildschirmhöhe von oben gemessen.
    private let freeAreaTop: CGFloat = 0.30
    private let freeAreaBottom: CGFloat = 0.78

    func applicationDidFinishLaunching(_ notification: Notification) {
        layout.placement = placement
        makePanel()
        makeMenu()

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("Mac gesperrt")
                self?.isLocked = true
                self?.standby.setLocked(true)
            }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("Mac entsperrt")
                self?.preview = false // Vorschau endet nach dem ersten Sperrtest
                self?.isLocked = false
                self?.standby.setLocked(false)
            }
        }
        isLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false

        // StandBy: Akku und Termine kommen als Meldungen, nichts wird abgefragt.
        standby.onVisibilityChange = { [weak self] in self?.updateVisibility() }
        standby.setBattery(power.state)
        standby.setLocked(isLocked)
        power.onChange = { [weak self] state, _ in self?.standby.setBattery(state) }
        calendar = CalendarWatcher()
        calendar?.onUpdate = { [weak self] event, _ in
            guard let self, self.standby.model.nextEvent != event else { return }
            self.standby.model.nextEvent = event
        }

        // Ist der Bildschirm aus, muss der Fortschrittsbalken nicht weiterlaufen.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        }

        spotify.$isPlaying.combineLatest(spotify.$track)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        // Einmalige Abfrage beim Start: holt den aktuellen Stand und lässt macOS die
        // Spotify-Erlaubnis abfragen, solange der Mac noch entsperrt ist. Danach kommt
        // jeder Wechsel als Meldung von Spotify, ohne Abfragen.
        spotify.query()
    }

    private func widgetNeededChanged() {
        spotify.needsArtwork = isLocked || preview
        updateVisibility()
    }

    /// Der Fortschrittsbalken tickt nur, wenn man ihn auch sieht und er sich bewegt.
    private func updateTicking() {
        let ticking = visible && spotify.isPlaying && !screensAsleep
        if layout.ticking != ticking { layout.ticking = ticking }
    }

    private func makePanel() {
        panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: layout.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.canBecomeVisibleWithoutLogin = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: WidgetView(spotify: spotify, layout: layout))
        panel.alphaValue = 0
        positionPanel()
    }

    /// Das Fenster deckt den freien Bereich zwischen Uhr und Benutzerfeld ab;
    /// darin sitzt die kleine Karte oben, mittig oder unten, die große immer mittig.
    private func positionPanel() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let frame = screen.frame
        let top = frame.maxY - frame.height * freeAreaTop
        let bottom = frame.maxY - frame.height * freeAreaBottom
        let size = CGSize(width: 480, height: top - bottom)
        if layout.canvas != size { layout.canvas = size }
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: bottom, width: size.width, height: size.height), display: true)
    }

    private func updateVisibility() {
        defer { updateTicking() }
        // Während StandBy zu sehen ist, steckt die Musik dort drin.
        let wanted = (isLocked || preview) && spotify.track != nil && !standby.visible
        if wanted && spotify.isPlaying {
            hideWork?.cancel()
            hideWork = nil
            setVisible(true)
        } else if wanted && visible {
            // Kurz nach dem Pausieren stehen lassen, damit man wieder auf Play tippen kann.
            guard hideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.hideWork = nil
                    self?.setVisible(false)
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        } else {
            hideWork?.cancel()
            hideWork = nil
            setVisible(false)
        }
    }

    /// Unsichtbar ist das Fenster ganz vom Bildschirm genommen, damit das System es
    /// weder zeichnen noch mischen muss.
    private func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        Log.write("Widget \(show ? "eingeblendet" : "ausgeblendet"), gesperrt: \(isLocked)")
        if show {
            positionPanel()
            panel.orderFrontRegardless()
            SkyLight.moveAboveLockScreen(panel)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: Menüleiste

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "LockGlass")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func togglePreview() { preview.toggle() }
    @objc private func toggleStandBy() { standby.enabled.toggle() }
    @objc private func toggleAutoLock() { standby.autoLock.toggle() }
    @objc private func previewStandBy() { standby.preview() }
    @objc private func choosePlacement(_ sender: NSMenuItem) {
        if let p = Placement(rawValue: sender.title) { placement = p }
    }
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Autostart konnte nicht geändert werden"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let previewItem = NSMenuItem(title: "Vorschau auf dem Schreibtisch", action: #selector(togglePreview), keyEquivalent: "")
        previewItem.state = preview ? .on : .off
        menu.addItem(previewItem)

        let placementItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in Placement.allCases {
            let item = NSMenuItem(title: p.rawValue, action: #selector(choosePlacement(_:)), keyEquivalent: "")
            item.state = p == placement ? .on : .off
            item.target = self
            sub.addItem(item)
        }
        placementItem.submenu = sub
        menu.addItem(placementItem)

        menu.addItem(.separator())
        let standbyItem = NSMenuItem(title: "StandBy am Strom", action: #selector(toggleStandBy), keyEquivalent: "")
        standbyItem.state = standby.enabled ? .on : .off
        menu.addItem(standbyItem)
        let autoLockItem = NSMenuItem(title: "Am Strom nach 5 Min automatisch sperren", action: #selector(toggleAutoLock), keyEquivalent: "")
        autoLockItem.state = standby.autoLock ? .on : .off
        menu.addItem(autoLockItem)
        menu.addItem(NSMenuItem(title: "StandBy jetzt ansehen", action: #selector(previewStandBy), keyEquivalent: ""))
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Beim Anmelden starten", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "LockGlass beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
