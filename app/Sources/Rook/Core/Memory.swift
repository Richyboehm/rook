import Darwin
import Foundation

enum Memory {
    /// Gibt freigewordenen Speicher (z. B. nach dem Schließen eines Fensters) gleich an
    /// macOS zurück, statt ihn für später zu behalten.
    static func relieve() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
