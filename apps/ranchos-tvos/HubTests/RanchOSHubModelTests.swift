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

    func testDevelopmentFixtureMakesTheOfflineBoundaryExplicit() {
        XCTAssertEqual(
            RanchOSHubDashboard.developmentFixtureBanner,
            "DEV fixture · Live tenant data is not connected")
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

    func testFinanceFixtureIsReadOnlyPresentationData() {
        let fixture = RanchOSFinanceDashboard.developmentFixture

        XCTAssertEqual(fixture.ranchName, "Ranch OS DEV")
        XCTAssertEqual(fixture.summaries.map(\.id), ["monthly-view", "household-ranch", "upcoming-bills"])
        XCTAssertEqual(fixture.summaries.map(\.status), [.ready, .review, .upcoming])
    }

    func testCompiledModuleHostSelectsOnlyTheApprovedFixtureModules() {
        let host = RanchOSModuleHost.developmentFixture

        XCTAssertEqual(host.hostedModule(for: .property).module, .property)
        XCTAssertEqual(host.hostedModule(for: .livestock).module, .livestock)
        XCTAssertEqual(host.hostedModule(for: .finance).module, .finance)
    }
}
