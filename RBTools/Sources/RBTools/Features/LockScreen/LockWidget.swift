import AppKit
import Combine
import SwiftUI

/// Rahmenloses Fenster, das nie den Fokus stiehlt.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Glas-Widgets auf dem Sperrbildschirm: Musik (solange ein Song läuft), nächster Termin,
/// Wetter, Akku & AirPods. Ist der Mac entsperrt, ist das Fenster ganz vom Bildschirm
/// genommen. Wetter und AirPods werden nur beim Sperren nachgesehen.
@MainActor
final class LockWidget {
    let layout = WidgetLayout()
    var enabled = false { didSet { if enabled != oldValue { update() } } }
    /// StandBy zeigt die Musik selbst an; dann bleibt das Widget weg.
    var suppressed = false { didSet { if suppressed != oldValue { update() } } }
    /// Zum Ausprobieren auf dem Schreibtisch; endet beim nächsten Entsperren.
    var preview = false {
        didSet {
            guard preview != oldValue else { return }
            if preview { refreshOnShow() }
            update()
        }
    }

    private let spotify: Spotify
    private let system: SystemState
    private let settings: Settings
    private let weather: WeatherService
    private var panel: WidgetPanel!
    private var visible = false
    /// Die Musik-Karte bleibt nach dem Pausieren noch kurz stehen.
    private var musicGrace: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Freier Bereich des Sperrbildschirms zwischen Uhr und Benutzerfeld,
    /// als Anteil der Bildschirmhöhe von oben gemessen.
    private let freeAreaTop: CGFloat = 0.30
    private let freeAreaBottom: CGFloat = 0.78

    init(spotify: Spotify, system: SystemState, settings: Settings, power: PowerMonitor,
         calendar: CalendarWatcher, weather: WeatherService) {
        self.spotify = spotify
        self.system = system
        self.settings = settings
        self.weather = weather
        makePanel()

        settings.$lockWidgetPlacement
            .sink { [weak self] placement in self?.layout.placement = placement }
            .store(in: &cancellables)
        system.$isLocked
            .dropFirst()
            .sink { [weak self] locked in
                if !locked { self?.preview = false }
                if locked { self?.refreshOnShow() }
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        power.$state.sink { [weak self] state in self?.layout.battery = state }.store(in: &cancellables)
        calendar.$nextEvent.sink { [weak self] event in
            self?.layout.event = event
            DispatchQueue.main.async { self?.update() }
        }.store(in: &cancellables)
        weather.$current.sink { [weak self] now in
            self?.layout.weather = now
            DispatchQueue.main.async { self?.update() }
        }.store(in: &cancellables)
        system.$screensAsleep
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateTicking() } }
            .store(in: &cancellables)
        spotify.$isPlaying.combineLatest(spotify.$track)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    /// Wird das Musik-Widget gerade gebraucht (für das Laden der Cover)?
    var needsArtwork: Bool { enabled && settings.widgetMusic && (system.isLocked || preview) }
    /// Braucht das Termin-Widget den Kalender?
    var needsCalendar: Bool { enabled && settings.widgetEvent }

    /// Wetter und AirPods nur nachsehen, wenn die Widgets gleich zu sehen sind.
    private func refreshOnShow() {
        guard enabled else { return }
        if settings.widgetWeather { weather.refreshIfNeeded(place: settings.weatherPlace) }
        if settings.widgetBattery { layout.headphones = HeadphoneMonitor.connected() }
    }

    private func makePanel() {
        panel = WidgetPanel(contentRect: NSRect(origin: .zero, size: layout.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.canBecomeVisibleWithoutLogin = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: WidgetView(spotify: spotify, layout: layout))
        panel.alphaValue = 0
        positionPanel()
    }

    /// Das Fenster deckt den freien Bereich zwischen Uhr und Benutzerfeld ab;
    /// darin sitzt die kleine Karte oben, mittig oder unten, die große immer mittig.
    private func positionPanel() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.frame
        let top = frame.maxY - frame.height * freeAreaTop
        let bottom = frame.maxY - frame.height * freeAreaBottom
        let size = CGSize(width: 480, height: top - bottom)
        if layout.canvas != size { layout.canvas = size }
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: bottom, width: size.width, height: size.height), display: true)
    }

    private func updateTicking() {
        let ticking = visible && spotify.isPlaying && !system.screensAsleep
        if layout.ticking != ticking { layout.ticking = ticking }
    }

    private func update() {
        defer { updateTicking() }
        let shown = enabled && (system.isLocked || preview) && !suppressed

        // Musik: solange ein Song läuft, nach dem Pausieren noch 5 Sekunden zum Weiterspielen.
        let playing = settings.widgetMusic && spotify.track != nil && spotify.isPlaying
        if playing {
            musicGrace?.cancel()
            musicGrace = nil
            setFlag(\.showMusic, true)
        } else if layout.showMusic && settings.widgetMusic && spotify.track != nil {
            if musicGrace == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.musicGrace = nil
                        self?.layout.showMusic = false
                        self?.update()
                    }
                }
                musicGrace = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }
        } else {
            musicGrace?.cancel()
            musicGrace = nil
            setFlag(\.showMusic, false)
        }
        setFlag(\.showEvent, settings.widgetEvent)
        setFlag(\.showWeather, settings.widgetWeather)
        setFlag(\.showBattery, settings.widgetBattery)

        setVisible(shown && (layout.showMusic || layout.hasInfo))
    }

    private func setFlag(_ path: ReferenceWritableKeyPath<WidgetLayout, Bool>, _ value: Bool) {
        if layout[keyPath: path] != value { layout[keyPath: path] = value }
    }

    private func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        Log.write("Widgets \(show ? "eingeblendet" : "ausgeblendet")")
        if show {
            positionPanel()
            panel.orderFrontRegardless()
            SkyLight.moveAboveLockScreen(panel)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
