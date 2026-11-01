import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Rahmenloses Fenster, das nie den Fokus stiehlt.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hält die SwiftUI-Insel und erkennt die Maus über eine Tracking-Area: Eintreten zählt
/// nur direkt an der Notch, Verlassen erst außerhalb der großen Insel. Das System
/// meldet nur Ein- und Austritt, es wird keine Mausbewegung mitverfolgt.
/// Außerdem nimmt es Dateien an, die auf die Notch gezogen werden.
final class IslandContainer: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onDragChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var hotZone: NSRect = .zero { didSet { if hotZone != oldValue { updateTrackingAreas() } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: hotZone, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragChange?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        onDragChange?(false)
        return !urls.isEmpty
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotify = Spotify()
    private let model = IslandModel()
    private let power = PowerMonitor()
    private var headphones: HeadphoneMonitor?
    private var calendar: CalendarWatcher?
    private var panel: IslandPanel!
    private var container: IslandContainer!
    private var cancellables = Set<AnyCancellable>()
    private var peekWork: DispatchWorkItem?
    private var lastTrackID: String?

    private let windowSize = CGSize(width: 480, height: 470)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard notchScreen() != nil else {
            let alert = NSAlert()
            alert.messageText = "Kein Bildschirm mit Notch gefunden"
            alert.informativeText = "Notch Island braucht den eingebauten Bildschirm eines MacBooks mit Notch."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        makePanel()
        positionPanel()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }
        NotificationCenter.default.addObserver(forName: .toggleLoginItem, object: nil, queue: .main) { _ in
            let service = SMAppService.mainApp
            if service.status == .enabled { try? service.unregister() } else { try? service.register() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.peek(.unlocked) }
        }

        model.battery = power.state
        power.onChange = { [weak self] state, pluggedIn in
            guard let self else { return }
            self.model.battery = state
            if pluggedIn { self.peek(.charging) }
        }

        headphones = HeadphoneMonitor()
        headphones?.onConnect = { [weak self] device in self?.peek(.headphones(device)) }

        calendar = CalendarWatcher()
        calendar?.onUpdate = { [weak self] event, soon in
            guard let self else { return }
            if self.model.nextEvent != event { self.model.nextEvent = event }
            if self.model.meetingSoon != soon { self.model.meetingSoon = soon }
        }
        calendar?.onReminder = { [weak self] in self?.peek(.meeting) }

        Screenshots.cleanUp()
        model.onCapture = { [weak self] mode in
            guard let self else { return }
            // Erst zuklappen, damit die Insel nicht mit aufs Bild kommt.
            self.model.hovering = false
            self.endPeek()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Screenshots.capture(mode) { [weak self] file in
                    self?.model.addToShelf([file], atFront: true)
                    self?.peek(.screenshot(file))
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

        spotify.needsArtwork = true
        spotify.query()
    }

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
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
        let hosting = NSHostingView(rootView: IslandView(spotify: spotify, model: model))
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
        panel.orderFrontRegardless()
    }

    /// Fenster oben mittig über der Notch.
    private func positionPanel() {
        guard let screen = notchScreen(), let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return }
        let notchWidth = right.minX - left.maxX
        let notchHeight = screen.safeAreaInsets.top
        model.notch = CGSize(width: notchWidth, height: notchHeight)
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

    private func peek(_ kind: IslandModel.Peek) {
        guard !model.hovering, !model.dragging else { return }
        model.peek = kind
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPeek() }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + kind.duration, execute: work)
    }

    private func endPeek() {
        peekWork?.cancel()
        peekWork = nil
        if model.peek != nil { model.peek = nil }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
