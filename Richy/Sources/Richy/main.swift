import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()
        makeStatusItem()
        NotificationCenter.default.addObserver(forName: .openControlCenter, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showControlCenter() }
        }
        // Beim allerersten Start die Kommandozentrale zeigen.
        if !state.settings.hasOnboarded {
            state.settings.hasOnboarded = true
            showControlCenter()
        }
    }

    /// Doppelklick auf die App, während sie schon läuft: Kommandozentrale öffnen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlCenter()
        return true
    }

    // MARK: Kommandozentrale

    @objc func showControlCenter() {
        if window == nil {
            let view = ControlCenterView(settings: state.settings, permissions: state.permissions,
                                         downloads: state.downloads, weather: state.weather, state: state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Richy"
            window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: view)
            window.setContentSize(NSSize(width: 920, height: 640))
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // Solange das Fenster offen ist, gibt es ein Dock-Symbol und Cmd + Tab findet es.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Kommandozentrale direkt auf der Seite einer Funktion öffnen.
    private func showControlCenter(feature: Feature?) {
        showControlCenter()
        guard let feature else { return }
        // Erst im nächsten Durchlauf, damit ein frisch erzeugtes Fenster schon zuhört.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showControlCenterPage, object: feature.rawValue)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Fenster samt Inhalt freigeben; beim nächsten Öffnen wird es neu gebaut.
        DispatchQueue.main.async {
            self.window = nil
            Memory.relieve()
        }
    }

    // MARK: Menüleiste

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarSymbol()
        button.setAccessibilityLabel("Richy")
        button.target = self
        button.action = #selector(togglePanel)
        // Öffnet schon beim Drücken, wie die Menüs von macOS.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        if panel == nil {
            let panel = MenuBarPanel(state: state) { [weak self] feature in self?.showControlCenter(feature: feature) }
            panel.onClose = { [weak self] in self?.statusItem.button?.highlight(false) }
            self.panel = panel
        }
        button.highlight(true)
        panel?.show(below: button)
    }

    /// Der Rabenkopf aus dem App-Icon als gefüllte Silhouette (Scripts/make-icon.swift).
    /// Als Vorlage, damit macOS ihn passend zur hellen oder dunklen Menüleiste einfärbt.
    private static func menuBarSymbol() -> NSImage? {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
