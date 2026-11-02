import SwiftUI

/// Karte in der Kommandozentrale: Rook Search laden, öffnen oder aktualisieren.
struct RookSearchCard: View {
    @ObservedObject var installer: RookSearchInstaller

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "magnifyingglass")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rook Search").font(.headline)
                    Text("Der Browser dazu: Safari-Engine, Werbeblocker eingebaut, deine Daten bleiben auf dem Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                status
                Spacer(minLength: 0)
                buttons
            }
        }
        .onAppear { installer.refresh() }
    }

    @ViewBuilder private var status: some View {
        switch installer.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 160)
            Text("Lädt … \(Int(fraction * 100)) %").font(.callout).foregroundStyle(.secondary).monospacedDigit()
        case .installing:
            ProgressView().controlSize(.small)
            Text("Wird installiert …").font(.callout).foregroundStyle(.secondary)
        case .failed(let problem):
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        case .idle:
            if installer.installedURL != nil {
                StatusChip(text: "Installiert", color: .green)
            } else {
                StatusChip(text: "Nicht installiert", color: .secondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if case .failed = installer.phase {
            Button("Download-Seite öffnen") { NSWorkspace.shared.open(RookSearchInstaller.website) }
            Button("Nochmal versuchen") { installer.install() }
        } else if installer.installedURL != nil {
            Button("Aktualisieren") { installer.install() }.disabled(installer.isBusy)
            Button("Öffnen") { installer.open() }.buttonStyle(.borderedProminent).disabled(installer.isBusy)
        } else {
            Button("Laden & installieren") { installer.install() }
                .buttonStyle(.borderedProminent)
                .disabled(installer.isBusy)
        }
    }
}
