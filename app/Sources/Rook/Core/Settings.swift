import Foundation
import ServiceManagement

enum Placement: String, CaseIterable {
    case top = "Oben", middle = "Mitte", bottom = "Unten"
}

/// Alle Schalter der Kommandozentrale an einer Stelle. Jede Änderung wird sofort
/// gespeichert; die Funktionen hören auf diese Werte und schalten sich live an oder aus.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private static let defaults = UserDefaults.standard

    private static func load<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    // MARK: Widgets (Sperrbildschirm)

    @Published var lockWidget: Bool = load("lockWidget", true) { didSet { save("lockWidget", lockWidget) } }
    @Published var widgetMusic: Bool = load("widgetMusic", true) { didSet { save("widgetMusic", widgetMusic) } }
    @Published var widgetEvent: Bool = load("widgetEvent", false) { didSet { save("widgetEvent", widgetEvent) } }
    @Published var widgetWeather: Bool = load("widgetWeather", false) { didSet { save("widgetWeather", widgetWeather) } }
    @Published var widgetBattery: Bool = load("widgetBattery", false) { didSet { save("widgetBattery", widgetBattery) } }
    @Published var weatherPlace: String = load("weatherPlace", "") { didSet { save("weatherPlace", weatherPlace) } }
    @Published var lockWidgetPlacement: Placement =
        Placement(rawValue: load("lockWidgetPlacement", "")) ?? .middle {
        didSet { save("lockWidgetPlacement", lockWidgetPlacement.rawValue) }
    }

    // MARK: StandBy

    @Published var standBy: Bool = load("standBy", true) { didSet { save("standBy", standBy) } }
    @Published var standByAutoLock: Bool = load("standByAutoLock", true) { didSet { save("standByAutoLock", standByAutoLock) } }
    @Published var standByNightMode: Bool = load("standByNightMode", true) { didSet { save("standByNightMode", standByNightMode) } }

    // MARK: Notch

    @Published var notch: Bool = load("notch", true) { didSet { save("notch", notch) } }
    @Published var notchMusic: Bool = load("notchMusic", true) { didSet { save("notchMusic", notchMusic) } }
    @Published var notchCoverColors: Bool = load("notchCoverColors", true) { didSet { save("notchCoverColors", notchCoverColors) } }
    @Published var notchScreenshots: Bool = load("notchScreenshots", true) { didSet { save("notchScreenshots", notchScreenshots) } }
    @Published var notchShelf: Bool = load("notchShelf", true) { didSet { save("notchShelf", notchShelf) } }
    @Published var notchCalendar: Bool = load("notchCalendar", true) { didSet { save("notchCalendar", notchCalendar) } }
    @Published var notchTimer: Bool = load("notchTimer", true) { didSet { save("notchTimer", notchTimer) } }
    @Published var notchHeadphones: Bool = load("notchHeadphones", true) { didSet { save("notchHeadphones", notchHeadphones) } }
    @Published var notchCharging: Bool = load("notchCharging", true) { didSet { save("notchCharging", notchCharging) } }
    @Published var notchUnlock: Bool = load("notchUnlock", true) { didSet { save("notchUnlock", notchUnlock) } }

    // MARK: Fenster

    /// Braucht die Erlaubnis „Bedienungshilfen“, deshalb erst nach bewusstem Einschalten.
    @Published var windowFetcher: Bool = load("windowFetcher", false) { didSet { save("windowFetcher", windowFetcher) } }
    /// Dock wie unter Windows (verändert das Verhalten, deshalb erst nach bewusstem Einschalten).
    @Published var dockToggle: Bool = load("dockToggle", false) { didSet { save("dockToggle", dockToggle) } }

    // MARK: Mausrad (verändert Eingaben, deshalb erst nach bewusstem Einschalten)

    @Published var mouseWheel: Bool = load("mouseWheel", false) { didSet { save("mouseWheel", mouseWheel) } }
    @Published var mouseReverseScroll: Bool = load("mouseReverseScroll", true) { didSet { save("mouseReverseScroll", mouseReverseScroll) } }
    @Published var mouseReverseZoom: Bool = load("mouseReverseZoom", true) { didSet { save("mouseReverseZoom", mouseReverseZoom) } }
    @Published var mouseReverseHorizontal: Bool = load("mouseReverseHorizontal", true) {
        didSet { save("mouseReverseHorizontal", mouseReverseHorizontal) }
    }

    // MARK: Lautstärke pro App (verändert den Ton, deshalb erst nach bewusstem Einschalten)

    @Published var appVolume: Bool = load("appVolume", false) { didSet { save("appVolume", appVolume) } }

    // MARK: Downloads (verschiebt Dateien, deshalb erst nach bewusstem Einschalten)

    @Published var downloadsCleaner: Bool = load("downloadsCleaner", false) { didSet { save("downloadsCleaner", downloadsCleaner) } }
    @Published var downloadsTrashInstallers: Bool = load("downloadsTrashInstallers", true) {
        didSet { save("downloadsTrashInstallers", downloadsTrashInstallers) }
    }

    // MARK: Allgemein

    @Published var debugLog: Bool = load("debugLog", false) { didSet { save("debugLog", debugLog) } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    /// Wurde die Kommandozentrale schon einmal gezeigt? Beim ersten Start öffnet sie sich von selbst.
    var hasOnboarded: Bool {
        get { Self.defaults.bool(forKey: "hasOnboarded") }
        set { Self.defaults.set(newValue, forKey: "hasOnboarded") }
    }

    private func save(_ key: String, _ value: Any) { Self.defaults.set(value, forKey: key) }
}
