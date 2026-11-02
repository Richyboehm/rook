import Foundation

struct WeatherNow: Equatable {
    var place: String
    var temperature: Int
    var symbol: String
    var text: String
}

/// Wetter vom freien Dienst Open-Meteo (ohne Konto). Gesendet wird nur der eingegebene
/// Ort. Abgefragt wird höchstens einmal pro Stunde und nur, wenn das Widget gebraucht wird.
@MainActor
final class WeatherService: ObservableObject {
    @Published private(set) var current: WeatherNow?
    @Published private(set) var problem: String?

    private var lastFetch: Date?
    private var lastPlace = ""
    private var loading = false

    func refreshIfNeeded(place rawPlace: String) {
        let place = rawPlace.trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty else {
            current = nil
            problem = "Kein Ort eingegeben"
            return
        }
        if place == lastPlace, let lastFetch, Date().timeIntervalSince(lastFetch) < 3600 { return }
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                current = try await Self.fetch(place: place)
                problem = nil
                lastFetch = Date()
                lastPlace = place
            } catch {
                problem = (error as? WeatherError)?.message ?? "Wetter gerade nicht erreichbar"
            }
        }
    }

    private struct WeatherError: Error { let message: String }

    private static func fetch(place: String) async throws -> WeatherNow {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "1"), .init(name: "language", value: "de")]
        struct GeoResult: Decodable {
            struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double }
            let results: [Place]?
        }
        let (geoData, _) = try await URLSession.shared.data(from: geo.url!)
        guard let found = try JSONDecoder().decode(GeoResult.self, from: geoData).results?.first else {
            throw WeatherError(message: "Ort „\(place)“ nicht gefunden")
        }

        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(found.latitude)),
            .init(name: "longitude", value: String(found.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "timezone", value: "auto"),
        ]
        struct Forecast: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            let current: Current
        }
        let (data, _) = try await URLSession.shared.data(from: forecast.url!)
        let now = try JSONDecoder().decode(Forecast.self, from: data).current
        let (symbol, text) = describe(code: now.weather_code, day: now.is_day == 1)
        return WeatherNow(place: found.name, temperature: Int(now.temperature_2m.rounded()), symbol: symbol, text: text)
    }

    /// WMO-Wettercodes von Open-Meteo in Symbol und Text.
    private static func describe(code: Int, day: Bool) -> (String, String) {
        switch code {
        case 0: (day ? "sun.max.fill" : "moon.stars.fill", "Klar")
        case 1, 2: (day ? "cloud.sun.fill" : "cloud.moon.fill", "Leicht bewölkt")
        case 3: ("cloud.fill", "Bewölkt")
        case 45, 48: ("cloud.fog.fill", "Nebel")
        case 51...57: ("cloud.drizzle.fill", "Nieselregen")
        case 61...67, 80...82: ("cloud.rain.fill", "Regen")
        case 71...77, 85, 86: ("cloud.snow.fill", "Schnee")
        case 95...99: ("cloud.bolt.rain.fill", "Gewitter")
        default: ("cloud.fill", "Bewölkt")
        }
    }
}
