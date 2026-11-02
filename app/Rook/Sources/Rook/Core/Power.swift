import Combine
import Foundation
import IOKit.ps

struct BatteryState: Equatable {
    var percent: Int
    var onPower: Bool
}

/// Meldet Änderungen am Akku. macOS ruft uns von selbst auf (Netzteil an/ab,
/// Prozentwechsel); es wird nichts regelmäßig abgefragt.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var state = PowerMonitor.read()
    /// Feuert, wenn das Netzteil angesteckt wird.
    let pluggedIn = PassthroughSubject<Void, Never>()
    private var source: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.changed() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func changed() {
        let new = PowerMonitor.read()
        guard new != state else { return }
        let wasOnPower = state.onPower
        state = new
        if new.onPower && !wasOnPower { pluggedIn.send() }
    }

    static func read() -> BatteryState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryState(percent: 100, onPower: true) }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return BatteryState(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return BatteryState(percent: 100, onPower: true)
    }
}
