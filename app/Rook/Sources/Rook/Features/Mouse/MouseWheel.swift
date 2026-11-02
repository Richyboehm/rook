import AppKit
import ApplicationServices

// Mausrad: dreht die Scroll- und Zoomrichtung nur für Mäuse mit Rad um. macOS kennt für
// „Natürliches Scrollen“ nur einen Schalter für Maus und Trackpad zusammen; Rook kehrt
// die Richtung deshalb nachträglich für die Maus um. Trackpad und Magic Mouse bleiben,
// wie sie in den Systemeinstellungen eingestellt sind.
// Braucht die Erlaubnis „Bedienungshilfen“; ohne sie bleibt das Mausrad unverändert.

@MainActor
final class MouseWheel {
    /// Scrollen ohne Sondertaste umkehren.
    var reverseScroll = true
    /// Mit gedrückter Cmd- oder ctrl-Taste (Zoomen in Apps und Bildschirmzoom) umkehren.
    var reverseZoom = true
    /// Auch das seitliche Scrollen (Kipprad, zweites Rad) umkehren.
    var reverseHorizontal = true

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
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
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, context in
                let wheel = Unmanaged<MouseWheel>.fromOpaque(context!).takeUnretainedValue()
                MainActor.assumeIsolated { wheel.handle(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return log("Mausrad-Beobachtung konnte nicht gestartet werden") }
        log("Bereit")
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            guard Self.isWheel(event) else { return }
            let zoom = !event.flags.isDisjoint(with: [.maskCommand, .maskControl])
            guard zoom ? reverseZoom : reverseScroll else { return }
            Self.invert(event, axis: 1)
            if reverseHorizontal { Self.invert(event, axis: 2) }
        default:
            break
        }
    }

    /// Trackpad und Magic Mouse schicken Gesten mit Anfang, Ende und Nachlauf; ein Mausrad
    /// schickt nur einzelne Rasten ohne solche Phasen.
    private static func isWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
            && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
    }

    /// Ein Scroll-Ereignis trägt dieselbe Bewegung in drei Feldern. Das Setzen der Rasten
    /// rechnet die anderen beiden grob neu aus, deshalb danach alle mit ihrem genauen Wert.
    private static func invert(_ event: CGEvent, axis: Int) {
        let (lines, fixed, points): (CGEventField, CGEventField, CGEventField) = axis == 1
            ? (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
            : (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        let lineValue = event.getIntegerValueField(lines)
        let fixedValue = event.getDoubleValueField(fixed)
        let pointValue = event.getIntegerValueField(points)
        event.setIntegerValueField(lines, value: -lineValue)
        event.setDoubleValueField(fixed, value: -fixedValue)
        event.setIntegerValueField(points, value: -pointValue)
    }

    private func log(_ message: String) { Log.write("Mausrad – \(message)") }
}
