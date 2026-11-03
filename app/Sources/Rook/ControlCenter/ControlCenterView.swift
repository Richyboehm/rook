import SwiftUI

enum Page: Hashable {
    case overview
    case feature(Feature)
    case permissions
    case general
}

struct ControlCenterView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions
    @ObservedObject var downloads: DownloadsCleaner
    @ObservedObject var weather: WeatherService
    @ObservedObject var rookSearch: RookSearch
    @ObservedObject var updater: Updater
    let state: AppState
    @State private var page: Page = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("Übersicht", systemImage: "square.grid.2x2").tag(Page.overview)
                Section("Funktionen") {
                    ForEach(Feature.allCases) { feature in
                        Label(feature.title, systemImage: feature.symbol).tag(Page.feature(feature))
                    }
                }
                Section {
                    Label("Erlaubnisse", systemImage: "hand.raised").tag(Page.permissions)
                    Label("Allgemein", systemImage: "gearshape").tag(Page.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { detail }
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showControlCenterPage)) { note in
            if let raw = note.object as? String, let feature = Feature(rawValue: raw) { page = .feature(feature) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .overview: overview
        case .feature(.lockWidget): widgetsPage
        case .feature(.standBy): standByPage
        case .feature(.notch): notchPage
        case .feature(.windowFetcher): windowFetcherPage
        case .feature(.dockToggle): dockTogglePage
        case .feature(.mouseWheel): mouseWheelPage
        case .feature(.appVolume): appVolumePage
        case .feature(.downloads): downloadsPage
        case .feature(.rookSearch): rookSearchPage
        case .permissions: permissionsPage
        case .general: generalPage
        }
    }

    // MARK: Übersicht

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                // Das eigene Logo direkt aus der App: NSApp.applicationIconImage liefert je nach
                // Symbolstil (z. B. „Klar“) eine umgefärbte Glas-Version.
                Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                    .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rook").font(.system(size: 24, weight: .semibold))
                    Text("Alle Funktionen auf einen Blick.").foregroundStyle(.secondary)
                }
            }
            UpdateRow(updater: updater)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Feature.allCases) { featureCard($0) }
            }

            let missing = Permissions.Kind.allCases.filter { permissions.status[$0] != .granted }.count
            if missing > 0 {
                HStack {
                    Text(missing == 1 ? "1 Erlaubnis ist noch offen." : "\(missing) Erlaubnisse sind noch offen.")
                        .foregroundStyle(.secondary)
                    Button("Ansehen") { page = .permissions }.buttonStyle(.link)
                }
                .font(.callout)
            }
        }
    }

    private func featureCard(_ feature: Feature) -> some View {
        let (text, color) = status(of: feature)
        return Card {
            HStack(alignment: .top) {
                IconTile(symbol: feature.symbol)
                Spacer()
                Toggle("", isOn: feature.isOn(settings)).toggleStyle(.switch).labelsHidden()
                    .disabled(feature == .notch && !NotchFeature.isAvailable)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.headline)
                Text(feature.tagline).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                StatusChip(text: text, color: color)
                Spacer()
                Button("Einstellungen") { page = .feature(feature) }.buttonStyle(.link)
            }
        }
    }

    private func status(of feature: Feature) -> (String, Color) {
        if feature == .notch && !NotchFeature.isAvailable { return ("Keine Notch", .secondary) }
        guard feature.isOn(settings).wrappedValue else { return ("Aus", .secondary) }
        if let needed = feature.requiredPermission, permissions.status[needed] != .granted {
            return ("Erlaubnis fehlt", .orange)
        }
        return ("An", .green)
    }

    // MARK: Widgets

    private var widgetsPage: some View {
        let feature = Feature.lockWidget
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Erscheinen auf dem Sperrbildschirm. Ist der Mac entsperrt, laufen sie nicht.",
                       isOn: feature.isOn(settings))
            Card(title: "Widgets") {
                OptionToggle(symbol: "music.note", title: "Musik",
                             detail: "Cover, Titel und Steuerung, solange in Spotify ein Song läuft. Klick aufs Cover vergrößert.",
                             isOn: $settings.widgetMusic)
                Divider()
                OptionToggle(symbol: "calendar", title: "Nächster Termin",
                             detail: "Uhrzeit und Titel des nächsten Termins in den kommenden 24 Stunden.",
                             isOn: $settings.widgetEvent)
                Divider()
                OptionToggle(symbol: "cloud.sun", title: "Wetter",
                             detail: "Temperatur am eingetragenen Ort, höchstens einmal pro Stunde abgefragt.",
                             isOn: $settings.widgetWeather)
                if settings.widgetWeather {
                    HStack {
                        TextField("Ort, z. B. München", text: $settings.weatherPlace)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            .onSubmit { weather.refreshIfNeeded(place: settings.weatherPlace) }
                        Button("Prüfen") { weather.refreshIfNeeded(place: settings.weatherPlace) }
                        Spacer()
                        if let now = weather.current {
                            Label("\(now.place), \(now.temperature)°", systemImage: now.symbol)
                                .foregroundStyle(.secondary)
                        } else if let problem = weather.problem {
                            Text(problem).foregroundStyle(.orange)
                        }
                    }
                    .padding(.leading, 34)
                    .font(.callout)
                }
                Divider()
                OptionToggle(symbol: "battery.75percent", title: "Akku & AirPods",
                             detail: "Ladestand vom Mac und von verbundenen Kopfhörern.",
                             isOn: $settings.widgetBattery)
            }
            .disabled(!settings.lockWidget)
            Card(title: "Position") {
                Picker("Position", selection: $settings.lockWidgetPlacement) {
                    ForEach(Placement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Card(title: "Erlaubnisse") {
                PermissionRow(kind: .spotify, permissions: permissions)
                Divider()
                PermissionRow(kind: .calendar, permissions: permissions)
                Divider()
                PermissionRow(kind: .bluetooth, permissions: permissions)
            }
            HStack {
                Button(state.lockWidget.preview ? "Vorschau beenden" : "Vorschau auf dem Schreibtisch") {
                    state.lockWidget.preview.toggle()
                }
                Text("Endet spätestens beim nächsten Entsperren.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: StandBy

    private var standByPage: some View {
        let feature = Feature.standBy
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Hängt der Mac am Netzteil und ist gesperrt, zeigt der Sperrbildschirm eine große Uhr mit Song, nächstem Termin und Ladestand. Eine Bewegung von Maus oder Tastatur blendet sie aus. Im Akkubetrieb läuft StandBy nicht.",
                       isOn: feature.isOn(settings))
            Card(title: "Optionen") {
                OptionToggle(symbol: "lock", title: "Am Netzteil automatisch sperren",
                             detail: "Nach 5 Minuten ohne Eingabe. Nicht, während ein Video läuft.",
                             isOn: $settings.standByAutoLock)
                Divider()
                OptionToggle(symbol: "moon", title: "Nachtmodus",
                             detail: "Von 22 bis 7 Uhr rot und gedimmt.",
                             isOn: $settings.standByNightMode)
            }
            .disabled(!settings.standBy)
            Card(title: "Erlaubnisse") {
                PermissionRow(kind: .calendar, permissions: permissions)
                Divider()
                PermissionRow(kind: .spotify, permissions: permissions)
            }
            HStack {
                Button("StandBy ansehen") { state.standBy.preview() }
                Text("Eine Bewegung blendet die Vorschau wieder aus.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Notch

    private var notchPage: some View {
        let feature = Feature.notch
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: NotchFeature.isAvailable
                           ? "Fahr mit der Maus auf die Notch, um sie aufzuklappen. Rechtsklick öffnet ein Menü."
                           : "Dieser Mac hat keinen Bildschirm mit Notch.",
                       isOn: NotchFeature.isAvailable ? feature.isOn(settings) : nil)
            Card(title: "Inhalt") {
                OptionToggle(symbol: "music.note", title: "Musik",
                             detail: "Cover neben der Notch, Steuerung beim Aufklappen, kurzes Aufklappen bei neuem Song.",
                             isOn: $settings.notchMusic)
                OptionToggle(symbol: "paintpalette", title: "Cover-Farben",
                             detail: "Wellenform und Fortschritt in der Farbe des Covers.",
                             isOn: $settings.notchCoverColors)
                    .disabled(!settings.notchMusic)
                Divider()
                OptionToggle(symbol: "rectangle.dashed", title: "Screenshots",
                             detail: "Ausschnitt, Fenster oder Bildschirm. Landet in der Zwischenablage.",
                             isOn: $settings.notchScreenshots)
                OptionToggle(symbol: "tray", title: "Ablage",
                             detail: "Dateien auf die Notch ziehen und später weiterziehen.",
                             isOn: $settings.notchShelf)
                Divider()
                OptionToggle(symbol: "calendar", title: "Termine",
                             detail: "Nächster Termin, Countdown ab 10 Minuten vorher.",
                             isOn: $settings.notchCalendar)
                OptionToggle(symbol: "timer", title: "Timer",
                             detail: "Frei einstellbar, mit Pause und +1 Minute.",
                             isOn: $settings.notchTimer)
                Divider()
                OptionToggle(symbol: "airpods", title: "Kopfhörer",
                             detail: "Kurze Anzeige mit Akkustand beim Verbinden.",
                             isOn: $settings.notchHeadphones)
                OptionToggle(symbol: "bolt", title: "Laden",
                             detail: "Kurze Anzeige beim Anstecken des Netzteils.",
                             isOn: $settings.notchCharging)
                OptionToggle(symbol: "lock.open", title: "Entsperren",
                             detail: "Kurzes Schloss-Symbol nach dem Entsperren.",
                             isOn: $settings.notchUnlock)
                Divider()
                OptionToggle(symbol: "display.2", title: "Andere Bildschirme",
                             detail: "Unsichtbare Notch oben in der Mitte, z. B. auf einem externen Monitor. Maus hin, und die Notch klappt dort auf.",
                             isOn: $settings.notchOtherScreens)
            }
            .disabled(!settings.notch || !NotchFeature.isAvailable)
            Card(title: "Erlaubnisse") {
                PermissionRow(kind: .spotify, permissions: permissions)
                Divider()
                PermissionRow(kind: .screenRecording, permissions: permissions)
                Divider()
                PermissionRow(kind: .calendar, permissions: permissions)
                Divider()
                PermissionRow(kind: .bluetooth, permissions: permissions)
            }
        }
    }

    // MARK: Fensterholer

    private var dockTogglePage: some View {
        let feature = Feature.dockToggle
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Klickst du im Dock auf die App, die gerade vorne ist, fliegen ihre Fenster ins Dock, wie in der Windows-Taskleiste. Ein weiterer Klick holt alle Fenster zurück. Hat die App kein offenes Fenster, öffnet der Klick wie gewohnt ein neues. Rook achtet dafür nur auf Klicks, nicht auf Mausbewegungen.",
                       isOn: feature.isOn(settings))
            Card(title: "Erlaubnisse") { PermissionRow(kind: .accessibility, permissions: permissions) }
        }
    }

    private var windowFetcherPage: some View {
        let feature = Feature.windowFetcher
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Cmd + Tab funktioniert wie gewohnt. Ist das Fenster der gewählten App minimiert, kommt es aus dem Dock zurück. Hat die App kein Fenster mehr, öffnet sie ein neues. Tasten werden weder verändert noch gespeichert.",
                       isOn: feature.isOn(settings))
            Card(title: "Erlaubnisse") { PermissionRow(kind: .accessibility, permissions: permissions) }
        }
    }

    // MARK: Mausrad

    private var mouseWheelPage: some View {
        let feature = Feature.mouseWheel
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Dreht die Richtung nur für Mäuse mit Rad um. Trackpad und Magic Mouse bleiben, wie unter Systemeinstellungen → Maus bzw. Trackpad bei „Natürliches Scrollen“ eingestellt.",
                       isOn: feature.isOn(settings))
            Card(title: "Optionen") {
                OptionToggle(symbol: "arrow.up.arrow.down", title: "Scrollen umkehren",
                             detail: "Das Rad ohne Sondertaste.",
                             isOn: $settings.mouseReverseScroll)
                Divider()
                OptionToggle(symbol: "plus.magnifyingglass", title: "Zoomen umkehren",
                             detail: "Das Rad mit gedrückter Cmd- oder ctrl-Taste, z. B. in Karten, Bildern oder beim Bildschirmzoom.",
                             isOn: $settings.mouseReverseZoom)
                Divider()
                OptionToggle(symbol: "arrow.left.arrow.right", title: "Seitlich auch umkehren",
                             detail: "Kipprad oder zweites Rad, z. B. bei Logitech-Mäusen.",
                             isOn: $settings.mouseReverseHorizontal)
            }
            .disabled(!settings.mouseWheel)
            Card(title: "Erlaubnisse") { PermissionRow(kind: .accessibility, permissions: permissions) }
        }
    }

    // MARK: Lautstärke

    private var appVolumePage: some View {
        let feature = Feature.appVolume
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Stell für jede App eine eigene Lautstärke ein, wie unter Windows. Steht eine App auf 100 %, bleibt ihr Ton unverändert. Die Lautstärke wird pro App gemerkt und beim nächsten Abspielen wieder benutzt.",
                       isOn: feature.isOn(settings))
            Card(title: "Apps") { AppVolumeList(volume: state.volume) }
                .disabled(!settings.appVolume)
            Card(title: "Erlaubnisse") { PermissionRow(kind: .audioCapture, permissions: permissions) }
        }
    }

    // MARK: Downloads

    private var downloadsPage: some View {
        let feature = Feature.downloads
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Neue Dateien im Downloads-Ordner kommen in Unterordner: "
                           + DownloadsCleaner.categories.map(\.folder).joined(separator: ", ")
                           + ". Unbekannte Dateitypen, Ordner und unfertige Downloads bleiben liegen.",
                       isOn: feature.isOn(settings))
            Card(title: "Optionen") {
                OptionToggle(symbol: "trash", title: "Alte Installer wegräumen",
                             detail: ".dmg- und .pkg-Dateien, die älter als 14 Tage sind, kommen in den Papierkorb.",
                             isOn: $settings.downloadsTrashInstallers)
            }
            .disabled(!settings.downloadsCleaner)
            Card(title: "Erlaubnisse") { PermissionRow(kind: .downloads, permissions: permissions) }
            if let error = downloads.lastError, settings.downloadsCleaner {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Card(title: "Zuletzt einsortiert") {
                if downloads.recent.isEmpty {
                    Text("Seit dem Start noch nichts.").foregroundStyle(.secondary)
                } else {
                    ForEach(downloads.recent) { action in
                        HStack {
                            Text(action.file).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(action.target).foregroundStyle(.secondary)
                            Text(action.date, style: .time).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
            Button("Downloads-Ordner öffnen") { NSWorkspace.shared.open(DownloadsCleaner.downloads) }
        }
    }

    // MARK: Rook Search

    private var rookSearchPage: some View {
        let feature = Feature.rookSearch
        return VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: feature.symbol, title: feature.title,
                       text: "Der Browser von Rook: Safari-Engine, Werbeblocker eingebaut, Tab-Gruppen wie in Safari, deine Daten bleiben auf dem Mac. Eingeschaltet liegt er in Programme und kann dein Standardbrowser sein.",
                       isOn: feature.isOn(settings))
            RookSearchCard(rookSearch: rookSearch, isOn: settings.rookSearch)
        }
    }

    // MARK: Erlaubnisse

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: "hand.raised", title: "Erlaubnisse",
                       text: "Nötig sind nur die Erlaubnisse für Funktionen, die du nutzt. Entziehen kannst du sie jederzeit in den Systemeinstellungen unter Datenschutz & Sicherheit.")
            Card {
                ForEach(Array(Permissions.Kind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider() }
                    PermissionRow(kind: kind, permissions: permissions)
                }
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in permissions.refresh() }
    }

    // MARK: Allgemein

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: "gearshape", title: "Allgemein", text: "Einstellungen für Rook selbst.")
            Card {
                OptionToggle(symbol: "power", title: "Beim Anmelden starten",
                             detail: "Rook startet automatisch in der Menüleiste.",
                             isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                Divider()
                OptionToggle(symbol: "doc.text", title: "Protokoll schreiben",
                             detail: "Für die Fehlersuche.",
                             isOn: $settings.debugLog)
                if settings.debugLog {
                    Button("Protokoll öffnen") { NSWorkspace.shared.open(Log.url) }
                        .padding(.leading, 34)
                }
            }
            Card(title: "Updates") {
                UpdateRow(updater: updater)
                Text("Rook schaut einmal am Tag nach einer neuen Version. Rook Search kommt dabei mit. Installiert wird nur, was mit dem Zertifikat von Rook signiert ist; Erlaubnisse bleiben erhalten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Rook beenden") { NSApp.terminate(nil) }
            }
        }
    }
}
