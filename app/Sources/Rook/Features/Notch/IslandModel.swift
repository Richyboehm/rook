import AppKit
import SwiftUI

@MainActor
final class IslandModel: ObservableObject {
    /// Kurze Einblendungen von selbst. Manche klappen die Insel auf, andere zeigen
    /// nur links und rechts neben der Notch etwas an.
    enum Peek: Equatable {
        case track, meeting, timerDone
        case screenshot(URL)
        case charging, unlocked
        case headphones(Headphones)

        var expands: Bool {
            switch self {
            case .track, .meeting, .timerDone, .screenshot: true
            default: false
            }
        }

        var duration: TimeInterval {
            switch self {
            case .unlocked: 1.4
            case .meeting, .timerDone: 6
            case .screenshot: 4
            default: 3
            }
        }
    }

    /// Was dauerhaft neben der Notch steht, nach Wichtigkeit.
    enum Live: Equatable { case timer, meeting, music }

    /// Seiten der aufgeklappten Notch, mit zwei Fingern im Kreis durchzuwischen.
    /// In dieser Reihenfolge stehen auch die Punkte: Notiz links, die normale Seite in der Mitte,
    /// Lautstärke rechts.
    enum Page: Int, CaseIterable {
        case note, main, volume
    }

    /// Beim Zuklappen geht es immer zurück auf die normale Seite.
    @Published private(set) var page: Page = .main
    /// Das Rad mit den Seiten; es dreht ohne SwiftUI und meldet nur die neue Seite.
    let wheel = PageWheel()

    init() {
        wheel.onPageChange = { [weak self] page in self?.page = page }
    }

    /// Finger bewegt sich (negativ = nach links): Das Rad dreht direkt mit.
    func swipe(by delta: CGFloat) { wheel.drag(by: delta) }

    /// Finger losgelassen: eine Seite weiter oder zurück, mit Schwung.
    func endSwipe(flick: CGFloat) { wheel.end(flick: flick) }

    /// Ein Klick auf einen Punkt.
    func show(_ target: Page) { wheel.show(target) }

    /// Beim Zuklappen: ohne Animation zurück auf die normale Seite.
    func resetPage() { wheel.reset() }

    @Published var notch = CGSize(width: 180, height: 32)
    @Published var hovering = false
    /// Gerade wird eine Datei über die Insel gezogen.
    @Published var dragging = false
    @Published var peek: Peek?
    @Published var battery = BatteryState(percent: 100, onPower: true)
    @Published var nextEvent: UpcomingEvent?
    @Published var meetingSoon = false
    @Published private(set) var shelf: [URL] = []
    /// Ende des laufenden Timers; nil, wenn er steht oder pausiert ist.
    @Published private(set) var timerEnd: Date?
    /// Restzeit eines pausierten Timers.
    @Published private(set) var timerPaused: TimeInterval?
    @Published private(set) var timerTotal: TimeInterval = 1
    /// Eingestellte Dauer in Sekunden; die zuletzt benutzte bleibt gespeichert.
    @Published var timerSeconds: Int = {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "timerSeconds") > 0 { return defaults.integer(forKey: "timerSeconds") }
        let minutes = defaults.integer(forKey: "timerMinutes") // frühere Einstellung in Minuten
        return (minutes > 0 ? minutes : 25) * 60
    }()
    /// Gemessene Höhe der großen Ansicht (hängt davon ab, was gerade drin ist).
    @Published var expandedHeight: CGFloat = 150

    static let expandedWidth: CGFloat = 440

    /// Breite der kleinen Insel: Notch plus je ein Feld links und rechts.
    var compactWidth: CGFloat { notch.width + 2 * (notch.height + 14) }

    var onTimerDone: (() -> Void)?
    var onCapture: ((Screenshots.Mode) -> Void)?

    func capture(_ mode: Screenshots.Mode) { onCapture?(mode) }
    private var timer: Timer?

    // MARK: Timer

    var timerActive: Bool { timerEnd != nil || timerPaused != nil }

    func startTimer() {
        guard timerSeconds > 0 else { return }
        UserDefaults.standard.set(timerSeconds, forKey: "timerSeconds")
        timerTotal = TimeInterval(timerSeconds)
        run(for: timerTotal)
    }

    func pauseTimer() {
        guard let end = timerEnd else { return }
        timer?.invalidate()
        timer = nil
        timerPaused = max(end.timeIntervalSinceNow, 0)
        timerEnd = nil
    }

    func resumeTimer() {
        guard let remaining = timerPaused else { return }
        run(for: remaining)
    }

    func addMinute() {
        timerTotal += 60
        if let remaining = timerPaused {
            timerPaused = remaining + 60
        } else if let end = timerEnd {
            run(for: end.timeIntervalSinceNow + 60)
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerEnd = nil
        timerPaused = nil
    }

    /// Restzeit zu einem Zeitpunkt (auch im pausierten Zustand).
    func timerRemaining(at date: Date) -> TimeInterval {
        if let paused = timerPaused { return paused }
        return max(timerEnd?.timeIntervalSince(date) ?? 0, 0)
    }

    /// Ein einziger Wecker zum Ablauf, kein Takt im Hintergrund.
    private func run(for duration: TimeInterval) {
        timer?.invalidate()
        timerPaused = nil
        let end = Date().addingTimeInterval(duration)
        timerEnd = end
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timerEnd = nil
                self?.timer = nil
                self?.onTimerDone?()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Ablage

    /// Die Ablage merkt sich nur, wo die Dateien liegen; kopiert wird nichts.
    func addToShelf(_ urls: [URL], atFront: Bool = false) {
        let new = urls.filter { !shelf.contains($0) }
        if atFront { shelf.insert(contentsOf: new, at: 0) } else { shelf.append(contentsOf: new) }
    }

    func removeFromShelf(_ url: URL) { shelf.removeAll { $0 == url } }
    func clearShelf() { shelf.removeAll() }
}
