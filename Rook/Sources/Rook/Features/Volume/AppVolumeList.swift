import SwiftUI

/// Liste der Apps mit Ton: Symbol, Name, Stumm-Knopf, Regler und Prozent.
/// Wird im Menüleisten-Fenster und in der Kommandozentrale gezeigt.
struct AppVolumeList: View {
    @ObservedObject var volume: AppVolume
    /// Kleine Schrift für das Menüleisten-Fenster.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if volume.sources.isEmpty {
                Text("Gerade ist keine App mit Ton geöffnet.")
                    .font(.system(size: compact ? 10 : 13))
                    .foregroundStyle(.tertiary)
            }
            ForEach(volume.sources) { source in row(source) }
            if let problem = volume.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ source: AppVolume.Source) -> some View {
        let level = volume.volume(of: source.id)
        return HStack(spacing: 8) {
            AppIcon(url: source.bundleURL).frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
            Text(source.name)
                .font(.system(size: compact ? 12 : 13))
                .lineLimit(1)
                .frame(width: compact ? 84 : 140, alignment: .leading)
                .foregroundStyle(source.isPlaying ? .primary : .secondary)
            Button { volume.toggleMute(source.id) } label: {
                Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(level == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(level == 0 ? "Ton an" : "Stumm")
            Slider(value: Binding(get: { Double(level) }, set: { volume.setVolume(Float($0), for: source.id) }), in: 0...1)
                .controlSize(compact ? .mini : .small)
            Text("\(Int((level * 100).rounded())) %")
                .font(.system(size: compact ? 10 : 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: compact ? 32 : 40, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(source.name)
    }
}

/// App-Symbol in kleiner Größe. Es wird nur hier, beim Anzeigen, geladen und mit der Liste
/// wieder freigegeben; im Hintergrund hält Rook keine Symbole im Speicher.
private struct AppIcon: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Color.clear }
        }
        .onAppear {
            guard image == nil, let url else { return }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            image = icon
        }
    }
}
