import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
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
            window.title = "RB-Tools"
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

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menüleiste

    private func makeStatusItem() {
        // Schlicht: nur „RB“ als Text, passend zum App-Icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "RB"
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .semibold)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "RB-Tools", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for feature in Feature.allCases {
            if feature == .notch && !NotchFeature.isAvailable { continue }
            let item = NSMenuItem(title: feature.title, action: #selector(toggleFeature(_:)), keyEquivalent: "")
            item.representedObject = feature.rawValue
            item.state = feature.isOn(state.settings).wrappedValue ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let standBy = NSMenuItem(title: "StandBy ansehen", action: #selector(previewStandBy), keyEquivalent: "")
        standBy.target = self
        menu.addItem(standBy)
        let open = NSMenuItem(title: "Kommandozentrale öffnen …", action: #selector(showControlCenter), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "RB-Tools beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let feature = Feature(rawValue: raw) else { return }
        let binding = feature.isOn(state.settings)
        binding.wrappedValue.toggle()
    }

    @objc private func previewStandBy() { state.standBy.preview() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
