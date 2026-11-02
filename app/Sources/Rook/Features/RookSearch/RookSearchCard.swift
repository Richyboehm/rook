import SwiftUI

/// Zustand von Rook Search in der Kommandozentrale: liegt er in Programme, wartet ein Update.
struct RookSearchCard: View {
    @ObservedObject var rookSearch: RookSearch
    let isOn: Bool

    var body: some View {
        Card(title: "Browser") {
            HStack(spacing: 10) {
                status
                Spacer(minLength: 0)
                if rookSearch.waitingForQuit {
                    Button("Jetzt neu starten") { rookSearch.restartNow() }
                }
                if rookSearch.isInstalled {
                    Button("Öffnen") { rookSearch.open() }.buttonStyle(.borderedProminent)
                }
            }
            Text("Rook Search steckt in Rook und wird mit Rook zusammen aktualisiert. Ausschalten legt ihn in den Papierkorb; Tabs, Favoriten und Verlauf bleiben auf deinem Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { rookSearch.refresh() }
    }

    @ViewBuilder private var status: some View {
        if rookSearch.busy {
            ProgressView().controlSize(.small)
            Text("Wird in Programme gelegt …").font(.callout).foregroundStyle(.secondary)
        } else if let problem = rookSearch.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        } else if rookSearch.waitingForQuit {
            StatusChip(text: "Neue Version kommt beim Beenden", color: .orange)
        } else if let version = rookSearch.installedVersion {
            StatusChip(text: "In Programme · Version \(version)", color: .green)
        } else {
            StatusChip(text: isOn ? "Wird vorbereitet" : "Aus", color: .secondary)
        }
    }
}

/// Version von Rook und, wenn es eine neue gibt, der Knopf zum Aktualisieren (Rook samt Browser).
struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 140)
                Text("Lädt … \(Int(fraction * 100)) %").foregroundStyle(.secondary).monospacedDigit()
            case .installing:
                ProgressView().controlSize(.small)
                Text("Wird installiert, Rook startet gleich neu …").foregroundStyle(.secondary)
            case .failed(let problem):
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Download-Seite") { NSWorkspace.shared.open(Updater.website) }
                Button("Nochmal") { updater.install() }
            case .idle:
                if updater.updateAvailable, let latest = updater.latest {
                    StatusChip(text: "Neu: Version \(latest.version)", color: .orange)
                    Spacer(minLength: 0)
                    Button("Aktualisieren") { updater.install() }.buttonStyle(.borderedProminent)
                } else {
                    StatusChip(text: updater.latest == nil ? "Version \(Updater.current.version)"
                                                           : "Aktuell · Version \(Updater.current.version)", color: .green)
                }
            }
        }
        .font(.callout)
        .onAppear { updater.check() }
    }
}
