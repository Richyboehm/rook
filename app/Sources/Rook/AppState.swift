import AppKit
import Combine

/// Verbindet die Schalter der Kommandozentrale mit den Funktionen. Jede Funktion wird
/// erst erzeugt bzw. gestartet, wenn sie eingeschaltet ist, und beim Ausschalten wieder
/// komplett angehalten.
@MainActor
final class AppState {
    static let shared = AppState()

    let settings = Settings.shared
    let system = SystemState()
    let power = PowerMonitor()
    let calendar = CalendarWatcher()
    let spotify = Spotify()
    let permissions = Permissions()
    let windowFetcher = WindowFetcher()
    let dockToggle = DockToggle()
    let mouseWheel = MouseWheel()
    let volume = AppVolume()
    let resources = ResourceMonitor()
    let rookSearch = RookSearch()
    let updater = Updater()
    let downloads = DownloadsCleaner()
    let weather = WeatherService()

    private(set) lazy var lockWidget = LockWidget(spotify: spotify, system: system, settings: settings, power: power,
                                                  calendar: calendar, weather: weather)
    private(set) lazy var standBy = StandByController(spotify: spotify)
    private(set) lazy var notch = NotchFeature(spotify: spotify, system: system, power: power,
                                               calendar: calendar, settings: settings, volume: volume)

    private var cancellables = Set<AnyCancellable>()

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { ResourceMonitor.recordBaseline() }
        settings.$debugLog
            .sink { on in Log.enabled = on || CommandLine.arguments.contains("--debug") }
            .store(in: &cancellables)

        // Widgets auf dem Sperrbildschirm
        settings.$lockWidget.sink { [weak self] on in self?.lockWidget.enabled = on }.store(in: &cancellables)

        // StandBy
        standBy.onVisibilityChange = { [weak self] in
            guard let self else { return }
            self.lockWidget.suppressed = self.standBy.visible
            self.updateNeeds()
        }
        settings.$standBy.sink { [weak self] on in self?.standBy.enabled = on }.store(in: &cancellables)
        settings.$standByAutoLock.sink { [weak self] on in self?.standBy.autoLock = on }.store(in: &cancellables)
        settings.$standByNightMode.sink { [weak self] on in self?.standBy.model.nightMode = on }.store(in: &cancellables)
        system.$isLocked.sink { [weak self] locked in self?.standBy.setLocked(locked) }.store(in: &cancellables)
        power.$state.sink { [weak self] state in self?.standBy.setBattery(state) }.store(in: &cancellables)
        calendar.$nextEvent.sink { [weak self] event in
            guard let self, self.standBy.model.nextEvent != event else { return }
            self.standBy.model.nextEvent = event
        }.store(in: &cancellables)

        // Notch
        settings.$notch.sink { [weak self] on in self?.notch.enabled = on }.store(in: &cancellables)

        // Fensterholer
        settings.$dockToggle.sink { [weak self] on in
            if on { self?.dockToggle.start() } else { self?.dockToggle.stop() }
        }.store(in: &cancellables)
        settings.$windowFetcher.sink { [weak self] on in
            if on { self?.windowFetcher.start() } else { self?.windowFetcher.stop() }
        }.store(in: &cancellables)

        // Mausrad
        settings.$mouseReverseScroll.sink { [weak self] on in self?.mouseWheel.reverseScroll = on }.store(in: &cancellables)
        settings.$mouseReverseZoom.sink { [weak self] on in self?.mouseWheel.reverseZoom = on }.store(in: &cancellables)
        settings.$mouseReverseHorizontal.sink { [weak self] on in self?.mouseWheel.reverseHorizontal = on }
            .store(in: &cancellables)
        settings.$mouseWheel.sink { [weak self] on in
            if on { self?.mouseWheel.start() } else { self?.mouseWheel.stop() }
        }.store(in: &cancellables)

        // Lautstärke pro App
        settings.$appVolume.sink { [weak self] on in self?.volume.enabled = on }.store(in: &cancellables)

        // Wird eine Funktion eingeschaltet, die eine Erlaubnis braucht, gleich einmal fragen.
        // Beim Start selbst wird nie gefragt (dropFirst), nur bei bewusstem Einschalten.
        let asks: [(Published<Bool>.Publisher, Permissions.Kind)] = [
            (settings.$windowFetcher, .accessibility), (settings.$dockToggle, .accessibility),
            (settings.$mouseWheel, .accessibility), (settings.$appVolume, .audioCapture),
            (settings.$widgetEvent, .calendar), (settings.$notchCalendar, .calendar),
            (settings.$widgetBattery, .bluetooth), (settings.$notchHeadphones, .bluetooth),
        ]
        for (publisher, kind) in asks {
            publisher.dropFirst().removeDuplicates().filter { $0 }
                .sink { [weak self] _ in self?.permissions.requestIfNeeded(kind) }
                .store(in: &cancellables)
        }
        // Kommt eine Erlaubnis dazu, die betroffenen Teile ohne Neustart nachladen.
        permissions.$status
            .map { ($0[.calendar] == .granted, $0[.bluetooth] == .granted) }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] calendar, bluetooth in
                if calendar { self?.calendar.reload() }
                if bluetooth { self?.notch.restartHeadphones() }
            }
            .store(in: &cancellables)

        // Downloads
        settings.$downloadsTrashInstallers.sink { [weak self] on in self?.downloads.trashOldInstallers = on }
            .store(in: &cancellables)
        settings.$downloadsCleaner.sink { [weak self] on in
            if on {
                UserDefaults.standard.set(true, forKey: "downloadsAccessAsked")
                self?.downloads.start()
            } else {
                self?.downloads.stop()
            }
        }.store(in: &cancellables)

        // Rook Search: Wurde der Browser von Hand gelöscht, ist die Funktion aus. Sonst beim Start
        // auf die Version bringen, die in diesem Rook steckt; beim Umschalten ablegen oder wegräumen.
        if settings.rookSearch && !rookSearch.isInstalled { settings.rookSearch = false }
        if settings.rookSearch { rookSearch.updateIfNeeded() }
        settings.$rookSearch.dropFirst().removeDuplicates().sink { [weak self] on in
            if on { self?.rookSearch.place() } else { self?.rookSearch.remove() }
        }.store(in: &cancellables)
        updater.start()

        // Was gerade gebraucht wird (Cover laden, Kalender beobachten), hängt von vielen
        // Schaltern ab; nach jeder Änderung einmal neu bestimmen.
        settings.objectWillChange.merge(with: system.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateNeeds() }
            .store(in: &cancellables)
        updateNeeds()

        // Einmal den aktuellen Spotify-Stand holen; danach kommt alles als Meldung.
        if settings.lockWidget || settings.standBy || settings.notchMusic { spotify.query() }
    }

    private func updateNeeds() {
        let artwork = lockWidget.needsArtwork || notch.needsArtwork || (settings.standBy && system.isLocked)
        if spotify.needsArtwork != artwork { spotify.needsArtwork = artwork }
        if notch.needsCalendar || lockWidget.needsCalendar || settings.standBy { calendar.start() }
    }
}
