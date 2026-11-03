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

    /// Die Notch gibt es auf jedem Mac: an der echten Notch und, wenn eingeschaltet, unsichtbar
    /// oben in der Mitte jedes anderen Bildschirms.
    static var isAvailable: Bool { !NSScreen.screens.isEmpty }

    private let spotify: Spotify
    private let settings: Settings
    private let volume: AppVolume
    /// Fängt das Wischen mit zwei Fingern ab, nur solange die Notch aufgeklappt ist.
    private var scrollMonitor: Any?
    private var swipeAxis = Axis?.none
    /// App, die vor dem Tippen in der Schnellnotiz den Fokus hatte.
    private var previousApp: NSRunningApplication?
    /// Letzte Fingerbewegung, für den Schwung beim Loslassen.
    private var lastSwipeDelta: CGFloat = 0
    private var panel: IslandPanel!
    private var container: IslandContainer!
    private var headphones: HeadphoneMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var peekWork: DispatchWorkItem?
    private var lastTrackID: String?
    /// Unsichtbare Notches auf den Bildschirmen ohne echte Notch.
    private var triggers: [NotchTrigger] = []
    /// Bildschirm ohne Notch, auf dem die Insel gerade aufgeklappt ist; nil, wenn sie an der echten Notch sitzt.
    private var borrowed: CGDirectDisplayID?
    /// Zählt mit, damit ein altes Ausblenden nicht zurückspringt, wenn die Maus gleich wieder da ist.
    private var fadeGeneration = 0

    private let windowSize = CGSize(width: 480, height: 470)

    /// Braucht die Notch gerade Cover bzw. Termine?
    var needsArtwork: Bool { enabled && settings.notchMusic }
    var needsCalendar: Bool { enabled && settings.notchCalendar }

    init(spotify: Spotify, system: SystemState, power: PowerMonitor, calendar: CalendarWatcher, settings: Settings,
         volume: AppVolume) {
        self.spotify = spotify
        self.settings = settings
        self.volume = volume
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
            self?.triggers.forEach { $0.acceptsFiles(on) }
        }.store(in: &cancellables)
        settings.$notchOtherScreens.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &cancellables)
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
        model.$hovering.removeDuplicates()
            .sink { [weak self] hovering in self?.hoverChanged(hovering) }
            .store(in: &cancellables)
        // Auf einem Bildschirm ohne Notch verschwindet die Insel ganz, sobald sie zuklappt.
        model.$hovering.combineLatest(model.$dragging)
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering, dragging in if !hovering && !dragging { self?.leaveBorrowedScreen() } }
            .store(in: &cancellables)
        model.$page.removeDuplicates()
            .sink { [weak self] page in self?.allowKeyboard(page == .note) }
            .store(in: &cancellables)
    }

    // MARK: Seiten

    /// Aufgeklappt: auf Wischen achten. Weggegangen: zurück auf die normale Seite.
    private func hoverChanged(_ hovering: Bool) {
        if hovering, scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Lokale Monitore laufen ohnehin auf dem Hauptthread.
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self?.handleSwipe(event) == true }
                return consumed ? nil : event
            }
        } else if !hovering {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            model.resetPage()
        }
    }

    /// Zwei Finger waagrecht drehen das Seiten-Rad live mit; beim Loslassen rastet es ein.
    /// Senkrechtes Scrollen (z. B. die Timer-Räder) geht unverändert durch.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.window === panel, event.hasPreciseScrollingDeltas, model.peek == nil else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            swipeAxis = nil
            lastSwipeDelta = 0
        }
        // Nachlauf nach dem Loslassen: gehört zur letzten Bewegung, das Einrasten übernimmt die Animation.
        if event.phase.isEmpty && !event.momentumPhase.isEmpty { return swipeAxis == .horizontal }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if swipeAxis == nil, abs(dx) + abs(dy) > 1.5 { swipeAxis = abs(dx) > abs(dy) ? .horizontal : .vertical }
        guard swipeAxis == .horizontal else { return false }
        // Richtung der Finger, egal ob „Natürliches Scrollen“ an ist (negativ = nach links).
        let finger = event.isDirectionInvertedFromDevice ? dx : -dx
        if finger != 0 {
            model.swipe(by: finger)
            lastSwipeDelta = finger
        }
        if event.phase == .ended || event.phase == .cancelled {
            model.endSwipe(flick: lastSwipeDelta)
            swipeAxis = nil
        }
        return true
    }

    /// Tippen geht nur auf der Schnellnotiz; danach bekommt die App, in der man vorher war,
    /// den Fokus direkt zurück. Das Fenster der Notch bleibt dabei sichtbar.
    private func allowKeyboard(_ on: Bool) {
        panel.allowsKeyboard = on
        if on {
            previousApp = NSWorkspace.shared.frontmostApplication
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            previousApp?.activate()
            previousApp = nil
        }
    }

    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    private func apply() {
        if enabled, Self.isAvailable {
            updateTriggers()
            // Bildschirme haben sich geändert: Die Insel geht zurück an die echte Notch.
            if borrowed != nil {
                model.hovering = false
                model.dragging = false
            }
            returnHome()
        } else {
            removeTriggers()
            panel.orderOut(nil)
            borrowed = nil
            model.hovering = false
            endPeek()
        }
        updateHeadphones()
    }

    /// Nach dem Erlauben von Bluetooth: Kopfhörer-Erkennung neu anmelden.
    func restartHeadphones() {
        headphones?.stop()
        headphones = nil
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
        let hosting = NSHostingView(rootView: IslandView(spotify: spotify, model: model, settings: settings, volume: volume))
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

    /// Größe der echten Notch; ohne MacBook-Bildschirm die übliche eines 14-Zoll-MacBook Pro.
    private static var notchSize: CGSize {
        guard let screen = notchScreen(), let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return CGSize(width: 185, height: 32) }
        return CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Fenster oben mittig über der Notch, bzw. über der Mitte eines Bildschirms ohne Notch.
    /// Die Insel ist dort genau so groß wie an der echten Notch.
    private func positionPanel(on screen: NSScreen) {
        model.notch = Self.notchSize
        var midX = screen.frame.midX
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            midX = screen.frame.minX + (left.maxX + right.minX) / 2
        }
        panel.setFrame(NSRect(x: midX - windowSize.width / 2, y: screen.frame.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: true)
        updateHotZone()
    }

    /// Zurück an die echte Notch. Ohne Bildschirm mit Notch (z. B. MacBook zugeklappt) wartet die
    /// Insel unsichtbar, bis die Maus an eine der unsichtbaren Notches kommt.
    private func returnHome() {
        borrowed = nil
        fadeGeneration += 1
        panel.alphaValue = 1
        if let screen = Self.notchScreen() {
            positionPanel(on: screen)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: Unsichtbare Notch auf anderen Bildschirmen

    private func updateTriggers() {
        removeTriggers()
        guard settings.notchOtherScreens else { return }
        let home = Self.notchScreen().flatMap(Self.displayID)
        let width = Self.notchSize.width
        for screen in NSScreen.screens {
            guard let id = Self.displayID(screen), id != home else { continue }
            let trigger = NotchTrigger(displayID: id, level: panel.level)
            trigger.acceptsFiles(settings.notchShelf)
            trigger.onEnter = { [weak self] in self?.borrow(id, dragging: false) }
            trigger.onDragEnter = { [weak self] in self?.borrow(id, dragging: true) }
            trigger.onDragExit = { [weak self] in self?.dragLeftTrigger() }
            trigger.onDrop = { [weak self] urls in self?.model.addToShelf(urls) }
            trigger.place(on: screen, width: width)
            triggers.append(trigger)
        }
    }

    private func removeTriggers() {
        triggers.forEach { $0.orderOut(nil) }
        triggers.removeAll()
    }

    /// Maus oder Datei an der unsichtbaren Notch: Die Insel zieht auf diesen Bildschirm und klappt auf.
    private func borrow(_ id: CGDirectDisplayID, dragging: Bool) {
        guard enabled, let screen = NSScreen.screens.first(where: { Self.displayID($0) == id }) else { return }
        // Schon offen (z. B. Maus kurz zurück, während sie ausblendet): nur wieder einblenden.
        if borrowed == id {
            fadeGeneration += 1
            panel.alphaValue = 1
        } else {
            guard !model.hovering, !model.dragging else { return }
            endPeek()
            fadeGeneration += 1
            borrowed = id
            positionPanel(on: screen)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        if dragging { model.dragging = true } else { model.hovering = true }
    }

    /// Eine gezogene Datei hat die unsichtbare Notch verlassen. Ist sie nicht auf der Insel
    /// angekommen, die gerade darüber aufgeklappt ist, klappt die Insel wieder zu.
    private func dragLeftTrigger() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.borrowed != nil, !self.container.dragInside else { return }
                self.model.dragging = false
            }
        }
    }

    /// Zugeklappt auf einem Bildschirm ohne Notch: sanft ausblenden, dann zurück an die echte Notch.
    private func leaveBorrowedScreen() {
        guard borrowed != nil else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.fadeGeneration, !self.model.hovering, !self.model.dragging else { return }
                self.returnHome()
            }
        })
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
        // Kurze Anzeigen nur an der echten Notch; auf anderen Bildschirmen bleibt die Notch unsichtbar.
        guard enabled, !model.hovering, !model.dragging, borrowed == nil, Self.notchScreen() != nil,
              isAllowed(kind) else { return }
        if model.page != .main { model.resetPage() }
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
