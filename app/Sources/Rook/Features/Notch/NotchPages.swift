import AppKit
import SwiftUI

// Die zusätzlichen Seiten der aufgeklappten Notch: Schnellnotiz und Lautstärke.

private struct NotchPageHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
            Spacer(minLength: 0)
            trailing
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
    }
}

private struct SmallButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Schnellnotiz

/// Ein Textfeld, das sich alles merkt, auch nach einem Neustart.
struct NotePage: View {
    var active = true
    @AppStorage("notchNote") private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchPageHeader(symbol: "note.text", title: "Schnellnotiz") {
                if !text.isEmpty {
                    SmallButton(title: "Kopieren", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    SmallButton(title: "Leeren", symbol: "trash") { text = "" }
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .padding(8)
                .frame(height: 120)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Einfach lostippen …")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        // Gleich tippen können, sobald die Seite da ist.
        .onAppear { if active { DispatchQueue.main.async { focused = true } } }
        .onChange(of: active) { if active { focused = true } }
    }
}

// MARK: Lautstärke

struct VolumePage: View {
    let volume: AppVolume
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchPageHeader(symbol: "speaker.wave.2", title: "Lautstärke pro App") {
                Toggle("Lautstärke pro App", isOn: $settings.appVolume)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if settings.appVolume {
                AppVolumeList(volume: volume)
            } else {
                Text("Einschalten, um jede App einzeln lauter oder leiser zu stellen.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}
