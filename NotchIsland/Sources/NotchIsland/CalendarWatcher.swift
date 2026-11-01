import AppKit
import EventKit
import SwiftUI

struct UpcomingEvent: Equatable {
    var title: String
    var start: Date
    var color: Color
}

/// Behält den nächsten Termin der kommenden 24 Stunden im Blick. Statt regelmäßig
/// nachzusehen, stellt er sich genau zwei Wecker: 10 Minuten vorher (Countdown an der
/// Notch) und 5 Minuten vorher (kurz aufklappen). Bei Kalenderänderungen, Tageswechsel
/// und nach dem Aufwachen wird neu geplant.
@MainActor
final class CalendarWatcher {
    var onUpdate: ((_ event: UpcomingEvent?, _ soon: Bool) -> Void)?
    var onReminder: (() -> Void)?

    private let store = EKEventStore()
    private var alarms: [Timer] = []

    init() {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if granted { self.reload() } } }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        alarms.forEach { $0.invalidate() }
        alarms.removeAll()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }

        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .min { $0.startDate < $1.startDate }

        guard let next else {
            onUpdate?(nil, false)
            return
        }
        let event = UpcomingEvent(title: next.title ?? "Termin", start: next.startDate,
                                  color: Color(nsColor: next.calendar.color ?? .systemRed))
        let untilStart = next.startDate.timeIntervalSince(now)
        onUpdate?(event, untilStart <= 600)

        if untilStart > 600 {
            schedule(at: next.startDate.addingTimeInterval(-600)) { self.onUpdate?(event, true) }
        }
        if untilStart > 300 {
            schedule(at: next.startDate.addingTimeInterval(-300)) { self.onReminder?() }
        }
        // Kurz nach Beginn zum nächsten Termin weiterspringen.
        schedule(at: next.startDate.addingTimeInterval(60)) { self.reload() }
    }

    private func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        alarms.append(timer)
    }
}
