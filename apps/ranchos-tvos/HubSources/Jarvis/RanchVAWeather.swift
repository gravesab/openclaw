#if !os(tvOS)
import Foundation
import Observation
import SwiftUI

struct RanchVAWeatherLocation: Codable, Sendable {
    let label: String
    let latitude: Double
    let longitude: Double
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    static func load() -> Self? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: directory.appending(path: "RanchOS DEV/weather-location.json")),
              let location = try? JSONDecoder().decode(Self.self, from: data), location.isValid else { return nil }
        return location
    }
}

struct RanchVAWeatherPeriod: Decodable, Identifiable, Sendable {
    let number: Int
    let name: String
    let startTime: Date
    let endTime: Date
    let temperature: Double
    let temperatureUnit: String
    let windSpeed: String
    let windDirection: String
    let shortForecast: String
    let detailedForecast: String
    let probabilityOfPrecipitation: Probability?
    struct Probability: Decodable, Sendable { let value: Double? }
    var id: Int { number }
    var temperatureText: String { "\(temperature.formatted(.number.precision(.fractionLength(0))))°\(temperatureUnit)" }
}
struct RanchVAWeatherForecast: Decodable, Sendable {
    let updateTime: Date
    let periods: [RanchVAWeatherPeriod]
    private struct Envelope: Decodable { let properties: RanchVAWeatherForecast }
    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Envelope.self, from: data).properties
        guard !result.periods.isEmpty else { throw WeatherFailure.invalidData }
        return result
    }
    func upcoming(at now: Date) -> [RanchVAWeatherPeriod] { periods.filter { $0.endTime > now } }
}
private enum WeatherFailure: Error { case invalidData, unavailable }

@MainActor @Observable final class RanchVAWeatherStore {
    private(set) var forecast: RanchVAWeatherForecast?
    private(set) var fetchedAt: Date?
    private(set) var sourceURL: URL?
    private(set) var isLoading = false
    private(set) var message = "Forecast not loaded."
    let location: RanchVAWeatherLocation?
    private let offline: Bool
    private let fetch: @Sendable (URLRequest) async throws -> Data

    init(location: RanchVAWeatherLocation? = .load(), offline: Bool = RanchOSLaunchMode.resolve() == .offlineVerification,
         fetch: @escaping @Sendable (URLRequest) async throws -> Data = RanchVAWeatherStore.fetch) {
        self.location = location
        self.offline = offline
        self.fetch = fetch
    }
    nonisolated static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "api.weather.gov" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
    nonisolated private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, allowed(url) else { throw WeatherFailure.unavailable }
        return data
    }
    private func read(_ url: URL) async throws -> Data {
        guard Self.allowed(url) else { throw WeatherFailure.invalidData }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("RanchOS-DEV/1.0 (personal native weather client)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        return try await fetch(request)
    }
    func refresh() async {
        guard !isLoading else { return }
        guard !offline else { message = "Weather unavailable during offline verification."; return }
        guard let location, location.isValid else { message = "No fixed weather location configured on this device."; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let coordinates = String(format: "%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), location.latitude, location.longitude)
            guard let point = URL(string: "https://api.weather.gov/points/\(coordinates)") else { throw WeatherFailure.invalidData }
            struct Points: Decodable {
                struct Properties: Decodable { let forecast: URL }
                let properties: Properties
            }
            let points = try JSONDecoder().decode(Points.self, from: await read(point))
            let result = try RanchVAWeatherForecast.decode(await read(points.properties.forecast))
            guard !result.upcoming(at: .now).isEmpty else { throw WeatherFailure.invalidData }
            forecast = result
            sourceURL = points.properties.forecast
            fetchedAt = .now
            message = "National Weather Service · Fixed location forecast"
        } catch {
            message = forecast == nil ? "Weather unavailable. Try Refresh weather." : "Refresh failed. Showing the previously fetched forecast."
        }
    }
    var answer: String {
        guard let forecast, let period = forecast.upcoming(at: .now).first else { return message }
        return "\(location?.label ?? "Configured location") · \(period.name): \(period.detailedForecast) Forecast issued \(forecast.updateTime.formatted()). \(message)"
    }
}

@MainActor struct RanchVAWeatherCard: View {
    let store: RanchVAWeatherStore
    @State private var showsDetails = false
    @State private var selectedPeriod: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Weather · \(store.location?.label ?? "Location not set")", systemImage: "cloud.sun")
                    .font(.headline)
                Spacer()
                Button("Refresh weather") { Task { await store.refresh() } }.disabled(store.isLoading)
            }
            if store.isLoading { ProgressView("Loading forecast…") }
            if let forecast = store.forecast {
                let periods = forecast.upcoming(at: .now)
                if periods.isEmpty { Text("The stored forecast has expired. Refresh weather.") }
                ForEach(Array(periods.prefix(3))) { period in
                    Button {
                        selectedPeriod = period.id
                        showsDetails = true
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(period.name) · \(period.temperatureText)").fontWeight(.semibold)
                            Text(period.shortForecast).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityHint("Opens the detailed forecast for \(period.name)")
                }
                Button("View full forecast", systemImage: "list.bullet.rectangle") {
                    selectedPeriod = periods.first?.id
                    showsDetails = true
                }.disabled(periods.isEmpty)
                Text("NWS forecast · Issued \(forecast.updateTime.formatted())").font(.caption).foregroundStyle(.secondary)
                if Date.now.timeIntervalSince(forecast.updateTime) > 6 * 3600 {
                    Label("Forecast is over six hours old", systemImage: "clock.badge.exclamationmark").font(.caption)
                }
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary)
        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .task { if store.forecast == nil { await store.refresh() } }
        .sheet(isPresented: $showsDetails) {
            RanchVAWeatherDetails(store: store, expandedPeriod: selectedPeriod)
        }
    }
}

/// DisclosureGroup style without the default focus ring: a plain chevron
/// button that rotates on expand. Kills the blue focus rectangle macOS
/// draws around default disclosure labels.
struct RanchVAForecastDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    configuration.label
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            if configuration.isExpanded { configuration.content.padding(.top, 8) }
        }
    }
}

@MainActor private struct RanchVAWeatherDetails: View {
    let store: RanchVAWeatherStore
    @State var expandedPeriod: Int?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(store.location?.label ?? "Configured location").font(.title2.bold())
                    Text(store.message).font(.caption).foregroundStyle(.secondary)
                    if let forecast = store.forecast {
                        let periods = forecast.upcoming(at: .now)
                        if periods.isEmpty { Text("This forecast has expired. Close and refresh weather.") }
                        ForEach(periods) { period in
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedPeriod == period.id },
                                set: { expandedPeriod = $0 ? period.id : nil })) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(period.detailedForecast)
                                    LabeledContent("Wind", value: "\(period.windDirection) \(period.windSpeed)")
                                    LabeledContent("Precipitation chance", value: period.probabilityOfPrecipitation?.value.map { "\($0.formatted())%" } ?? "Not supplied")
                                    Text("\(period.startTime.formatted()) – \(period.endTime.formatted())")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(period.name) · \(period.temperatureText)").font(.headline)
                                    Text(period.shortForecast).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .buttonStyle(.plain)
                                .focusable(false)
                                .focusEffectDisabled()
                                .disclosureGroupStyle(RanchVAForecastDisclosureStyle())
                        }
                        Text("Forecast issued \(forecast.updateTime.formatted())").font(.caption)
                        if let time = store.fetchedAt { Text("Retrieved \(time.formatted())").font(.caption) }
                        if let source = store.sourceURL { Link("National Weather Service source", destination: source) }
                        Text("Forecast periods, not current thermometer readings. Times use this device’s time zone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .navigationTitle("Forecast details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.69, green: 0.51, blue: 0.12))
                        .keyboardShortcut(.defaultAction)
                        .focusable(false)
                        .focusEffectDisabled()
                }
            }
        }.frame(minWidth: 320, idealWidth: 640, minHeight: 450, idealHeight: 650)
    }
}
#endif
