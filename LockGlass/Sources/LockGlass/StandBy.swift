import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// StandBy wie beim iPhone: Ist der Mac am Strom und gesperrt, wird der Sperrbildschirm
/// nach ein paar Sekunden Ruhe zur großen Uhr-Anzeige. Bewegung von Maus oder Tastatur
/// blendet sie aus, damit man entsperren kann. Im Akkubetrieb läuft hier gar nichts.
@MainActor
final class StandByController {
    let model = StandByModel()
    private(set) var visible = false
    var onVisibilityChange: (() -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "standbyEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "standbyEnabled"); if !newValue { hide() }; reschedule() }
    }
    /// Am Strom nach einer Weile ohne Eingabe automatisch sperren (und damit in StandBy gehen).
    var autoLock: Bool {
        get { UserDefaults.standard.object(forKey: "standbyAutoLock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "standbyAutoLock"); reschedule() }
    }

    private let panel: NSPanel
    private var locked = false
    private var previewing = false
    private var timer: Timer?
    private var shownAt = Date.distantPast
    /// Wie lange Ruhe herrschen muss, bevor StandBy (wieder) erscheint.
    private var showAfter: TimeInterval = 3
    private var assertion: IOPMAssertionID = 0

    init(spotify: Spotify) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.canBecomeVisibleWithoutLogin = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true // Bewegung wird über die Ruhezeit erkannt
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: StandByView(spotify: spotify, model: model))
    }

    // MARK: Zustand von außen

    func setLocked(_ isLocked: Bool) {
        locked = isLocked
        showAfter = 3
        if !isLocked && !previewing { hide() }
        reschedule()
    }

    func setBattery(_ state: BatteryState) {
        if model.battery != state { model.battery = state }
        if !state.onPower && !previewing { hide() }
        reschedule()
    }

    /// Zum Anschauen auf dem Schreibtisch; die erste Bewegung blendet sie wieder aus.
    func preview() {
        previewing = true
        show()
    }

    // MARK: Takt – nur am Strom, und nur so oft wie nötig

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard enabled, model.battery.onPower || previewing else { return }
        let interval: TimeInterval
        if visible { interval = 1 }                  // auf Bewegung achten
        else if locked { interval = 2 }               // auf Ruhe warten
        else if autoLock { interval = 20 }            // Ruhe zum automatischen Sperren
        else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let idle = idleSeconds()
        if visible {
            // Kurz nach dem Einblenden Bewegungen ignorieren (z. B. der Klick zum Sperren).
            guard Date().timeIntervalSince(shownAt) > 2, idle < 1.5 else { return }
            previewing = false
            showAfter = 30
            hide()
        } else if locked {
            if idle >= showAfter { show() }
        } else if autoLock, idle >= autoLockDelay(), !otherAppKeepsDisplayOn() {
            Log.write("StandBy: \(Int(idle)) s ohne Eingabe, Mac wird gesperrt")
            lockScreen()
        }
    }

    private func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    /// 5 Minuten, aber immer vor dem Abschalten des Bildschirms (Energie-Einstellung am Strom).
    private func autoLockDelay() -> TimeInterval {
        max(min(300, Self.acDisplaySleepMinutes * 60 - 30), 60)
    }

    /// „Bildschirm aus nach …“ am Strom, einmal beim Start aus `pmset` gelesen.
    private static let acDisplaySleepMinutes: Double = {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return 10 }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let ac = output.components(separatedBy: "AC Power:").last,
              let line = ac.split(separator: "\n").first(where: { $0.contains("displaysleep") }),
              let value = line.split(separator: " ").last.flatMap({ Double($0) }), value > 0 else { return 10 }
        return value
    }()

    /// Läuft ein Video oder eine Präsentation, hält diese App den Bildschirm wach;
    /// dann nicht sperren.
    private func otherAppKeepsDisplayOn() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict[kIOPMAssertionTypePreventUserIdleDisplaySleep] ?? 0) > 0
    }

    private func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        unsafeBitCast(symbol, to: Lock.self)()
    }

    // MARK: Ein- und Ausblenden

    private func show() {
        guard !visible, enabled, let screen = NSScreen.screens.first else { return }
        visible = true
        shownAt = Date()
        model.active = true
        Log.write("StandBy eingeblendet")
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        SkyLight.moveAboveLockScreen(panel)
        // Bildschirm wach halten, solange StandBy zu sehen ist (nur am Strom).
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "LockGlass StandBy" as CFString, &assertion)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            panel.animator().alphaValue = 1
        }
        onVisibilityChange?()
        reschedule()
    }

    private func hide() {
        guard visible else { return }
        visible = false
        model.active = false
        Log.write("StandBy ausgeblendet")
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
            }
        }
        onVisibilityChange?()
        reschedule()
    }
}
