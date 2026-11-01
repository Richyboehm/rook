import AppKit
import Combine
import SwiftUI

/// Die Dynamic Island an der Notch. Jeder Bereich lässt sich in der Kommandozentrale
/// einzeln abschalten; ist die ganze Notch aus, ist ihr Fenster vom Bildschirm genommen
/// und die Kopfhörer-Erkennung abgemeldet.
@MainActor
final class NotchFeature {
    let model = IslandModel()
    var enabled = false { didSet { if enabled != oldValue { apply() } } }

    /// Gibt es überhaupt einen Bildschirm mit Notch?
    static var isAvailable: Bool { notchScreen() != nil }

    private let spotify: Spotify
    private let settings: Settings
    private var panel: IslandPanel!
    private var container: IslandContainer!
    private var headphones: HeadphoneMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var peekWork: DispatchWorkItem?
    private var lastTrackID: String?

    private let windowSize = CGSize(width: 480, height: 470)

    /// Braucht die Notch gerade Cover bzw. Termine?
    var needsArtwork: Bool { enabled && settings.notchMusic }
    var needsCalendar: Bool { enabled && settings.notchCalendar }

    init(spotify: Spotify, system: SystemState, power: PowerMonitor, calendar: CalendarWatcher, settings: Settings) {
        self.spotify = spotify
        self.settings = settings
        makePanel()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }

        system.unlocked.sink { [weak self] in self?.peek(.unlocked) }.store(in: &cancellables)
        power.$state.sink { [weak self] state in self?.model.battery = state }.store(in: &cancellables)
        power.pluggedIn.sink { [weak self] in self?.peek(.charging) }.store(in: &cancellables)

        calendar.$nextEvent.combineLatest(calendar.$soon)
            .sink { [weak self] event, soon in
                guard let self else { return }
                if self.model.nextEvent != event { self.model.nextEvent = event }
                if self.model.meetingSoon != soon { self.model.meetingSoon = soon }
            }
            .store(in: &cancellables)
        calendar.reminder.sink { [weak self] in self?.peek(.meeting) }.store(in: &cancellables)

        settings.$notchHeadphones.sink { [weak self] _ in DispatchQueue.main.async { self?.updateHeadphones() } }
            .store(in: &cancellables)
        settings.$notchShelf.sink { [weak self] on in
            if on { self?.container.registerForDraggedTypes([.fileURL]) } else { self?.container.unregisterDraggedTypes() }
        }.store(in: &cancellables)
        settings.$notchTimer.sink { [weak self] on in if !on { self?.model.stopTimer() } }.store(in: &cancellables)

        Screenshots.cleanUp()
        model.onCapture = { [weak self] mode in
            guard let self else { return }
            // Erst zuklappen, damit die Insel nicht mit aufs Bild kommt.
            self.model.hovering = false
            self.endPeek()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Screenshots.capture(mode) { [weak self] file in
                    guard let self else { return }
                    if self.settings.notchShelf { self.model.addToShelf([file], atFront: true) }
                    self.peek(.screenshot(file))
                }
            }
        }
        model.onTimerDone = { [weak self] in
            NSSound(named: "Glass")?.play()
            self?.peek(.timerDone)
        }

        // Neuer Song: kurz aufklappen, wie beim iPhone.
        spotify.$track
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                guard let self, let id = track?.id, id != self.lastTrackID else { return }
                let isFirst = self.lastTrackID == nil
                self.lastTrackID = id
                if !isFirst && self.spotify.isPlaying { self.peek(.track) }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest3(model.$hovering, model.$dragging, model.$expandedHeight)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHotZone() }
            .store(in: &cancellables)
    }

    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    private func apply() {
        if enabled, Self.isAvailable {
            positionPanel()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            model.hovering = false
            endPeek()
        }
        updateHeadphones()
    }

    private func updateHeadphones() {
        let wanted = enabled && settings.notchHeadphones
        if wanted && headphones == nil {
            headphones = HeadphoneMonitor()
            headphones?.onConnect = { [weak self] device in self?.peek(.headphones(device)) }
        } else if !wanted, let monitor = headphones {
            monitor.stop()
            headphones = nil
        }
    }

    private func makePanel() {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: windowSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        container = IslandContainer(frame: NSRect(origin: .zero, size: windowSize))
        let hosting = NSHostingView(rootView: IslandView(spotify: spotify, model: model, settings: settings))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onHoverChange = { [weak self] inside in
            guard let self, self.model.hovering != inside else { return }
            self.model.hovering = inside
            if inside { self.endPeek() }
        }
        container.onDragChange = { [weak self] active in
            guard let self, self.model.dragging != active else { return }
            self.model.dragging = active
            if active { self.endPeek() }
        }
        container.onDrop = { [weak self] urls in self?.model.addToShelf(urls) }
        panel.contentView = container
    }

    /// Fenster oben mittig über der Notch.
    private func positionPanel() {
        guard let screen = Self.notchScreen(), let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return }
        let notchWidth = right.minX - left.maxX
        model.notch = CGSize(width: notchWidth, height: screen.safeAreaInsets.top)
        let midX = screen.frame.minX + left.maxX + notchWidth / 2
        panel.setFrame(NSRect(x: midX - windowSize.width / 2, y: screen.frame.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: true)
        updateHotZone()
    }

    private func updateHotZone() {
        guard let container else { return }
        let size = model.hovering || model.dragging
            ? CGSize(width: IslandModel.expandedWidth, height: model.expandedHeight)
            : CGSize(width: model.compactWidth, height: model.notch.height)
        container.hotZone = NSRect(x: (windowSize.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }

    /// Nur einblenden, wenn die Notch an ist und der jeweilige Bereich eingeschaltet.
    private func peek(_ kind: IslandModel.Peek) {
        guard enabled, !model.hovering, !model.dragging, isAllowed(kind) else { return }
        model.peek = kind
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPeek() }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + kind.duration, execute: work)
    }

    private func isAllowed(_ kind: IslandModel.Peek) -> Bool {
        switch kind {
        case .track: settings.notchMusic
        case .meeting: settings.notchCalendar
        case .timerDone: settings.notchTimer
        case .screenshot: settings.notchScreenshots
        case .charging: settings.notchCharging
        case .unlocked: settings.notchUnlock
        case .headphones: settings.notchHeadphones
        }
    }

    private func endPeek() {
        peekWork?.cancel()
        peekWork = nil
        if model.peek != nil { model.peek = nil }
    }
}
