import XCTest

final class RanchOSForecastStoreTests: XCTestCase {
    @MainActor
    func testStoreStartsIdleWithoutFetching() {
        XCTAssertEqual(RanchOSForecastStore().state, .idle)
    }

    @MainActor
    func testStoreNeverFetchesWithoutExplicitRefresh() async {
        let provider = CountingForecastFetchProvider()
        let store = RanchOSForecastStore(provider: provider)

        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(store.state, .idle)
        let fetchCount = await provider.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testForecastPayloadDecodesCurrentAndDailyValues() throws {
        let data = try XCTUnwrap("""
        {"current":{"temperature_2m":78.6,"weather_code":2},        "daily":{"time":["2026-09-27"],"weather_code":[2],        "temperature_2m_max":[85.2],"temperature_2m_min":[66.4]}}
        """.data(using: .utf8))

        let brief = try RanchOSForecastBrief.decode(from: data)

        XCTAssertEqual(brief.currentTemperature, 79)
        XCTAssertEqual(brief.condition, "Partly cloudy")
        XCTAssertEqual(brief.symbolName, "cloud.sun.fill")
        XCTAssertEqual(brief.highTemperature, 85)
        XCTAssertEqual(brief.lowTemperature, 66)
        XCTAssertEqual(brief.summary, "79\u{00B0} \u{00B7} Partly cloudy")
        XCTAssertEqual(brief.rangeDetail, "High 85\u{00B0} \u{00B7} Low 66\u{00B0}")
    }

    func testMalformedForecastPayloadFailsClosed() {
        for payload in ["{}", "{\"current\":{}}", "{\"current\":{\"temperature_2m\":72.0}}"] {
            XCTAssertThrowsError(
                try RanchOSForecastBrief.decode(from: Data(payload.utf8)),
                "payload must not decode: \(payload)")
        }
    }

    func testWeatherCodeMappingCoversDocumentedCodes() {
        XCTAssertEqual(RanchOSForecastBrief.condition(for: 0).description, "Clear sky")
        XCTAssertEqual(RanchOSForecastBrief.condition(for: 3).symbolName, "cloud.fill")
        XCTAssertEqual(RanchOSForecastBrief.condition(for: 45).description, "Fog")
        XCTAssertEqual(RanchOSForecastBrief.condition(for: 63).description, "Rain")
        XCTAssertEqual(RanchOSForecastBrief.condition(for: 95).symbolName, "cloud.bolt.rain.fill")
    }

    func testUnknownWeatherCodeFallsBackWithoutInventing() {
        let condition = RanchOSForecastBrief.condition(for: 999)

        XCTAssertEqual(condition.description, "Conditions unavailable")
        XCTAssertEqual(condition.symbolName, "cloud.fill")
    }

    func testRequestUsesFixedCoarseDevLocation() throws {
        let url = RanchOSForecastStore.requestURL()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(query["latitude"], "30.3")
        XCTAssertEqual(query["longitude"], "-97.7")
        XCTAssertEqual(query["temperature_unit"], "fahrenheit")
        XCTAssertEqual(query["timezone"], "America/Chicago")
        XCTAssertEqual(query["forecast_days"], "1")
        XCTAssertEqual(query["current"], "temperature_2m,weather_code")
    }

    @MainActor
    func testRefreshShowsLoadingWhileFetchIsInFlight() async throws {
        let provider = ControllableForecastFetchProvider()
        let store = RanchOSForecastStore(provider: provider)
        let payload = try XCTUnwrap(validForecastPayloadData())

        let refresh = Task { await store.refresh() }
        await provider.waitUntilEntered()
        XCTAssertEqual(store.state, .loading)

        let url = RanchOSForecastStore.requestURL()
        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        await provider.complete(.success((payload, response)))
        await refresh.value

        guard case .ready(let brief) = store.state else {
            return XCTFail("expected ready state, got \(store.state)")
        }
        XCTAssertEqual(brief.condition, "Partly cloudy")
    }

    @MainActor
    func testRefreshFailureShowsUnavailable() async throws {
        let provider = ImmediateForecastFetchProvider(shouldFail: true)
        let store = RanchOSForecastStore(provider: provider)

        await store.refresh()

        guard case .unavailable(let message) = store.state else {
            return XCTFail("expected unavailable state, got \(store.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    @MainActor
    func testNon200StatusShowsUnavailable() async throws {
        let provider = ImmediateForecastFetchProvider(statusCode: 500)
        let store = RanchOSForecastStore(provider: provider)

        await store.refresh()

        XCTAssertEqual(store.state, .unavailable("The DEV forecast is unavailable (HTTP 500)."))
    }

    @MainActor
    func testRetryAfterFailureCanSucceed() async throws {
        let provider = ImmediateForecastFetchProvider(shouldFail: true)
        let store = RanchOSForecastStore(provider: provider)

        await store.refresh()
        guard case .unavailable = store.state else {
            return XCTFail("expected unavailable state, got \(store.state)")
        }

        await provider.setSuccess()
        await store.refresh()

        guard case .ready(let brief) = store.state else {
            return XCTFail("expected ready state, got \(store.state)")
        }
        XCTAssertEqual(brief.currentTemperature, 79)
    }
}

private func validForecastPayloadData() -> Data? {
    """
    {"current":{"temperature_2m":78.6,"weather_code":2},\
    "daily":{"time":["2026-09-27"],"weather_code":[2],\
    "temperature_2m_max":[85.2],"temperature_2m_min":[66.4]}}
    """.data(using: .utf8)
}

private struct ForecastFetchTestFailure: Error {}

private actor CountingForecastFetchProvider: RanchOSForecastFetchProvider {
    private(set) var fetchCount = 0

    func fetchForecast(request: URLRequest) async throws -> (Data, URLResponse) {
        fetchCount += 1
        throw ForecastFetchTestFailure()
    }
}

private actor ImmediateForecastFetchProvider: RanchOSForecastFetchProvider {
    private var statusCode: Int
    private var shouldFail: Bool
    private var capturedURL: URL?

    init(statusCode: Int = 200, shouldFail: Bool = false) {
        self.statusCode = statusCode
        self.shouldFail = shouldFail
    }

    func setSuccess(statusCode: Int = 200) {
        self.statusCode = statusCode
        self.shouldFail = false
    }

    func capturedRequestURL() -> URL? { capturedURL }

    func fetchForecast(request: URLRequest) async throws -> (Data, URLResponse) {
        capturedURL = request.url
        if shouldFail {
            throw ForecastFetchTestFailure()
        }
        guard let url = request.url,
              let payload = validForecastPayloadData(),
              let response = HTTPURLResponse(
                  url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        else {
            throw ForecastFetchTestFailure()
        }
        return (payload, response)
    }
}

private actor ControllableForecastFetchProvider: RanchOSForecastFetchProvider {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<(Data, URLResponse), Error>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func complete(_ result: Result<(Data, URLResponse), Error>) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(with: result)
    }

    func fetchForecast(request: URLRequest) async throws -> (Data, URLResponse) {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { self.pending = $0 }
    }
}
