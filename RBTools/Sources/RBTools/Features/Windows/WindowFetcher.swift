import AppKit
import ApplicationServices

/// Inoffiziell, aber seit Jahren stabil: liefert zur Bedienungshilfen-Ansicht eines
/// Fensters dessen Fensternummer im Fenstersystem.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// Fensterholer: Nach Cmd + Tab erscheint immer ein Fenster der gewählten App.
// Braucht die Erlaubnis „Bedienungshilfen“; ohne sie bleibt er still.
// Die Cmd + Tab-Leiste von macOS bleibt unverändert; es werden keine Tasten
// verändert oder geschluckt. Ein minimiertes Fenster wird zurückgeholt, eine App
// ohne Fenster öffnet ein neues. Bei allen anderen App-Wechseln (Dock, Klick auf
// ein Fenster, Schreibtisch) passiert nichts.

@MainActor
final class WindowFetcher {
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private(set) var running = false
    /// Cmd wird gerade gehalten.
    private var commandHeld = false
    /// Während Cmd gehalten wurde, kam ein anderes Kürzel (z. B. Cmd + Q, Cmd + C).
    private var otherShortcut = false
    /// Wann Cmd zuletzt ohne anderes Kürzel losgelassen wurde.
    private var releasedAt: Date?

    func start() {
        guard !running else { return }
        running = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.activated(app) } }
        }
        if AXIsProcessTrusted() {
            installTap()
        } else {
            log("Wartet auf die Erlaubnis „Bedienungshilfen“")
            // Nur bis die Erlaubnis da ist, alle 2 Sekunden nachsehen.
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
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        log("Ausgeschaltet")
    }

    // MARK: Cmd + Tab erkennen

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                let holer = Unmanaged<WindowFetcher>.fromOpaque(context!).takeUnretainedValue()
                MainActor.assumeIsolated { holer.observe(type, event) }
                return Unmanaged.passUnretained(event) // immer unverändert weiterreichen
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return log("Tastatur-Beobachtung konnte nicht gestartet werden") }
        log("Bereit")
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// macOS verarbeitet Cmd + Tab als Systemkürzel, bevor Apps die Tab-Taste sehen.
    /// Erkennbar ist es trotzdem: Beim Loslassen von Cmd wechselt die App, und während
    /// Cmd gehalten wurde, kam kein anderes (sichtbares) Kürzel.
    private func observe(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if commandHeld && event.getIntegerValueField(.keyboardEventKeycode) != 48 { otherShortcut = true }
        case .flagsChanged:
            let command = event.flags.contains(.maskCommand)
            if command && !commandHeld {
                commandHeld = true
                otherShortcut = false
            } else if !command && commandHeld {
                commandHeld = false
                releasedAt = otherShortcut ? nil : Date()
            }
        default:
            break
        }
    }

    // MARK: Fenster nach vorne holen

    private func activated(_ app: NSRunningApplication) {
        guard let releasedAt, Date().timeIntervalSince(releasedAt) < 0.5 else { return }
        self.releasedAt = nil
        // Kurz warten, bis macOS fertig gewechselt hat (auch auf einen anderen Schreibtisch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { self.bringWindow(of: app) }
        }
    }

    private func bringWindow(of app: NSRunningApplication) {
        let name = app.localizedName ?? "?"
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        let all = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success
            ? (value as? [AXUIElement] ?? []) : []
        // Echte Fenster: Standardfenster oder (bei Chrome, Electron & Co.) Fenster ohne
        // Untertyp, aber nur ab einer sinnvollen Größe – keine Popups oder Tooltips.
        let windows = all.filter { window in
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == "AXUnknown" else { return false }
            let size = self.size(of: window)
            return size.width >= 150 && size.height >= 100
        }
        let onScreen = onScreenWindowIDs(of: app)
        let minimized = windows.filter { attribute($0, kAXMinimizedAttribute) as? Bool == true }
        // Sichtbar heißt: nicht minimiert und wirklich auf dem Bildschirm. Manche Apps
        // behalten geschlossene Fenster unsichtbar im Speicher.
        let visible = windows.filter { window in
            guard attribute(window, kAXMinimizedAttribute) as? Bool != true else { return false }
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(window, &id) != .success || onScreen.contains(id)
        }
        let summary = "\(name): \(windows.count) Fenster, \(visible.count) sichtbar, \(minimized.count) minimiert"

        if !visible.isEmpty {
            log("\(summary) → nichts zu tun")
            return
        }
        if let window = minimized.first {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            log("\(summary) → aus dem Dock zurückgeholt")
            return
        }
        // Kein Fenster: App bitten, eins zu öffnen, wie bei einem Klick aufs Dock-Symbol.
        // Hat sie noch eins auf einem anderen Schreibtisch, springt macOS stattdessen dorthin.
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        log("\(summary) → neues Fenster angefordert")
    }

    private func onScreenWindowIDs(of app: NSRunningApplication) -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
                ? info[kCGWindowNumber as String] as? CGWindowID : nil
        })
    }

    private func size(of window: AXUIElement) -> CGSize {
        var size = CGSize.zero
        if let value = attribute(window, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return size
    }

    private func log(_ message: String) { Log.write("Fensterholer – \(message)") }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
