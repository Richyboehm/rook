import SwiftUI

@MainActor
final class StandByModel: ObservableObject {
    @Published var battery = BatteryState(percent: 100, onPower: true)
    @Published var nextEvent: UpcomingEvent?
    /// Nur solange StandBy zu sehen ist, laufen Uhr und Fortschrittsbalken.
    @Published var active = false
}

/// Ganzer Bildschirm wie StandBy beim iPhone: tiefschwarz (bei Mini-LED-Bildschirmen
/// bleibt die Hintergrundbeleuchtung dort aus), links eine große Uhr, rechts Karten.
/// Nachts wird alles rot und gedimmt.
struct StandByView: View {
    @ObservedObject var spotify: Spotify
    @ObservedObject var model: StandByModel

    var body: some View {
        GeometryReader { geo in
            // Die Uhr ändert sich einmal pro Minute; das ganze Bild wird so selten neu gezeichnet.
            TimelineView(.everyMinute) { context in
                let night = isNight(context.date)
                HStack(alignment: .center, spacing: geo.size.width * 0.05) {
                    clock(context.date, height: geo.size.height)
                    VStack(spacing: 18) {
                        if spotify.track != nil { musicCard(night: night) }
                        if let event = model.nextEvent { eventCard(event) }
                        batteryCard
                    }
                    .frame(width: min(geo.size.width * 0.3, 420))
                }
                .padding(.horizontal, geo.size.width * 0.07)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .colorMultiply(night ? Color(red: 1, green: 0.22, blue: 0.18) : .white)
                .opacity(night ? 0.65 : 1)
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    private func isNight(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }

    // MARK: Uhr

    private func clock(_ date: Date, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: height * 0.34, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: height * 0.045, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, height * 0.015)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Karten

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func musicCard(night: Bool) -> some View {
        card {
            HStack(spacing: 16) {
                Group {
                    if let image = spotify.artwork {
                        Image(nsImage: image).resizable().scaledToFill()
                            .saturation(night ? 0 : 1)
                    } else {
                        Color.white.opacity(0.1)
                            .overlay(Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.5)))
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(spotify.track?.name ?? "")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(spotify.track?.artist ?? "")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    progress.padding(.top, 8)
                }
                .lineLimit(1)
            }
        }
    }

    /// Tickt nur, solange StandBy zu sehen ist und Musik läuft – und dann nur alle 5 Sekunden.
    @ViewBuilder private var progress: some View {
        if model.active && spotify.isPlaying {
            TimelineView(.periodic(from: .now, by: 5)) { context in progressBar(at: context.date) }
        } else {
            progressBar(at: spotify.positionDate)
        }
    }

    private func progressBar(at date: Date) -> some View {
        let duration = max(spotify.track?.duration ?? 0, 1)
        let elapsed = spotify.position + (spotify.isPlaying ? date.timeIntervalSince(spotify.positionDate) : 0)
        return GeometryReader { geo in
            Capsule().fill(.white.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.8))
                        .frame(width: geo.size.width * min(max(elapsed / duration, 0), 1))
                }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.4), value: elapsed)
    }

    private func eventCard(_ event: UpcomingEvent) -> some View {
        card {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(event.color).frame(width: 6, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(eventTime(event.start))
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func eventTime(_ start: Date) -> String {
        let time = start.formatted(.dateTime.hour().minute())
        return Calendar.current.isDateInToday(start) ? "Heute, \(time)" : "Morgen, \(time)"
    }

    private var batteryCard: some View {
        card {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                    Circle().trim(from: 0, to: CGFloat(model.battery.percent) / 100)
                        .stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.green)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.battery.percent) %")
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(model.battery.percent >= 100 ? "Voll geladen" : "Wird geladen")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}
