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
    /// CPU im Schnitt seit dem Start, ohne die ersten 30 Sekunden (das Starten selbst
    /// kostet kurz etwas). Gemessen, nicht geschätzt; nil, solange die App noch frisch ist.
    @Published private(set) var averageCPU: Double?

    /// CPU, während das Raben-Fenster zu war: vom letzten Schließen bis zum Öffnen.
    /// Das ist der eigentliche Verbrauch im Alltag; gemessen ohne eigenen Takt.
    @Published private(set) var backgroundCPU: Double?
    @Published private(set) var backgroundDuration: TimeInterval = 0

    /// Stand 30 Sekunden nach dem Start; einmal gesetzt von `recordBaseline()`.
    private static var baseline: (cpu: Double, time: TimeInterval)?
    /// Stand beim letzten Schließen des Raben-Fensters.
    private static var closedMark: (cpu: Double, time: TimeInterval)?

    /// Beim Schließen des Raben-Fensters: Stand merken.
    static func windowClosed() {
        closedMark = (cpuSeconds(), ProcessInfo.processInfo.systemUptime)
    }

    /// Beim Öffnen, bevor das Fenster selbst etwas kostet: Verbrauch seit dem Schließen.
    /// Beim ersten Öffnen nach dem Start zählt die Zeit ab 30 Sekunden nach dem Start.
    func windowOpened() {
        let cpu = Self.cpuSeconds(), now = ProcessInfo.processInfo.systemUptime
        guard let mark = Self.closedMark ?? Self.baseline, now - mark.time > 3 else { return }
        backgroundCPU = max(0, (cpu - mark.cpu) / (now - mark.time) * 100)
        backgroundDuration = now - mark.time
    }

    /// Einmal 30 Sekunden nach dem Start aufrufen. Kostet sonst nichts, kein Takt.
    static func recordBaseline() {
        baseline = (cpuSeconds(), ProcessInfo.processInfo.systemUptime)
    }

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
        if let base = Self.baseline, now - base.time > 5 {
            averageCPU = max(0, (cpu - base.cpu) / (now - base.time) * 100)
        }
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
}
