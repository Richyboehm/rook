import SwiftUI

/// Größe des Fensters und gewählte Position; das Fenster deckt den freien Bereich
/// zwischen Uhr und Benutzerfeld ab. Transparente Stellen sind für Klicks durchlässig.
@MainActor
final class WidgetLayout: ObservableObject {
    @Published var canvas = CGSize(width: 480, height: 460)
    @Published var placement: Placement = .middle
    /// Läuft der Fortschrittsbalken gerade (sichtbar, Musik läuft, Bildschirm an)?
    @Published var ticking = false
}

struct WidgetView: View {
    @ObservedObject var spotify: Spotify
    @ObservedObject var layout: WidgetLayout
    @State private var expanded = false

    private let padding: CGFloat = 16

    /// Cover-Größe in der großen Ansicht, passend zur verfügbaren Höhe.
    private var largeArtwork: CGFloat { min(240, max(layout.canvas.height - 220, 120)) }
    private var artworkSize: CGFloat { expanded ? largeArtwork : 64 }

    private var restingAlignment: Alignment {
        switch layout.placement {
        case .top: .top
        case .middle: .center
        case .bottom: .bottom
        }
    }

    var body: some View {
        // Eine einzige Karte, deren Anordnung wechselt: So bleibt jedes Element dasselbe
        // und SwiftUI kann Größe und Position durchgehend animieren.
        let cardLayout = expanded
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(spacing: 14))

        cardLayout {
            artwork
            info
            controls
        }
        .padding(padding)
        .frame(width: expanded ? largeArtwork + padding * 2 : 400)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: expanded ? 36 : 28, style: .continuous))
        .environment(\.colorScheme, .dark)
        .frame(width: layout.canvas.width, height: layout.canvas.height,
               alignment: expanded ? .center : restingAlignment)
    }

    private func toggle() {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { expanded.toggle() }
    }

    private var artwork: some View {
        Group {
            if let image = spotify.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.12)
                    .overlay(Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)))
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 20 : 14, style: .continuous))
        .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 14, y: 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spotify.track?.name ?? "")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(spotify.track?.artist ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            progress.padding(.top, 6)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Balken und Zeiten teilen sich einen Takt von einer Sekunde. Steht der Balken
    /// (pausiert, ausgeblendet, Bildschirm aus), läuft gar kein Takt.
    @ViewBuilder private var progress: some View {
        if layout.ticking {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressContent(elapsed: elapsed(at: context.date))
            }
        } else {
            progressContent(elapsed: elapsed(at: spotify.positionDate))
        }
    }

    /// Aktuelle Position in Sekunden, zwischen Spotifys Meldungen weitergerechnet.
    private func elapsed(at date: Date) -> Double {
        let value = spotify.position + (spotify.isPlaying ? date.timeIntervalSince(spotify.positionDate) : 0)
        return min(max(value, 0), spotify.track?.duration ?? 0)
    }

    private func progressContent(elapsed: Double) -> some View {
        let duration = spotify.track?.duration ?? 0
        return VStack(spacing: 6) {
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geo.size.width * elapsed / max(duration, 1))
                    }
            }
            .frame(height: 4)
            if expanded {
                HStack {
                    Text(format(elapsed))
                    Spacer()
                    Text("-" + format(duration - elapsed))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .transition(.opacity)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var controls: some View {
        HStack(spacing: expanded ? 26 : 14) {
            button("backward.fill", size: 16, action: spotify.previous)
            button(spotify.isPlaying ? "pause.fill" : "play.fill", size: 22, action: spotify.playPause)
            button("forward.fill", size: 16, action: spotify.next)
        }
        // Skalieren statt Schriftgröße ändern, damit die Tasten flüssig mitwachsen.
        .scaleEffect(expanded ? 1.35 : 1)
        .padding(.vertical, expanded ? 6 : 0)
        .padding(.trailing, expanded ? 0 : 4)
        .frame(maxWidth: expanded ? .infinity : nil)
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
