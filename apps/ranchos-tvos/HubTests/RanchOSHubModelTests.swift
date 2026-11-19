import XCTest

final class RanchOSHubModelTests: XCTestCase {
    func testDevelopmentFixtureContainsOnlyTheApprovedModules() {
        XCTAssertEqual(
            RanchOSHubDashboard.developmentFixture.modules,
            [.property, .livestock, .finance])
        XCTAssertEqual(RanchOSModule.allCases.count, 3)
    }

    func testModulesHaveStableNonHealthIdentifiers() {
        let modules = RanchOSHubDashboard.developmentFixture.modules

        XCTAssertEqual(modules.map(\.rawValue), ["property", "livestock", "finance"])
        XCTAssertFalse(modules.map(\.rawValue).contains("health"))
        XCTAssertFalse(modules.map(\.title).contains("My Health"))
    }

    func testDevelopmentHubMakesThePropertyConnectionAndFixtureBoundaryExplicit() {
        XCTAssertEqual(
            RanchOSHubDashboard.developmentFixtureBanner,
            "DEV · PropertyManager live; Livestock pending; Finance not connected")
        XCTAssertEqual(
            RanchOSRuntimeEnvironment.production.hubBanner,
            "Production · PropertyManager live; Livestock pending; Finance not connected")
    }

    func testPropertyFixtureIsReadOnlyPresentationData() {
        let fixture = RanchOSPropertyDashboard.developmentFixture

        XCTAssertEqual(fixture.ranchName, "Ranch OS DEV")
        XCTAssertEqual(fixture.summaries.map(\.id), ["north-fence", "equipment-barn", "water-system"])
        XCTAssertEqual(fixture.summaries.map(\.status), [.needsAttention, .upcoming, .current])
    }

    func testPropertyFixtureHasAClosedReadOnlySnapshotForEachKnownAsset() {
        let fixture = RanchOSPropertyDashboard.developmentFixture

        XCTAssertEqual(
            fixture.snapshots.map(\.asset),
            [.northPastureFence, .equipmentBarn, .waterSystem])
        XCTAssertEqual(
            fixture.snapshot(for: .northPastureFence).nextAction,
            "Inspect the north gate and two marked posts this week.")
        XCTAssertTrue(fixture.snapshot(for: .equipmentBarn).note.contains("Fixture only"))
    }

    func testLivestockFixtureIsReadOnlyPresentationData() {
        let fixture = RanchOSLivestockDashboard.developmentFixture

        XCTAssertEqual(fixture.ranchName, "Ranch OS DEV")
        XCTAssertEqual(fixture.herdCount, 12)
        XCTAssertEqual(fixture.summaries.map(\.id), ["care-reminders", "pasture-check", "records-review"])
        XCTAssertEqual(fixture.summaries.map(\.status), [.careDue, .current, .review])
    }

    func testFinanceScreenIsADisconnectedReportSummary() {
        let dashboard = RanchOSFinanceDashboard.developmentFixture

        XCTAssertEqual(dashboard.ranchName, "Ranch OS DEV")
        XCTAssertTrue(dashboard.summaries.isEmpty)
        XCTAssertEqual(RanchOSModule.finance.detail, "Report summary from the Finance application")
        XCTAssertEqual(RanchOSFinanceDashboard.disconnectedCardLabel, "Report summary · not connected")
        XCTAssertTrue(RanchOSFinanceDashboard.disconnectedBanner.contains("not connected"))
        XCTAssertTrue(RanchOSFinanceDashboard.disconnectedBanner.contains("No finance data is loaded here."))
    }

    func testBuildInfoDisplayAlwaysShowsDevVersionAndBuild() {
        let display = RanchOSBuildInfo.display

        XCTAssertEqual(RanchOSBuildInfo.productName, "RanchOS DEV")
        XCTAssertEqual(RanchOSBuildInfo.environmentName, "DEV")
        XCTAssertTrue(display.hasPrefix("RanchOS DEV · Version "), display)
        XCTAssertTrue(display.contains(" · Build "), display)
        XCTAssertEqual(RanchOSBuildInfo.versionAndBuild, "Version \(RanchOSBuildInfo.version) · Build \(RanchOSBuildInfo.build)")
        XCTAssertTrue(RanchOSBuildInfo.accessibilityLabel.contains("development"))
        XCTAssertTrue(RanchOSBuildInfo.accessibilityLabel.contains("Version"))
        XCTAssertTrue(RanchOSBuildInfo.accessibilityLabel.contains("Build"))
    }

    func testCompiledModuleHostSelectsOnlyTheApprovedFixtureModules() {
        let host = RanchOSModuleHost.developmentFixture

        XCTAssertEqual(host.hostedModule(for: .property).module, .property)
        XCTAssertEqual(host.hostedModule(for: .livestock).module, .livestock)
        XCTAssertEqual(host.hostedModule(for: .finance).module, .finance)
    }
}
