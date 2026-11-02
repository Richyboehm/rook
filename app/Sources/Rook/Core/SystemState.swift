import AppKit
import Combine

/// Zustände des Macs, die mehrere Funktionen brauchen. Alles kommt als Meldung vom
/// System; nichts wird regelmäßig abgefragt.
@MainActor
final class SystemState: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var screensAsleep = false
    /// Feuert einmal pro Entsperren.
    let unlocked = PassthroughSubject<Void, Never>()

    init() {
        isLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("Mac gesperrt")
                self?.isLocked = true
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("Mac entsperrt")
                self?.isLocked = false
                self?.unlocked.send()
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        }
    }
}
