import Darwin
import Foundation

/// Misst, wie viel Prozessor und Arbeitsspeicher Rook selbst braucht, so wie die
/// Aktivitätsanzeige (100 % CPU = ein voller Kern). Gemessen wird nur, solange die
/// Anzeige offen ist; der Höchstwert beim Speicher kommt vom System und gilt seit dem Start.
@MainActor
final class ResourceMonitor: ObservableObject {
    struct Sample: Identifiable {
        let id: Int
        let cpu: Double    // Prozent eines Kerns
        let memory: Double // MB
    }

    /// Die letzten 60 Sekunden.
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var peakMemory: Double = 0

    private var timer: Timer?
    private var last: (cpu: Double, time: TimeInterval)?
    private var counter = 0

    func start() {
        guard timer == nil else { return }
        last = nil
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let cpu = Self.cpuSeconds()
        let now = ProcessInfo.processInfo.systemUptime
        let memory = Self.memory()
        peakMemory = max(memory.peak, memory.now)
        defer { last = (cpu, now) }
        guard let last, now > last.time else { return }
        counter += 1
        samples.append(Sample(id: counter, cpu: max(0, (cpu - last.cpu) / (now - last.time) * 100), memory: memory.now))
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
    }

    /// Rechenzeit aller Threads seit dem Start, in Sekunden.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Belegter Speicher wie in der Aktivitätsanzeige („Speicher“) und sein Höchstwert, in MB.
    private static func memory() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    // MARK: Schätzung

    /// Grobe Obergrenze mit den eingeschalteten Funktionen: Grundbedarf plus, was jede Funktion
    /// in ihrem aufwendigsten Moment zusätzlich braucht (z. B. StandBy mit Uhr und Cover).
    static func estimatedMaximum(_ settings: Settings) -> (cpu: Double, memory: Double) {
        var cpu = base.cpu, memory = base.memory
        for feature in Feature.allCases where feature.isOn(settings).wrappedValue {
            guard let cost = costs[feature] else { continue }
            cpu += cost.cpu
            memory += cost.memory
        }
        return (cpu, memory)
    }

    /// Menüleiste, Notch und Spotify im Leerlauf. Gemessen mit laufender Musik: etwa 23 MB und 0,2 %.
    static let base: (cpu: Double, memory: Double) = (0.5, 25)

    /// Zusätzlich pro Funktion im aufwendigsten Moment (Animationen, Cover, Ton-Abzweigung).
    static let costs: [Feature: (cpu: Double, memory: Double)] = [
        .lockWidget: (1, 8),
        .standBy: (1.5, 12),
        .notch: (2, 10),
        .windowFetcher: (0.2, 1),
        .mouseWheel: (0.3, 1),
        .appVolume: (1.5, 4),
        .downloads: (0.5, 2),
    ]
}
