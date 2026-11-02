import SwiftUI

/// Die Funktionen mit Symbol, Farben und Beschreibung, wie sie in der
/// Kommandozentrale und im Menü erscheinen.
enum Feature: String, CaseIterable, Identifiable {
    case lockWidget, standBy, notch, windowFetcher, mouseWheel, appVolume, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockWidget: "Widgets"
        case .standBy: "StandBy"
        case .notch: "Notch Island"
        case .windowFetcher: "Fensterholer"
        case .mouseWheel: "Mausrad"
        case .appVolume: "Lautstärke"
        case .downloads: "Downloads-Aufräumer"
        }
    }

    var tagline: String {
        switch self {
        case .lockWidget: "Glas-Widgets auf dem Sperrbildschirm."
        case .standBy: "Große Uhr auf dem Sperrbildschirm, während der Mac lädt."
        case .notch: "Musik, Screenshots, Ablage und mehr an der Notch."
        case .windowFetcher: "Cmd + Tab bringt immer ein Fenster nach vorne."
        case .mouseWheel: "Scrollen und Zoomen mit der Maus umkehren."
        case .appVolume: "Eigene Lautstärke für jede App."
        case .downloads: "Sortiert neue Downloads nach Dateityp."
        }
    }

    var symbol: String {
        switch self {
        case .lockWidget: "rectangle.3.group"
        case .standBy: "clock"
        case .notch: "capsule.tophalf.filled"
        case .windowFetcher: "macwindow.on.rectangle"
        case .mouseWheel: "computermouse"
        case .appVolume: "speaker.wave.2"
        case .downloads: "tray.and.arrow.down"
        }
    }

    /// Ohne diese Erlaubnis funktioniert die Funktion gar nicht.
    var requiredPermission: Permissions.Kind? {
        switch self {
        case .windowFetcher, .mouseWheel: .accessibility
        case .downloads: .downloads
        case .appVolume: .audioCapture
        default: nil
        }
    }

    @MainActor func isOn(_ settings: Settings) -> Binding<Bool> {
        switch self {
        case .lockWidget: Binding(get: { settings.lockWidget }, set: { settings.lockWidget = $0 })
        case .standBy: Binding(get: { settings.standBy }, set: { settings.standBy = $0 })
        case .notch: Binding(get: { settings.notch }, set: { settings.notch = $0 })
        case .windowFetcher: Binding(get: { settings.windowFetcher }, set: { settings.windowFetcher = $0 })
        case .mouseWheel: Binding(get: { settings.mouseWheel }, set: { settings.mouseWheel = $0 })
        case .appVolume: Binding(get: { settings.appVolume }, set: { settings.appVolume = $0 })
        case .downloads: Binding(get: { settings.downloadsCleaner }, set: { settings.downloadsCleaner = $0 })
        }
    }
}

/// Ruhiges, einheitliches Symbol-Feld.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(.primary.opacity(0.07))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.primary))
            .frame(width: size, height: size)
    }
}

struct PageHeader: View {
    let symbol: String
    let title: String
    let text: String
    var isOn: Binding<Bool>?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let isOn {
                Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

/// Gruppierte Fläche im Glas-Look.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Ein Schalter mit Symbol, Titel und kurzer Erklärung.
struct OptionToggle: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

/// Kleines Etikett für den Zustand einer Funktion.
struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Zeigt eine nötige Erlaubnis mit Zustand und Knopf zum Erteilen.
struct PermissionRow: View {
    let kind: Permissions.Kind
    @ObservedObject var permissions: Permissions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.system(size: 14)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.usedBy).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch permissions.status[kind] {
            case .granted:
                Label("Erlaubt", systemImage: "checkmark").foregroundStyle(.secondary).font(.callout)
            case .unavailable(let reason):
                Text(reason).font(.callout).foregroundStyle(.secondary)
            case .denied:
                Button("In Einstellungen öffnen") { permissions.openSettings(kind) }
            default:
                Button("Erlauben") { permissions.request(kind) }
            }
        }
    }
}
