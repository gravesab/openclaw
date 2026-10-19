import Foundation
import Observation
import SwiftUI

/// Fetch boundary for the DEV forecast brief. GET only; production uses
/// URLSession while tests inject a scripted provider. Mirrors the Livestock
/// authorized-read provider pattern.
protocol RanchOSForecastFetchProvider: Sendable {
    func fetchForecast(request: URLRequest) async throws -> (Data, URLResponse)
}

struct RanchOSForecastURLSessionProvider: RanchOSForecastFetchProvider {
    func fetchForecast(request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// DEV-only ranch forecast brief for the RanchOS home dashboard.
///
/// WeatherKit is the Apple-first choice, but enabling it requires the
/// WeatherKit App ID capability with signing and entitlement changes that are
/// out of scope for this DEV step. This step therefore uses the free keyless
/// Open-Meteo API. The store uses fixed coarse stand-in coordinates only: no
/// CoreLocation and no live user tracking. The card starts unloaded and
/// fetches only after the user taps Load forecast; the stand-in location
/// stays labeled.
@MainActor
@Observable
final class RanchOSForecastStore {
    enum State: Equatable {
        case idle
        case loading
        case ready(RanchOSForecastBrief)
        case unavailable(String)
    }

    // Coarse 1-decimal DEV stand-in (central Texas, America/Chicago).
    // Production must use the ranch's configured location.
    nonisolated private static let latitude = 30.3
    nonisolated private static let longitude = -97.7
    nonisolated private static let timeZone = "America/Chicago"

    nonisolated static let provenanceLabel = "DEV forecast · Open-Meteo · stand-in location"
    nonisolated static let idleLabel =
        "Forecast is not loaded. Loading sends the coarse DEV stand-in location to Open-Meteo."

    private(set) var state: State = .idle
    private let provider: any RanchOSForecastFetchProvider

    init(provider: (any RanchOSForecastFetchProvider)? = nil) {
        self.provider = provider ?? RanchOSForecastURLSessionProvider()
    }

    func refresh() async {
        state = .loading
        do {
            var request = URLRequest(url: Self.requestURL())
            request.httpMethod = "GET"
            request.timeoutInterval = 20

            let (data, response) = try await provider.fetchForecast(request: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ForecastError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw ForecastError.httpStatus(httpResponse.statusCode)
            }

            state = .ready(try RanchOSForecastBrief.decode(from: data))
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    nonisolated static func requestURL() -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: timeZone),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return components.url!
    }
}

enum ForecastError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The DEV forecast returned an invalid response."
        case .httpStatus(let code): "The DEV forecast is unavailable (HTTP \(code))."
        }
    }
}

struct RanchOSForecastBrief: Equatable {
    let currentTemperature: Int
    let condition: String
    let symbolName: String
    let highTemperature: Int
    let lowTemperature: Int

    var summary: String {
        "\(currentTemperature)\u{00B0} \u{00B7} \(condition)"
    }

    var rangeDetail: String {
        "High \(highTemperature)\u{00B0} \u{00B7} Low \(lowTemperature)\u{00B0}"
    }

    /// WMO weather interpretation codes per the Open-Meteo API docs.
    static func condition(for code: Int) -> (description: String, symbolName: String) {
        switch code {
        case 0: ("Clear sky", "sun.max.fill")
        case 1: ("Mainly clear", "sun.max.fill")
        case 2: ("Partly cloudy", "cloud.sun.fill")
        case 3: ("Overcast", "cloud.fill")
        case 45, 48: ("Fog", "cloud.fog.fill")
        case 51, 53, 55: ("Drizzle", "cloud.drizzle.fill")
        case 56, 57: ("Freezing drizzle", "cloud.drizzle.fill")
        case 61, 63, 65, 80, 81, 82: ("Rain", "cloud.rain.fill")
        case 66, 67: ("Freezing rain", "cloud.rain.fill")
        case 71, 73, 75, 77, 85, 86: ("Snow", "cloud.snow.fill")
        case 95, 96, 99: ("Thunderstorm", "cloud.bolt.rain.fill")
        default: ("Conditions unavailable", "cloud.fill")
        }
    }

    static func decode(from data: Data) throws -> RanchOSForecastBrief {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let currentTemperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int,
              let daily = object["daily"] as? [String: Any],
              let maximums = daily["temperature_2m_max"] as? [Double],
              let minimums = daily["temperature_2m_min"] as? [Double],
              let high = maximums.first,
              let low = minimums.first
        else {
            throw ForecastError.invalidResponse
        }

        let condition = condition(for: code)
        return RanchOSForecastBrief(
            currentTemperature: Int(currentTemperature.rounded()),
            condition: condition.description,
            symbolName: condition.symbolName,
            highTemperature: Int(high.rounded()),
            lowTemperature: Int(low.rounded()))
    }
}

struct RanchOSForecastBriefCard: View {
    @State private var store = RanchOSForecastStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Today's forecast", systemImage: "cloud.sun.fill")
                .font(.headline)

            switch store.state {
            case .idle:
                Text(RanchOSForecastStore.idleLabel)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
                Button("Load forecast") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Loads the DEV forecast for the stand-in ranch location")
            case .loading:
                ProgressView("Loading forecast\u{2026}")
            case .ready(let brief):
                HStack(spacing: 14) {
                    Image(systemName: brief.symbolName)
                        .font(.system(size: 34, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(brief.summary)
                            .font(.title2.weight(.semibold))
                        Text(brief.rangeDetail)
                            .font(.subheadline)
                            .foregroundStyle(detailColor)
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await store.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
                Text(RanchOSForecastStore.provenanceLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(detailColor)
            case .unavailable(let message):
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
                Button("Retry") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(titleColor)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

#if os(tvOS)
    private var titleColor: Color { .white }
    private var detailColor: Color { .white.opacity(0.72) }
    private var cardBackground: Color { .white.opacity(0.13) }
#else
    // Matches the RanchOSTheme ink, muted ink, and card fills without
    // crossing the file-private theme boundary.
    private var titleColor: Color { Color(red: 0.09, green: 0.13, blue: 0.10) }
    private var detailColor: Color { Color(red: 0.28, green: 0.33, blue: 0.27) }
    private var cardBackground: Color { .white.opacity(0.72) }
#endif
}
