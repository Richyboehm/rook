import AppKit
import CoreBluetooth
import IOBluetooth

// Alle Melder hier hängen sich an Ereignisse des Systems und rechnen nur, wenn wirklich
// etwas passiert. Es wird nichts regelmäßig abgefragt.

// MARK: Kopfhörer

struct Headphones: Equatable {
    var name: String
    var symbol: String
    var battery: Int?
}

/// Meldet, wenn sich Bluetooth-Kopfhörer verbinden (AirPods mit Akkustand).
/// Die Bluetooth-Erlaubnis wird zuerst ohne Blockieren erfragt; IOBluetooth würde
/// sonst den Hauptthread anhalten, bis die Abfrage beantwortet ist.
@MainActor
final class HeadphoneMonitor: NSObject, CBCentralManagerDelegate {
    var onConnect: ((Headphones) -> Void)?
    private var startup = true
    private var registration: IOBluetoothUserNotification?
    private var permissionManager: CBCentralManager?

    override init() {
        super.init()
        switch CBManager.authorization {
        case .allowedAlways: register()
        case .notDetermined: permissionManager = CBCentralManager(delegate: self, queue: .main) // fragt nach
        default: break // abgelehnt: keine Kopfhörer-Anzeige
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard CBManager.authorization == .allowedAlways else { return }
            permissionManager = nil
            register()
        }
    }

    /// Abmelden, wenn die Kopfhörer-Anzeige ausgeschaltet wird.
    func stop() {
        registration?.unregister()
        registration = nil
        permissionManager = nil
    }

    private func register() {
        guard registration == nil else { return }
        startup = true
        registration = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        // Beim Anmelden meldet das System alle schon verbundenen Geräte; die nicht anzeigen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.startup = false } }
    }

    /// IOBluetooth meldet das Verbinden über die Warteschlange von CoreBluetooth, nicht
    /// über den Hauptthread. Deshalb erst dorthin wechseln, bevor etwas angefasst wird.
    @objc nonisolated private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio else { return }
        let name = device.name ?? "Kopfhörer"
        // Kurz warten: Der Akkustand kommt erst einen Moment nach dem Verbinden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard !self.startup else { return }
                self.onConnect?(Headphones(name: name, symbol: Self.symbol(for: name), battery: Self.battery(of: device)))
            }
        }
    }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        return "headphones"
    }

    /// Gerade verbundene Kopfhörer mit Akkustand. Nur mit Bluetooth-Erlaubnis abfragen,
    /// sonst würde IOBluetooth auf die Antwort im Erlaubnis-Dialog warten.
    static func connected() -> [Headphones] {
        guard CBManager.authorization == .allowedAlways else { return [] }
        return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.isConnected() && $0.deviceClassMajor == kBluetoothDeviceClassMajorAudio }
            .map { device in
                let name = device.name ?? "Kopfhörer"
                return Headphones(name: name, symbol: symbol(for: name), battery: battery(of: device))
            }
    }

    /// Akkustand über inoffizielle Methoden von IOBluetooth, falls vorhanden.
    static func battery(of device: IOBluetoothDevice) -> Int? {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        for name in ["batteryPercentCombined", "batteryPercentSingle", "batteryPercentLeft"] {
            let selector = Selector(name)
            guard device.responds(to: selector) else { continue }
            let value = unsafeBitCast(device.method(for: selector), to: Getter.self)(device, selector)
            if value > 0 && value <= 100 { return Int(value) }
        }
        return nil
    }
}
