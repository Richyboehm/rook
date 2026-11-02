import AppKit
import ApplicationServices

// Dock wie unter Windows: Ein Klick auf das Dock-Symbol der App, die gerade vorne ist,
// minimiert ihre Fenster ins Dock, mit der normalen Animation von macOS. Der nächste Klick
// holt alle Fenster zurück (macOS selbst würde nur eins wiederherstellen).
// Beobachtet werden nur Mausklicks, keine Mausbewegungen. Genauer hingeschaut wird nur bei
// Klicks auf das Dock. Braucht die Erlaubnis „Bedienungshilfen“.

@MainActor
final class DockToggle {
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private(set) var running = false

    /// App, die beim Drücken der Maustaste vorne war, und wo gedrückt wurde.
    private var pressed: (app: NSRunningApplication?, location: CGPoint)?
    /// Bereich des Docks; wird höchstens alle 10 Sekunden beim Dock nachgefragt.
    private var dockFrame: CGRect?
    private var dockFrameDate = Date.distantPast

    func start() {
        guard !running else { return }
        running = true
        if AXIsProcessTrusted() {
            installTap()
        } else {
            log("Wartet auf die Erlaubnis „Bedienungshilfen“")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    timer.invalidate()
                    self?.trustTimer = nil
                    self?.installTap()
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        trustTimer?.invalidate()
        trustTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        log("Ausgeschaltet")
    }

    private func installTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                let toggle = Unmanaged<DockToggle>.fromOpaque(context!).takeUnretainedValue()
                MainActor.assumeIsolated { toggle.observe(type, event) }
                return Unmanaged.passUnretained(event) // Klicks immer unverändert weiterreichen
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return log("Klick-Beobachtung konnte nicht gestartet werden") }
        log("Bereit")
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            // Nur merken, wenn der Klick im Dock liegt; sonst passiert hier nichts weiter.
            pressed = isInDock(event.location) ? (NSWorkspace.shared.frontmostApplication, event.location) : nil
        case .leftMouseUp:
            guard let pressed else { return }
            self.pressed = nil
            let location = event.location
            // Gezogen statt geklickt (z. B. Symbol verschoben): nichts tun.
            guard hypot(location.x - pressed.location.x, location.y - pressed.location.y) < 6,
                  let clicked = dockApp(at: location),
                  let app = NSWorkspace.shared.runningApplications.first(where: { Self.same(clicked, $0.bundleURL) }),
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            // Zustand jetzt lesen, bevor das Dock auf den Klick reagiert (es bekommt ihn erst danach).
            let windows = Self.standardWindows(of: app)
            let open = windows.filter { !Self.isMinimized($0) }
            let minimized = windows.filter(Self.isMinimized)
            if pressed.app?.processIdentifier == app.processIdentifier, !open.isEmpty, hasVisibleWindows(app) {
                // Vorne und sichtbar: alle Fenster ins Dock.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    open.forEach { Self.setMinimized($0, true) }
                }
                log("\(app.localizedName ?? "App") minimiert")
            } else if open.isEmpty, !minimized.isEmpty {
                // Alles im Dock: alle Fenster zurück, nicht nur das eine, das macOS selbst holt.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    minimized.forEach { Self.setMinimized($0, false) }
                    app.activate()
                }
                log("\(app.localizedName ?? "App") zurückgeholt")
            }
        default:
            break
        }
    }

    // MARK: Dock

    private var dockPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    /// Grobe Vorprüfung mit dem zwischengespeicherten Bereich des Docks.
    private func isInDock(_ point: CGPoint) -> Bool {
        if dockFrame == nil || Date().timeIntervalSince(dockFrameDate) > 10 {
            dockFrame = currentDockFrame()
            dockFrameDate = Date()
        }
        return dockFrame?.insetBy(dx: -4, dy: -4).contains(point) ?? false
    }

    /// Bereich der Symbolleiste im Dock (Bildschirmkoordinaten, Ursprung oben links).
    private func currentDockFrame() -> CGRect? {
        guard let pid = dockPID else { return nil }
        let dock = AXUIElementCreateApplication(pid)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first else { return nil }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Welche App gehört zum Dock-Symbol an dieser Stelle?
    private func dockApp(at point: CGPoint) -> URL? {
        guard let pid = dockPID else { return nil }
        let dock = AXUIElementCreateApplication(pid)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var subrole: CFTypeRef?, url: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String == "AXApplicationDockItem",
              AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &url) == .success else { return nil }
        return (url as? URL) ?? (url as? NSURL) as URL?
    }

    // MARK: Fenster

    /// Normale Fenster der App (keine Paletten, Menüs oder Dialoge).
    private static func standardWindows(of app: NSRunningApplication) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.filter { window in
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            return subrole as? String == kAXStandardWindowSubrole as String
        }
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        return (value as? Bool) ?? false
    }

    private static func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }

    private static func same(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        return a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Nur ausblenden, wenn die App sichtbare Fenster hat. Ohne Fenster öffnet der Klick
    /// wie gewohnt ein neues.
    private func hasVisibleWindows(_ app: NSRunningApplication) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && (window[kCGWindowLayer as String] as? Int) == 0
                && ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0
        }
    }

    private func log(_ message: String) { Log.write("Dock – \(message)") }
}
