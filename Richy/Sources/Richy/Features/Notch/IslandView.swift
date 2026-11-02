import SwiftUI

struct IslandView: View {
    @ObservedObject var spotify: Spotify
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: Settings

    typealias Live = IslandModel.Live
    typealias Peek = IslandModel.Peek

    /// Bereits angewendete Schritte während eines Zieh-Vorgangs am Timer.
    @State private var dragSteps = 0

    enum Mode: Equatable { case hidden, compact(Live), small(Peek), expanded }

    private var live: Live? {
        if settings.notchTimer && model.timerActive { return .timer }
        if settings.notchCalendar && model.meetingSoon { return .meeting }
        if settings.notchMusic && spotify.track != nil && spotify.isPlaying { return .music }
        return nil
    }

    /// Farbe für Wellenform und Fortschritt: Cover-Farbe oder neutral weiß.
    private var accent: Color { settings.notchCoverColors ? spotify.palette.primary : .white }

    private var mode: Mode {
        if model.hovering || model.dragging { return .expanded }
        if let peek = model.peek { return peek.expands ? .expanded : .small(peek) }
        if let live { return .compact(live) }
        return .hidden
    }

    private var isExpanded: Bool { mode == .expanded }

    private var size: CGSize {
        switch mode {
        case .hidden: model.notch
        case .compact, .small: CGSize(width: model.compactWidth, height: model.notch.height)
        case .expanded: CGSize(width: IslandModel.expandedWidth, height: model.expandedHeight)
        }
    }

    var body: some View {
        let radius = isExpanded ? 30 : model.notch.height / 2.6
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        // Auch im Ruhezustand ist die Insel da: schwarz und genau so groß wie die Notch,
        // also unsichtbar. So kann man jederzeit Dateien auf die Notch ziehen.
        ZStack(alignment: .top) {
            shape.fill(.black)
            content
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(isExpanded ? 0.35 : 0), radius: 16, y: 6)
        .contextMenu { menu }
        .animation(.spring(duration: 0.42, bounce: 0.28), value: mode)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.expandedHeight)
        .animation(.easeInOut(duration: 0.9), value: spotify.palette)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var menu: some View {
        if !settings.notchTimer {
            EmptyView()
        } else if model.timerEnd != nil {
            Button("Timer pausieren") { model.pauseTimer() }
            Button("Timer +1 Min") { model.addMinute() }
            Button("Timer stoppen") { model.stopTimer() }
        } else if model.timerPaused != nil {
            Button("Timer fortsetzen") { model.resumeTimer() }
            Button("Timer stoppen") { model.stopTimer() }
        } else {
            Button("Timer starten (\(minutesLabel(model.timerMinutes)))") { model.startTimer() }
        }
        if settings.notchScreenshots {
            Divider()
            Button("Screenshot: Ausschnitt") { model.capture(.area) }
            Button("Screenshot: Fenster") { model.capture(.window) }
            Button("Screenshot: Bildschirm") { model.capture(.screen) }
        }
        Divider()
        if settings.notchShelf && !model.shelf.isEmpty { Button("Ablage leeren") { model.clearShelf() } }
        Button("Kommandozentrale öffnen …") { NotificationCenter.default.post(name: .openControlCenter, object: nil) }
        Button("Richy beenden") { NSApp.terminate(nil) }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .hidden:
            EmptyView()
        case .compact(let live):
            compactContent(live).transition(.opacity)
        case .small(let peek):
            smallContent(peek).transition(.opacity)
        case .expanded:
            expandedContent.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
    }

    // MARK: Klein: je ein Feld links und rechts der Notch

    private func sides<Left: View, Right: View>(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        HStack(spacing: 0) {
            left().frame(width: model.notch.height + 14)
            Spacer(minLength: model.notch.width)
            right().frame(width: model.notch.height + 14)
        }
        .frame(height: model.notch.height)
    }

    @ViewBuilder private func compactContent(_ live: Live) -> some View {
        switch live {
        case .music:
            sides {
                cover(size: model.notch.height - 10, radius: 6)
            } right: {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            }
        case .meeting:
            sides {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.nextEvent?.color ?? .red)
            } right: {
                // Ändert sich nur einmal pro Minute.
                TimelineView(.everyMinute) { context in
                    Text(minutesUntilEvent(at: context.date))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(model.nextEvent?.color ?? .red)
                }
            }
        case .timer:
            // Tickt nur, solange der Timer wirklich läuft; pausiert steht alles still.
            ticking(model.timerEnd != nil) { date in
                sides {
                    timerRing(at: date, size: 15)
                } right: {
                    Text(timerRemaining(at: date))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(model.timerPaused != nil ? .white.opacity(0.5) : .orange)
                }
            }
        }
    }

    @ViewBuilder private func smallContent(_ peek: Peek) -> some View {
        switch peek {
        case .charging:
            sides {
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
            } right: {
                Text("\(model.battery.percent) %")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.green)
            }
        case .unlocked:
            sides {
                Image(systemName: "lock.open.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } right: {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
            }
        case .headphones(let headphones):
            sides {
                Image(systemName: headphones.symbol).font(.system(size: 14)).foregroundStyle(.white)
            } right: {
                if let battery = headphones.battery {
                    Text("\(battery) %")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(battery <= 20 ? .red : .green)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                }
            }
        case .track, .meeting, .timerDone, .screenshot:
            EmptyView() // klappen auf
        }
    }

    // MARK: Groß

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            topStrip
            if model.peek == .timerDone {
                banner(symbol: "timer", text: "Timer abgelaufen", color: .orange)
            }
            if model.peek == .meeting, let event = model.nextEvent {
                banner(symbol: "calendar", text: "\(event.title) beginnt gleich", color: event.color)
            }
            if case .screenshot(let url) = model.peek {
                screenshotBanner(url)
            }
            if settings.notchMusic && spotify.track != nil { musicSection }
            if settings.notchScreenshots { captureRow }
            if settings.notchShelf && (!model.shelf.isEmpty || model.dragging) { shelfSection }
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: IslandModel.expandedWidth)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(height - model.expandedHeight) > 0.5 { model.expandedHeight = height }
        }
    }

    /// Links und rechts neben der Notch: Datum und Akku.
    private var topStrip: some View {
        HStack {
            Text(Date.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
            Spacer(minLength: model.notch.width + 24)
            HStack(spacing: 4) {
                Text("\(model.battery.percent) %").monospacedDigit()
                Image(systemName: model.battery.onPower ? "battery.100percent.bolt" : batterySymbol)
                    .foregroundStyle(model.battery.onPower ? .green : (model.battery.percent <= 20 ? .red : .white.opacity(0.6)))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
        .frame(height: model.notch.height)
    }

    private var batterySymbol: String {
        switch model.battery.percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func banner(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
            Text(text).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var musicSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                cover(size: 52, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(spotify.track?.name ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(spotify.track?.artist ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    button("backward.fill", size: 15, action: spotify.previous)
                    button(spotify.isPlaying ? "pause.fill" : "play.fill", size: 20, action: spotify.playPause)
                    button("forward.fill", size: 15, action: spotify.next)
                }
            }
            progress
        }
    }

    // MARK: Screenshots

    private var captureRow: some View {
        HStack(spacing: 8) {
            captureButton("Ausschnitt", symbol: "rectangle.dashed", mode: .area)
            captureButton("Fenster", symbol: "macwindow", mode: .window)
            captureButton("Bildschirm", symbol: "display", mode: .screen)
        }
    }

    private func captureButton(_ title: String, symbol: String, mode: Screenshots.Mode) -> some View {
        Button { model.capture(mode) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func screenshotBanner(_ url: URL) -> some View {
        HStack(spacing: 12) {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshot kopiert").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Liegt auch in der Ablage").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
        }
    }

    // MARK: Ablage

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ablage").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !model.shelf.isEmpty {
                    Button("Leeren") { model.clearShelf() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if model.shelf.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(height: 64)
                    .overlay {
                        Label("Hier ablegen", systemImage: "tray.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.shelf, id: \.self) { shelfTile($0) }
                    }
                    .padding(.top, 4)
                }
                .frame(height: 72)
                .overlay {
                    if model.dragging {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    }
                }
            }
        }
    }

    private func shelfTile(_ url: URL) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 38, height: 38)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .overlay(alignment: .topTrailing) {
            Button { model.removeFromShelf(url) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7), .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: -4, y: -4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
    }

    // MARK: Termin und Timer

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if settings.notchCalendar { eventRow }
            if settings.notchTimer { timerRow }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var eventRow: some View {
        HStack(spacing: 8) {
            if let event = model.nextEvent {
                Circle().fill(event.color).frame(width: 7, height: 7)
                Text(event.start, format: .dateTime.hour().minute())
                    .foregroundStyle(.white.opacity(0.6))
                Text(event.title).foregroundStyle(.white).lineLimit(1)
            } else {
                Image(systemName: "calendar").foregroundStyle(.white.opacity(0.4))
                Text("Keine Termine in Sicht").foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var timerRow: some View {
        if model.timerActive {
            HStack(spacing: 10) {
                ticking(model.timerEnd != nil) { date in
                    HStack(spacing: 8) {
                        timerRing(at: date, size: 16)
                        Text(timerRemaining(at: date))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(model.timerPaused != nil ? .white.opacity(0.5) : .orange)
                    }
                }
                Spacer(minLength: 0)
                pill("+1 Min") { model.addMinute() }
                circleButton(model.timerPaused != nil ? "play.fill" : "pause.fill") {
                    if model.timerPaused != nil { model.resumeTimer() } else { model.pauseTimer() }
                }
                circleButton("xmark") { model.stopTimer() }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(.white.opacity(0.5))
                Text("Timer").foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                circleButton("minus") { model.adjustTimer(by: -1) }
                // Zum Einstellen auch ziehen: nach rechts/oben mehr, nach links/unten weniger.
                Text(minutesLabel(model.timerMinutes))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 74)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let steps = Int((value.translation.width - value.translation.height) / 8)
                            if steps != dragSteps {
                                model.adjustTimer(by: steps - dragSteps)
                                dragSteps = steps
                            }
                        }
                        .onEnded { _ in dragSteps = 0 })
                    .help("Ziehen oder − / + zum Einstellen")
                circleButton("plus") { model.adjustTimer(by: 1) }
                pill("Start", tint: .orange) { model.startTimer() }
            }
        }
    }

    private func pill(_ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint == .white ? .white : .black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(tint == .white ? .white.opacity(0.12) : tint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    private func minutesLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) Min" : String(format: "%d:%02d Std", minutes / 60, minutes % 60)
    }

    /// Sekundentakt nur, wenn `active`; sonst wird einmal gezeichnet und es läuft nichts.
    @ViewBuilder private func ticking<Content: View>(_ active: Bool,
                                                     @ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        } else {
            content(.now)
        }
    }

    private func timerRing(at date: Date, size: CGFloat) -> some View {
        let fraction = model.timerRemaining(at: date) / max(model.timerTotal, 1)
        return ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction)
                .stroke(model.timerPaused != nil ? .white.opacity(0.5) : .orange,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }

    private func timerRemaining(at date: Date) -> String {
        format(model.timerRemaining(at: date).rounded(.up))
    }

    private func minutesUntilEvent(at date: Date) -> String {
        guard let start = model.nextEvent?.start else { return "" }
        let minutes = Int((start.timeIntervalSince(date) / 60).rounded(.up))
        return minutes <= 0 ? "jetzt" : "\(minutes) Min"
    }

    // MARK: Bausteine

    private func cover(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = spotify.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                spotify.palette.primary.opacity(0.4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Tickt nur, solange die große Ansicht offen ist und Musik läuft.
    @ViewBuilder private var progress: some View {
        if spotify.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressContent(elapsed: elapsed(at: context.date))
            }
        } else {
            progressContent(elapsed: elapsed(at: spotify.positionDate))
        }
    }

    private func elapsed(at date: Date) -> Double {
        let value = spotify.position + (spotify.isPlaying ? date.timeIntervalSince(spotify.positionDate) : 0)
        return min(max(value, 0), spotify.track?.duration ?? 0)
    }

    private func progressContent(elapsed: Double) -> some View {
        let duration = spotify.track?.duration ?? 0
        return HStack(spacing: 10) {
            Text(format(elapsed))
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(accent)
                            .frame(width: geo.size.width * elapsed / max(duration, 1))
                    }
            }
            .frame(height: 4)
            Text("-" + format(duration - elapsed))
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let openControlCenter = Notification.Name("Richy.openControlCenter")
    /// `object` ist der rawValue einer `Feature`, deren Seite die Kommandozentrale zeigen soll.
    static let showControlCenterPage = Notification.Name("Richy.showControlCenterPage")
}
