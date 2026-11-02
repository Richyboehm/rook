import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Das Fenster unter dem Raben in der Menüleiste, als normales macOS-Popover mit kleinem Pfeil.
/// Schließt sich bei Klick daneben, mit Esc oder bei erneutem Klick auf den Raben.
@MainActor
final class MenuBarPanel: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    private let popover = NSPopover()
    private let intro = IntroTrigger()
    private let state: AppState
    private let openSettings: (Feature?) -> Void

    init(state: AppState, openSettings: @escaping (Feature?) -> Void) {
        self.state = state
        self.openSettings = openSettings
        super.init()
        // Immer dunkel wie bei Vorssaint, egal ob die Menüleiste hell oder dunkel ist.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private var closedAt = Date.distantPast

    /// Offen oder gerade eben geschlossen: Ein Klick auf den Raben schließt das Popover zuerst
    /// selbst (es ist „transient“), danach soll derselbe Klick es nicht gleich wieder öffnen.
    var isVisible: Bool { popover.isShown || Date().timeIntervalSince(closedAt) < 0.3 }

    func show(below button: NSStatusBarButton) {
        intro.count += 1
        // Der Inhalt wird erst beim Öffnen gebaut und beim Schließen wieder freigegeben.
        if popover.contentViewController == nil { popover.contentViewController = makeContent() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Als Hintergrund-App bekommt das Popover sonst keine Tastatur (Esc).
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }

    func popoverWillClose(_ notification: Notification) { closedAt = Date() }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        Memory.relieve()
        onClose?()
    }

    private func makeContent() -> NSViewController {
        let view = MenuBarView(settings: state.settings, permissions: state.permissions, downloads: state.downloads,
                               intro: intro, state: state,
                               openSettings: { [weak self] feature in self?.close(); self?.openSettings(feature) },
                               close: { [weak self] in self?.close() })
        let controller = NSHostingController(rootView: view)
        // Das Popover wächst und schrumpft mit dem Inhalt, z. B. beim Wechsel der Funktion.
        controller.sizingOptions = .preferredContentSize
        return controller
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
    let state: AppState
    let openSettings: (Feature?) -> Void
    let close: () -> Void

    @AppStorage("menuBarTab") private var selectedRaw = Feature.lockWidget.rawValue
    /// Reihenfolge der Leiste, per Ziehen änderbar; neue Tabs kommen hinten dazu.
    @AppStorage("menuBarOrder") private var orderRaw = ""
    @State private var dragging: MenuTab?
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
                FooterButton(title: "Rook Search", symbol: "magnifyingglass") {
                    // Installiert: öffnen. Sonst die Kommandozentrale mit dem Knopf zum Laden zeigen.
                    state.rookSearch.refresh()
                    if state.rookSearch.installedURL != nil {
                        close()
                        state.rookSearch.open()
                    } else {
                        openSettings(nil)
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

    /// Klick wählt einen Tab, Ziehen sortiert die Leiste um.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selected
                Button { selectedRaw = tab.id } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(MenuBarView.accent) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 27)
                        .background(isSelected ? MenuBarView.accent.opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .onDrag {
                    dragging = tab
                    return NSItemProvider(object: tab.id as NSString)
                }
                .onDrop(of: [.text], delegate: TabDrop(target: tab, tabs: tabs, dragging: $dragging) { order in
                    orderRaw = order.map(\.id).joined(separator: ",")
                })
            }
        }
        .padding(4)
        .surface(cornerRadius: 12)
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
            Divider()
            Disclosure(title: "Kurze Anzeigen", isExpanded: $notchExtras)
            if notchExtras {
                OptionRow(title: "Kopfhörer verbunden", isOn: $settings.notchHeadphones)
                OptionRow(title: "Netzteil angesteckt", isOn: $settings.notchCharging)
                OptionRow(title: "Entsperrt", isOn: $settings.notchUnlock)
            }
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

/// Schiebt den gezogenen Tab an die Stelle, über der er gerade ist.
private struct TabDrop: DropDelegate {
    let target: MenuTab
    let tabs: [MenuTab]
    @Binding var dragging: MenuTab?
    let save: ([MenuTab]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = tabs.firstIndex(of: dragging), let to = tabs.firstIndex(of: target) else { return }
        var order = tabs
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.snappy(duration: 0.2)) { save(order) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: Leistung

/// CPU und Arbeitsspeicher von Rook: jetzt, als Verlauf der letzten Minute und höchstens.
private struct PerformanceCard: View {
    @ObservedObject var monitor: ResourceMonitor
    @ObservedObject var settings: Settings

    var body: some View {
        let maximum = ResourceMonitor.estimatedMaximum(settings)
        VStack(alignment: .leading, spacing: 10) {
            Text("So viel braucht die App gerade.").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            metric("Prozessor", value: percent(monitor.samples.last?.cpu), values: monitor.samples.map(\.cpu), floor: 5)
            metric("Arbeitsspeicher", value: megabytes(monitor.samples.last?.memory),
                   values: monitor.samples.map(\.memory), floor: 50)
            Divider()
            InfoRow(title: "Höchstens", caption: "Geschätzt: alle eingeschalteten Funktionen gleichzeitig aktiv",
                    value: "\(percent(maximum.cpu)) · \(megabytes(maximum.memory))")
            InfoRow(title: "Speicher-Spitze", caption: "Seit dem Start der App",
                    value: megabytes(monitor.peakMemory))
            Text("100 % CPU entspricht einem voll ausgelasteten Prozessorkern, wie in der Aktivitätsanzeige.")
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
