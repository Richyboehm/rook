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

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menüleiste

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarSymbol()
        statusItem.button?.setAccessibilityLabel("Richy")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Der ry-Block aus dem App-Icon, klein für die Menüleiste. Als Vorlage gezeichnet,
    /// damit macOS ihn passend zur hellen oder dunklen Menüleiste einfärbt.
    private static func menuBarSymbol() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3.5, y: 1.5, width: 13, height: 13), xRadius: 3, yRadius: 3).fill()
            let front = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.25, width: 13, height: 13), xRadius: 3, yRadius: 3)
            // Vorderseite freistellen, damit die Kante dahinter wie im Icon wirkt.
            NSGraphicsContext.current?.compositingOperation = .clear
            front.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            front.lineWidth = 1.5
            NSColor.black.setStroke()
            front.stroke()
            let text = NSAttributedString(string: "ry", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .heavy), .foregroundColor: NSColor.black])
            let size = text.size()
            text.draw(at: NSPoint(x: 8.25 - size.width / 2, y: 9.75 - size.height / 2 + 1))
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Richy", action: nil, keyEquivalent: "")
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
        menu.addItem(NSMenuItem(title: "Richy beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
