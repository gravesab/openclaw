import XCTest

final class RanchVAWeatherTests: XCTestCase {
    func testLocationValidation() {
        XCTAssertFalse(RanchVAWeatherLocation(label: "Test", latitude: .nan, longitude: 0).isValid)
        XCTAssertFalse(RanchVAWeatherLocation(label: "Test", latitude: 91, longitude: 0).isValid)
        XCTAssertTrue(RanchVAWeatherLocation(label: "Test", latitude: 40, longitude: -100).isValid)
    }
    func testForecastURLMustRemainOnNWSHTTPS() throws {
        for text in ["http://api.weather.gov/test", "https://example.com/forecast", "https://api.weather.gov.example.com/test"] {
            XCTAssertFalse(RanchVAWeatherStore.allowed(try XCTUnwrap(URL(string: text))))
        }
        XCTAssertTrue(RanchVAWeatherStore.allowed(try XCTUnwrap(URL(string: "https://api.weather.gov/gridpoints/TEST/1,1/forecast"))))
    }
    @MainActor func testOfflineModeNeverFetches() async {
        let store = RanchVAWeatherStore(location: .init(label: "Test", latitude: 40, longitude: -100), offline: true) { _ in
            XCTFail("Offline verification must not send weather requests")
            return Data()
        }
        await store.refresh()
        XCTAssertNil(store.forecast)
        XCTAssertTrue(store.message.contains("offline"))
    }
    func testPeriodsExpireWithoutInventingCurrentConditions() throws {
        let data = Data(#"{"properties":{"updateTime":"2026-01-01T00:00:00Z","periods":[{"number":1,"name":"Today","startTime":"2026-01-01T00:00:00Z","endTime":"2026-01-01T12:00:00Z","temperature":50,"temperatureUnit":"F","windSpeed":"5 mph","windDirection":"N","shortForecast":"Clear","detailedForecast":"Clear skies","probabilityOfPrecipitation":{"value":null}}]}}"#.utf8)
        let result = try RanchVAWeatherForecast.decode(data)
        let time = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
        XCTAssertTrue(result.upcoming(at: time).isEmpty)
        XCTAssertNil(result.periods.first?.probabilityOfPrecipitation?.value)
        XCTAssertEqual(result.periods.first?.temperatureText, "50°F")
    }
    @MainActor func testFailureDoesNotCreateSampleForecast() async {
        let store = RanchVAWeatherStore(location: .init(label: "Test", latitude: 40, longitude: -100), offline: false) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await store.refresh()
        XCTAssertNil(store.forecast)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.message.contains("unavailable"))
    }
}
