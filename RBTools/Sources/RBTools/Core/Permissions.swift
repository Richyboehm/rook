import AppKit
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import EventKit

/// Überblick über alle Erlaubnisse, die RB-Tools von macOS braucht, mit Knopf zum
/// Anfragen. Geprüft wird nur, wenn die Kommandozentrale offen ist.
@MainActor
final class Permissions: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Kind: String, CaseIterable, Identifiable {
        case spotify, accessibility, screenRecording, calendar, bluetooth, downloads
        var id: String { rawValue }

        var title: String {
            switch self {
            case .spotify: "Spotify steuern"
            case .accessibility: "Bedienungshilfen"
            case .screenRecording: "Bildschirmaufnahme"
            case .calendar: "Kalender"
            case .bluetooth: "Bluetooth"
            case .downloads: "Downloads-Ordner"
            }
        }

        var symbol: String {
            switch self {
            case .spotify: "music.note"
            case .accessibility: "accessibility"
            case .screenRecording: "rectangle.dashed.badge.record"
            case .calendar: "calendar"
            case .bluetooth: "airpods"
            case .downloads: "arrow.down.circle"
            }
        }

        /// Wofür die Erlaubnis gebraucht wird.
        var usedBy: String {
            switch self {
            case .spotify: "Musik auf Sperrbildschirm, StandBy und Notch"
            case .accessibility: "Fensterholer (Cmd + Tab)"
            case .screenRecording: "Screenshots aus der Notch"
            case .calendar: "Termine in Notch und StandBy"
            case .bluetooth: "AirPods-Anzeige in der Notch"
            case .downloads: "Downloads-Aufräumer"
            }
        }

        /// Bereich in den Systemeinstellungen, falls man sie dort von Hand freigeben muss.
        var settingsAnchor: String {
            switch self {
            case .spotify: "Privacy_Automation"
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            case .calendar: "Privacy_Calendars"
            case .bluetooth: "Privacy_Bluetooth"
            case .downloads: "Privacy_FilesAndFolders"
            }
        }
    }

    enum Status: Equatable {
        case granted, denied, notDetermined
        case unavailable(String)
    }

    @Published private(set) var status: [Kind: Status] = [:]
    private var bluetoothManager: CBCentralManager?

    var grantedCount: Int { status.values.filter { $0 == .granted }.count }

    func refresh() {
        status[.accessibility] = AXIsProcessTrusted() ? .granted : .notDetermined
        status[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        status[.calendar] = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        status[.bluetooth] = switch CBManager.authorization {
        case .allowedAlways: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        // Erst nach der ersten Anfrage nachsehen, sonst würde schon das Prüfen den Dialog auslösen.
        if UserDefaults.standard.bool(forKey: "downloadsAccessAsked") {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: DownloadsCleaner.downloads.path)) != nil
            status[.downloads] = readable ? .granted : .denied
        } else {
            status[.downloads] = .notDetermined
        }
        refreshSpotify(ask: false)
    }

    func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(prompt) { openSettings(kind) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .calendar:
            if status[kind] == .denied { return openSettings(kind) }
            EKEventStore().requestFullAccessToEvents { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
            }
        case .bluetooth:
            if status[kind] == .denied { return openSettings(kind) }
            bluetoothManager = CBCentralManager(delegate: self, queue: .main)
        case .downloads:
            // Der erste Zugriff lässt macOS nachfragen.
            UserDefaults.standard.set(true, forKey: "downloadsAccessAsked")
            if (try? FileManager.default.contentsOfDirectory(atPath: DownloadsCleaner.downloads.path)) == nil {
                openSettings(kind)
            }
        case .spotify:
            if status[kind] == .denied { return openSettings(kind) }
            refreshSpotify(ask: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func openSettings(_ kind: Kind) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }

    /// Die Spotify-Abfrage kann warten, bis man im Dialog geantwortet hat, deshalb im Hintergrund.
    private func refreshSpotify(ask: Bool) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            status[.spotify] = .unavailable("Spotify ist nicht geöffnet")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client")
            let result = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            let status: Status = switch result {
            case noErr: .granted
            case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
            case OSStatus(errAEEventNotPermitted): .denied
            default: .unavailable("Spotify antwortet nicht")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.status[.spotify] = status } }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothManager = nil
            refresh()
        }
    }
}
