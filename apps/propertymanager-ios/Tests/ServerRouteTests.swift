import XCTest
@testable import PropertyManager

final class ServerRouteTests: XCTestCase {
    private let lan = URL(string: "http://intelmini.local:5062")!
    private let tailscale = URL(string: "http://100.85.36.72:5062")!

    private actor ProbeLog {
        private(set) var probed: [URL] = []
        func record(_ url: URL) { probed.append(url) }
    }

    func testWiFiTriesTheLANAddressFirstAndCellularGoesStraightToTailscale() {
        let route = ServerRoute(lan: lan, tailscale: tailscale)

        XCTAssertEqual(route.candidates(onLocalNetwork: true).map(\.url), [lan, tailscale])
        XCTAssertEqual(route.candidates(onLocalNetwork: false).map(\.url), [tailscale])
        XCTAssertEqual(ServerRoute.fixed(lan).candidates(onLocalNetwork: true).map(\.url), [lan])
    }

    func testLANIsUsedWhenItAnswers() async {
        let log = ProbeLog()
        let resolver = ServerRouteResolver { url in await log.record(url); return true }

        let chosen = await resolver.resolve(ServerRoute(lan: lan, tailscale: tailscale), onLocalNetwork: true)

        XCTAssertEqual(chosen, .init(url: lan, via: .lan))
        let probed = await log.probed
        XCTAssertEqual(probed, [lan])
    }

    func testTailscaleIsUsedWhenTheLANAddressDoesNotAnswer() async {
        let lan = self.lan
        let resolver = ServerRouteResolver { url in url != lan }

        let chosen = await resolver.resolve(ServerRoute(lan: lan, tailscale: tailscale), onLocalNetwork: true)

        XCTAssertEqual(chosen, .init(url: tailscale, via: .tailscale))
    }

    func testOffWiFiTheLANAddressIsNeverTried() async {
        let log = ProbeLog()
        let resolver = ServerRouteResolver { url in await log.record(url); return true }

        let chosen = await resolver.resolve(ServerRoute(lan: lan, tailscale: tailscale), onLocalNetwork: false)

        XCTAssertEqual(chosen.via, .tailscale)
        let probed = await log.probed
        XCTAssertEqual(probed, [tailscale])
    }

    func testAChoiceIsKeptUntilForgottenAndALANChoiceIsDroppedOffWiFi() async {
        let log = ProbeLog()
        let resolver = ServerRouteResolver { url in await log.record(url); return true }
        let route = ServerRoute(lan: lan, tailscale: tailscale)

        _ = await resolver.resolve(route, onLocalNetwork: true)
        _ = await resolver.resolve(route, onLocalNetwork: true)
        let offWiFi = await resolver.resolve(route, onLocalNetwork: false)
        await resolver.forgetChoices()
        _ = await resolver.resolve(route, onLocalNetwork: true)

        XCTAssertEqual(offWiFi.via, .tailscale)
        let probed = await log.probed
        XCTAssertEqual(probed, [lan, tailscale, lan])
    }

    func testWhenNothingAnswersTheTailscaleAddressIsReported() async {
        let resolver = ServerRouteResolver { _ in false }

        let chosen = await resolver.resolve(ServerRoute(lan: lan, tailscale: tailscale), onLocalNetwork: true)

        XCTAssertEqual(chosen, .init(url: tailscale, via: .tailscale))
    }

    func testOnlyFailuresBeforeAnyServerAreSafeToResend() {
        XCTAssertTrue(ServerRouteResolver.neverReachedServer(URLError(.cannotConnectToHost)))
        XCTAssertTrue(ServerRouteResolver.neverReachedServer(URLError(.cannotFindHost)))
        XCTAssertTrue(ServerRouteResolver.neverReachedServer(URLError(.notConnectedToInternet)))
        // The server may already have applied a write that timed out or lost its connection.
        XCTAssertFalse(ServerRouteResolver.neverReachedServer(URLError(.timedOut)))
        XCTAssertFalse(ServerRouteResolver.neverReachedServer(URLError(.networkConnectionLost)))
        XCTAssertFalse(ServerRouteResolver.neverReachedServer(CocoaError(.fileReadCorruptFile)))
    }

    @MainActor
    func testPathWatcherStartsOffTheLocalNetworkUntilItReports() {
        let watcher = NetworkPathWatcher {}
        if !watcher.hasReportedPath {
            XCTAssertFalse(watcher.onLocalNetwork)
        }
    }

    func testOnlyConnectionFailuresCountAsUnreachable() {
        XCTAssertTrue(ServerRouteResolver.isUnreachable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(ServerRouteResolver.isUnreachable(URLError(.timedOut)))
        XCTAssertTrue(ServerRouteResolver.isUnreachable(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ServerRouteResolver.isUnreachable(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(ServerRouteResolver.isUnreachable(CocoaError(.fileReadCorruptFile)))
    }

    @MainActor
    func testSettingsKeepTheBuiltInAddressAutomaticAndUseATypedAddressAsIs() {
        let automatic = PropertyStore.route(
            stored: "http://100.85.36.72:5062/", tailscaleDefault: "http://100.85.36.72:5062", lanDefault: "http://intelmini.local:5062"
        )
        XCTAssertEqual(automatic, ServerRoute(lan: lan, tailscale: tailscale))

        let typed = PropertyStore.route(
            stored: " http://10.0.0.9:5062 ", tailscaleDefault: "http://100.85.36.72:5062", lanDefault: "http://intelmini.local:5062"
        )
        XCTAssertEqual(typed, .fixed(URL(string: "http://10.0.0.9:5062")!))
        XCTAssertNil(PropertyStore.route(stored: "not a url", tailscaleDefault: "http://100.85.36.72:5062", lanDefault: nil))
    }

    /// Older builds saved the Intel Mini's Wi-Fi IP, which then failed on cellular.
    @MainActor
    func testASavedWiFiAddressOfTheBuiltInServerStillRoutesOverTailscale() {
        for saved in ["http://192.168.50.104:5062", "http://intelmini.local:5062/"] {
            let route = PropertyStore.route(
                stored: saved,
                tailscaleDefault: "http://100.85.36.72:5062",
                lanDefault: "http://intelmini.local:5062",
                otherAddresses: ["http://192.168.50.104:5062"]
            )
            XCTAssertEqual(route, ServerRoute(lan: lan, tailscale: tailscale), saved)
            XCTAssertEqual(route?.candidates(onLocalNetwork: false), [.init(url: tailscale, via: .tailscale)], saved)
        }
    }
}
