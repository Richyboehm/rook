import AppKit
import SwiftUI

/// Das Fenster unter dem Raben in der Menüleiste. Ein eigenes, dunkles Fenster mit der
/// klassischen Unschärfe statt des Glas-Popovers von macOS 26: Dessen Glas belegt beim Öffnen
/// und bei jeder Größenänderung kurz rund 70 MB Grafikspeicher. Die Unschärfe hier zeichnet
/// das System selbst, Rook kostet sie nichts.
/// Schließt sich bei Klick daneben, mit Esc oder bei erneutem Klick auf den Raben.
@MainActor
final class MenuBarPanel: NSObject {
    var onClose: (() -> Void)?
    private let intro = IntroTrigger()
    private let state: AppState
    private let openSettings: (Feature?) -> Void
    /// Wird bei jedem Öffnen neu gebaut und beim Schließen freigegeben.
    private var window: MenuBarWindow?
    private var outsideClicks: Any?
    private var closedAt = Date.distantPast

    init(state: AppState, openSettings: @escaping (Feature?) -> Void) {
        self.state = state
        self.openSettings = openSettings
        super.init()
    }

    /// Offen oder gerade eben geschlossen: Der Klick auf den Raben, der das Fenster (als Klick
    /// daneben) schon geschlossen hat, soll es nicht gleich wieder öffnen.
    var isVisible: Bool { window?.isVisible == true || Date().timeIntervalSince(closedAt) < 0.3 }

    func show(below button: NSStatusBarButton) {
        guard window == nil, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        intro.count += 1
        state.resources.windowOpened()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let window = MenuBarWindow(content: makeView())
        window.onCancel = { [weak self] in self?.close() }
        window.onResign = { [weak self] in self?.close() }
        window.place(below: anchor, on: screen)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        window.onResign = nil
        window.orderOut(nil)
        window.contentView = nil
        closedAt = Date()
        ResourceMonitor.windowClosed()
        Memory.relieve()
        onClose?()
    }

    private func makeView() -> some View {
        MenuBarView(settings: state.settings, permissions: state.permissions, downloads: state.downloads,
                    intro: intro, rookSearch: state.rookSearch, updater: state.updater, state: state,
                    openSettings: { [weak self] feature in self?.close(); self?.openSettings(feature) },
                    close: { [weak self] in self?.close() })
    }
}

/// Rahmenloses, dunkles Fenster mit runden Ecken und Schatten. Es wächst und schrumpft mit
/// dem Inhalt (z. B. beim Wechsel der Funktion), die Oberkante bleibt unter der Menüleiste.
final class MenuBarWindow: NSPanel {
    var onCancel: (() -> Void)?
    var onResign: (() -> Void)?

    init<Content: View>(content: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        let host = NSHostingView(rootView: content.onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
            self?.fit(size)
        })
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }

    /// Mittig unter dem Raben, aber immer ganz auf dem Bildschirm.
    func place(below anchor: NSRect, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(NSPoint(x: x, y: anchor.minY - 6 - size.height))
    }

    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }
}

/// Zählt jedes Öffnen mit, damit der Rabe oben seine kurze Animation jedes Mal abspielt.
@MainActor
final class IntroTrigger: ObservableObject {
    @Published var count = 0
}

/// Aufbau wie bei Vorssaint: oben der Rabe, darunter eine Leiste mit allen Funktionen,
/// darunter eine Karte mit den Schaltern der gewählten Funktion, unten Einstellungen und Beenden.
/// Bewusst ruhig: dunkel, kleine Schrift, graue Flächen, Blau nur für Auswahl und Schalter.
struct MenuBarView: View {
    /// Das Blau von macOS, unabhängig von der Akzentfarbe in den Systemeinstellungen.
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 1)

    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions
    @ObservedObject var downloads: DownloadsCleaner
    @ObservedObject var intro: IntroTrigger
    @ObservedObject var rookSearch: RookSearch
    @ObservedObject var updater: Updater
    let state: AppState
    let openSettings: (Feature?) -> Void
    let close: () -> Void

    @AppStorage("menuBarTab") private var selectedRaw = Feature.lockWidget.rawValue
    /// Reihenfolge der Leiste, per Ziehen änderbar; neue Tabs kommen hinten dazu.
    @AppStorage("menuBarOrder") private var orderRaw = ""
    /// Laufendes Umsortieren: welcher Tab gezogen wird und wie weit.
    @State private var drag: TabDrag?
    /// Nach dem Loslassen: Rest-Abstand des Tabs zu seinem neuen Platz, gleitet auf 0.
    @State private var settling: (tab: MenuTab, offset: CGFloat)?
    @State private var barWidth: CGFloat = 0
    /// Die Vorschau der Widgets meldet keine Änderungen; nach dem Umschalten neu zeichnen.
    @State private var widgetPreview = false
    @State private var notchExtras = false

    private var tabs: [MenuTab] {
        let available = Feature.allCases.filter { $0 != .notch || NotchFeature.isAvailable }.map(MenuTab.feature) + [.performance]
        let stored = orderRaw.split(separator: ",").compactMap { MenuTab(id: String($0)) }.filter(available.contains)
        return stored + available.filter { !stored.contains($0) }
    }
    private var selected: MenuTab {
        MenuTab(id: selectedRaw).flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
    }

    var body: some View {
        VStack(spacing: 12) {
            RavenIntro(trigger: intro.count)
            tabBar
            VStack(alignment: .leading, spacing: 8) {
                Text(selected.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                switch selected {
                case .feature(let feature): card(for: feature)
                case .performance: PerformanceCard(monitor: state.resources, settings: settings)
                }
            }
            HStack(spacing: 8) {
                if updater.updateAvailable || updater.isBusy {
                    FooterButton(title: updater.isBusy ? "Lädt …" : "Update", symbol: "arrow.down.circle") {
                        if !updater.isBusy { updater.install() }
                    }
                }
                FooterButton(title: "Einstellungen", symbol: "gearshape") { openSettings(selected.feature) }
                FooterButton(title: "Beenden", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 332)
        .fixedSize(horizontal: false, vertical: true)
        // Etwas dunkler als das normale Popover, damit es fast schwarz wirkt.
        .background(Color.black.opacity(0.3))
        .tint(Self.accent)
        .onAppear {
            permissions.refresh()
            widgetPreview = state.lockWidget.preview
        }
    }

    private static let tabSpacing: CGFloat = 2

    /// Klick wählt einen Tab. Ziehen sortiert um wie auf dem iPhone-Homescreen: Während des
    /// Ziehens bleibt die Leiste selbst stehen, nur der gezogene Tab folgt dem Zeiger 1:1 und
    /// die anderen rutschen zur Seite. Erst beim Loslassen wird die Reihenfolge gespeichert.
    private var tabBar: some View {
        HStack(spacing: Self.tabSpacing) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                let isSelected = tab == selected
                let isDragged = drag?.tab == tab
                Image(systemName: tab.symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(MenuBarView.accent) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: 27)
                    .background(isSelected ? MenuBarView.accent.opacity(0.2) : isDragged ? .primary.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .scaleEffect(isDragged ? 1.12 : 1)
                    .shadow(color: .black.opacity(isDragged ? 0.4 : 0), radius: 6, y: 2)
                    .animation(.easeOut(duration: 0.15), value: isDragged)
                    // Der gezogene Tab ohne Verzögerung, die anderen weich.
                    .offset(x: offset(for: tab, at: index))
                    .animation(isDragged ? nil : .snappy(duration: 0.2), value: drag?.target)
                    .zIndex(isDragged || settling?.tab == tab ? 1 : 0)
                    .onTapGesture { selectedRaw = tab.id }
                    // Gemessen an der Leiste, die stillsteht, nicht am Tab, der sich bewegt.
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("tabBar"))
                        .onChanged { value in moveTab(tab, from: index, by: value.translation.width) }
                        .onEnded { _ in endDrag() })
                    .help("\(tab.title) · zum Umsortieren ziehen")
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .coordinateSpace(.named("tabBar"))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidth = $0 }
        .padding(4)
        .surface(cornerRadius: 12)
    }

    /// Abstand von einem Platz zum nächsten.
    private var slotWidth: CGFloat {
        (barWidth + Self.tabSpacing) / CGFloat(max(tabs.count, 1))
    }

    private func offset(for tab: MenuTab, at index: Int) -> CGFloat {
        if let settling, settling.tab == tab { return settling.offset }
        guard let drag else { return 0 }
        if drag.tab == tab { return drag.translation }
        // Tabs zwischen altem und neuem Platz weichen um einen Platz aus.
        if drag.start < drag.target, index > drag.start, index <= drag.target { return -slotWidth }
        if drag.target < drag.start, index >= drag.target, index < drag.start { return slotWidth }
        return 0
    }

    private func moveTab(_ tab: MenuTab, from index: Int, by translation: CGFloat) {
        let target = min(max(index + Int((translation / max(slotWidth, 1)).rounded()), 0), tabs.count - 1)
        drag = TabDrag(tab: tab, start: index, target: target, translation: translation)
    }

    /// Reihenfolge speichern; der Tab gleitet vom Zeiger auf seinen neuen Platz.
    private func endDrag() {
        guard let drag else { return }
        var order = tabs
        order.remove(at: drag.start)
        order.insert(drag.tab, at: drag.target)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            orderRaw = order.map(\.id).joined(separator: ",")
            settling = (drag.tab, drag.translation - CGFloat(drag.target - drag.start) * slotWidth)
            self.drag = nil
        }
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.22)) { settling = nil }
        }
    }

    // MARK: Karte der gewählten Funktion

    private func card(for feature: Feature) -> some View {
        let isOn = feature.isOn(settings)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(feature.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Toggle(feature.title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            if isOn.wrappedValue, let needed = feature.requiredPermission, permissions.status[needed] != .granted {
                permissionHint(needed)
            }
            VStack(alignment: .leading, spacing: 10) { options(for: feature) }
                .disabled(!isOn.wrappedValue)
                .opacity(isOn.wrappedValue ? 1 : 0.4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 10)
    }

    private func permissionHint(_ kind: Permissions.Kind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Erlaubnis fehlt: \(kind.title)").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Pill(title: "Erlauben") {
                if permissions.status[kind] == .denied { permissions.openSettings(kind) } else { permissions.request(kind) }
            }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private func options(for feature: Feature) -> some View {
        switch feature {
        case .lockWidget:
            Divider()
            OptionRow(title: "Musik", isOn: $settings.widgetMusic)
            OptionRow(title: "Nächster Termin", isOn: $settings.widgetEvent)
            OptionRow(title: "Wetter", isOn: $settings.widgetWeather)
            OptionRow(title: "Akku & AirPods", isOn: $settings.widgetBattery)
            Divider()
            HStack(spacing: 6) {
                Text("Position").font(.system(size: 12))
                Spacer(minLength: 0)
                ForEach(Placement.allCases, id: \.self) { place in
                    Pill(title: place.rawValue, isSelected: settings.lockWidgetPlacement == place) {
                        settings.lockWidgetPlacement = place
                    }
                }
            }
            Pill(title: widgetPreview ? "Vorschau beenden" : "Vorschau auf dem Schreibtisch", symbol: "eye", wide: true) {
                state.lockWidget.preview.toggle()
                widgetPreview = state.lockWidget.preview
            }
        case .standBy:
            Divider()
            OptionRow(title: "Am Netzteil automatisch sperren", caption: "Nach 5 Minuten ohne Eingabe",
                      isOn: $settings.standByAutoLock)
            OptionRow(title: "Nachtmodus", caption: "Von 22 bis 7 Uhr rot und gedimmt", isOn: $settings.standByNightMode)
            Pill(title: "StandBy ansehen", symbol: "play", wide: true) {
                close()
                state.standBy.preview()
            }
        case .notch:
            Divider()
            OptionRow(title: "Musik", isOn: $settings.notchMusic)
            OptionRow(title: "Screenshots", isOn: $settings.notchScreenshots)
            OptionRow(title: "Ablage", isOn: $settings.notchShelf)
            OptionRow(title: "Termine", isOn: $settings.notchCalendar)
            OptionRow(title: "Timer", isOn: $settings.notchTimer)
            OptionRow(title: "Andere Bildschirme", caption: "Unsichtbare Notch, z. B. auf dem Monitor",
                      isOn: $settings.notchOtherScreens)
            Divider()
            Disclosure(title: "Kurze Anzeigen", isExpanded: $notchExtras)
            if notchExtras {
                OptionRow(title: "Kopfhörer verbunden", isOn: $settings.notchHeadphones)
                OptionRow(title: "Netzteil angesteckt", isOn: $settings.notchCharging)
                OptionRow(title: "Entsperrt", isOn: $settings.notchUnlock)
            }
        case .dockToggle:
            Text("Ein weiterer Klick aufs Dock-Symbol holt alle Fenster zurück.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .windowFetcher:
            Text("Ist das Fenster minimiert, kommt es zurück. Hat die App keins mehr, öffnet sie ein neues.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .mouseWheel:
            Divider()
            OptionRow(title: "Scrollen umkehren", isOn: $settings.mouseReverseScroll)
            OptionRow(title: "Zoomen umkehren", caption: "Mit gedrückter Cmd- oder ctrl-Taste", isOn: $settings.mouseReverseZoom)
            OptionRow(title: "Seitlich auch umkehren", isOn: $settings.mouseReverseHorizontal)
        case .appVolume:
            Divider()
            AppVolumeList(volume: state.volume, compact: true)
        case .downloads:
            Divider()
            OptionRow(title: "Alte Installer wegräumen", caption: "Älter als 14 Tage, in den Papierkorb",
                      isOn: $settings.downloadsTrashInstallers)
            Group {
                if let last = downloads.recent.first {
                    Text("Zuletzt: \(last.file) → \(last.target)").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Seit dem Start noch nichts einsortiert.")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            Pill(title: "Downloads-Ordner öffnen", symbol: "folder", wide: true) {
                close()
                NSWorkspace.shared.open(DownloadsCleaner.downloads)
            }
        case .rookSearch:
            Group {
                if rookSearch.waitingForQuit {
                    Text("Neue Version kommt, sobald Rook Search beendet wird.")
                } else if let problem = rookSearch.problem {
                    Text(problem)
                } else {
                    Text("Liegt in Programme und wird mit Rook aktualisiert.")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            Pill(title: "Rook Search öffnen", symbol: "globe", wide: true) {
                close()
                rookSearch.open()
            }
            .disabled(!rookSearch.isInstalled)
        }
    }
}

// MARK: Tabs

/// Ein Tab in der Leiste: eine Funktion oder die Leistungsanzeige.
enum MenuTab: Hashable, Identifiable {
    case feature(Feature)
    case performance

    init?(id: String) {
        if id == "performance" { self = .performance } else if let feature = Feature(rawValue: id) { self = .feature(feature) } else { return nil }
    }

    var id: String {
        switch self {
        case .feature(let feature): feature.rawValue
        case .performance: "performance"
        }
    }

    var title: String {
        switch self {
        case .feature(let feature): feature.title
        case .performance: "Leistung"
        }
    }

    var symbol: String {
        switch self {
        case .feature(let feature): feature.symbol
        case .performance: "gauge.with.dots.needle.33percent"
        }
    }

    var feature: Feature? {
        if case .feature(let feature) = self { feature } else { nil }
    }
}

/// Zustand beim Umsortieren der Leiste.
private struct TabDrag {
    let tab: MenuTab
    let start: Int
    let target: Int
    let translation: CGFloat
}

// MARK: Leistung

/// CPU und Arbeitsspeicher von Rook: jetzt, als Verlauf der letzten Minute und höchstens.
private struct PerformanceCard: View {
    @ObservedObject var monitor: ResourceMonitor
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("So viel braucht die App gerade.").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            metric("Prozessor", value: percent(monitor.samples.last?.cpu), values: monitor.samples.map(\.cpu), floor: 5)
            metric("Arbeitsspeicher", value: megabytes(monitor.samples.last?.memory),
                   values: monitor.samples.map(\.memory), floor: 50)
            Divider()
            InfoRow(title: "Bei geschlossenem Fenster", caption: monitor.backgroundCPU == nil
                        ? "Erscheint ab dem zweiten Öffnen"
                        : "Während das Fenster zu war, zuletzt \(duration(monitor.backgroundDuration))",
                    value: percent(monitor.backgroundCPU))
            InfoRow(title: "Im Schnitt seit Start", caption: "Gemessen, ohne die ersten 30 Sekunden nach dem Start",
                    value: percent(monitor.averageCPU))
            InfoRow(title: "Speicher-Spitze", caption: "Seit dem Start der App",
                    value: megabytes(monitor.peakMemory))
            Text("100 % CPU entspricht einem voll ausgelasteten Prozessorkern, wie in der Aktivitätsanzeige. „Jetzt“ enthält das Messen und Zeichnen dieses Fensters selbst, deshalb ist der Wert bei geschlossenem Fenster der aussagekräftige.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 10)
        // Gemessen wird nur, solange dieser Tab offen ist.
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func metric(_ title: String, value: String, values: [Double], floor: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            Sparkline(values: values, floor: floor).frame(height: 30)
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + " %"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        seconds < 120 ? "\(Int(seconds)) Sekunden" : seconds < 7200 ? "\(Int(seconds / 60)) Minuten" : "\(Int(seconds / 3600)) Stunden"
    }

    private func megabytes(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(0))) + " MB"
    }
}

/// Verlauf der letzten 60 Sekunden als blaue Linie mit sanfter Fläche darunter.
private struct Sparkline: View {
    let values: [Double]
    /// Kleinster Endwert der Skala, damit kleine Schwankungen nicht riesig wirken.
    let floor: Double

    var body: some View {
        GeometryReader { box in
            let top = max(values.max() ?? 0, floor) * 1.15
            let step = box.size.width / 59
            let points = values.suffix(60).enumerated().map { index, value in
                CGPoint(x: box.size.width - CGFloat(values.suffix(60).count - 1 - index) * step,
                        y: box.size.height * (1 - CGFloat(value / top)))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.04))
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: box.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: box.size.height))
                    }
                    .fill(LinearGradient(colors: [MenuBarView.accent.opacity(0.35), MenuBarView.accent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(MenuBarView.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

/// Zeile mit Titel, kleiner Erklärung und Wert rechts.
private struct InfoRow: View {
    let title: String
    let caption: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }
}

// MARK: Bausteine

/// Kopfzeile mit kurzer Animation wie im Intro von Rook: Der Rabe wird vom Schnabel her
/// aufgedeckt, ein Lichtstreifen läuft einmal über ihn, dann erscheint der Name daneben.
private struct RavenIntro: View {
    static let name = "Rook"
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var shine = false
    @State private var nameShown = false

    var body: some View {
        HStack(spacing: 8) {
            raven
            Text(Self.name)
                .font(.system(size: 15, weight: .bold))
                .tracking(0.5)
                .opacity(nameShown ? 1 : 0)
                .blur(radius: nameShown ? 0 : 4)
                .offset(x: nameShown ? 0 : -6)
        }
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.name)
        .onAppear(perform: play)
        .onChange(of: trigger) { play() }
    }

    private var image: some View {
        Group {
            if let raven = Bundle.main.image(forResource: "MenuBarIcon") {
                Image(nsImage: raven).renderingMode(.template).resizable().interpolation(.high)
            } else {
                Image(systemName: "bird.fill").resizable()
            }
        }
        .scaledToFit()
    }

    private var raven: some View {
        image
            // Grau, bis der Lichtstreifen drüber ist, danach weiß
            .foregroundStyle(Color(white: shine ? 1 : 0.6))
            .overlay {
                GeometryReader { box in
                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: box.size.width * 0.6)
                        .offset(x: shine ? box.size.width * 1.2 : -box.size.width * 0.8)
                }
                .mask(image)
            }
            // Von links (Schnabel) nach rechts aufdecken, mit weicher Kante
            .mask {
                GeometryReader { box in
                    LinearGradient(stops: [.init(color: .black, location: 0.45), .init(color: .clear, location: 0.55)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: box.size.width * 3)
                        .offset(x: revealed ? -box.size.width * 0.4 : -box.size.width * 1.6)
                }
            }
            .frame(width: 24, height: 24)
    }

    private func play() {
        var reset = Transaction()
        reset.disablesAnimations = true
        if reduceMotion {
            withTransaction(reset) { revealed = true; shine = true; nameShown = true }
            return
        }
        withTransaction(reset) { revealed = false; shine = false; nameShown = false }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.55)) { revealed = true }
            withAnimation(.easeInOut(duration: 0.7).delay(0.25)) { shine = true }
            withAnimation(.spring(duration: 0.6, bounce: 0.15).delay(0.45)) { nameShown = true }
        }
    }
}

private extension View {
    /// Graue Fläche mit feiner heller Kante, wie Leiste und Karte bei Vorssaint.
    func surface(cornerRadius: CGFloat) -> some View {
        background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.11), lineWidth: 0.7))
    }
}

/// Eine Einstellung: Titel, darunter optional eine kurze Erklärung, rechts ein kleiner Schalter.
private struct OptionRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let caption {
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

/// Kleine, runde Schaltfläche. Ausgewählt in Blau, sonst grau.
private struct Pill: View {
    let title: String
    var symbol: String?
    var isSelected = false
    var wide = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)) }
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(MenuBarView.accent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: 20)
            .background(isSelected ? MenuBarView.accent.opacity(0.2) : Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Aufklappbare Zeile für seltener gebrauchte Einstellungen.
private struct Disclosure: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Einstellungen und Beenden am unteren Rand.
private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.11), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
