import XCTest

final class RanchOSLivestockConnectionTests: XCTestCase {
    func testLivestockIsNotMarkedLiveWithoutAnAuthorizedProvider() async {
        let connection = RanchOSLivestockConnection.pending

        XCTAssertFalse(connection.hasAuthorizedProvider)
        XCTAssertEqual(connection.presentationSession, .fixture(.developmentFixture))
        XCTAssertFalse(connection.presentationSession.isLive)
        XCTAssertEqual(connection.presentationSession.banner, RanchOSLivestockConnection.pendingLabel)

        let session = await connection.resolve()
        XCTAssertEqual(session, .fixture(.developmentFixture))
        XCTAssertFalse(session.isLive)
    }

    func testAuthorizedProviderDoesNotPresentTheLocalFixtureAsLiveUntilItReads() async {
        let liveDashboard = RanchOSLivestockDashboard(
            ranchName: "Authorized read",
            herdCount: 3,
            summaries: [
                RanchOSLivestockSummary(
                    id: "authorized",
                    title: "Authorized herd",
                    detail: "Read only",
                    status: .current),
            ])
        let connection = RanchOSLivestockConnection(
            authorizedProvider: StubLivestockReadProvider(dashboard: liveDashboard))

        XCTAssertTrue(connection.hasAuthorizedProvider)
        XCTAssertEqual(
            connection.presentationSession,
            .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage))
        XCTAssertFalse(connection.presentationSession.isLive)

        let session = await connection.resolve()
        XCTAssertEqual(session, .live(liveDashboard))
        XCTAssertTrue(session.isLive)
        XCTAssertNotEqual(session, .fixture(.developmentFixture))
    }

    func testAuthorizedReadFailureUsesTheUnavailableState() async {
        let connection = RanchOSLivestockConnection(authorizedProvider: FailingLivestockReadProvider())
        let session = await connection.resolve()

        XCTAssertEqual(session, .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage))
        XCTAssertFalse(session.isLive)
    }

    func testResolveMapsCancellationToCancelledInsteadOfUnavailable() async {
        let connection = RanchOSLivestockConnection(authorizedProvider: CancellingLivestockReadProvider())
        let session = await connection.resolve()

        XCTAssertEqual(session, .cancelled)
        XCTAssertFalse(session.isLive)
        XCTAssertEqual(session.banner, "")
    }

    func testLivestockConnectionBoundaryHasNoWriteRequestMethods() {
        XCTAssertTrue(RanchOSLivestockConnection.writeRequestMethods.isEmpty)
        XCTAssertEqual(RanchOSLivestockConnectionRequestMethod.allCases.map(\.rawValue), ["GET"])
        XCTAssertTrue(RanchOSLivestockConnectionRequestMethod.allCases.allSatisfy { !$0.isWrite })
        XCTAssertEqual(RanchOSLivestockConnectionOperation.allCases, [.readDashboard])

        let writeVerbs: Set<String> = ["POST", "PATCH", "PUT", "DELETE"]
        XCTAssertTrue(writeVerbs.isDisjoint(with: Set(RanchOSLivestockConnection.writeRequestMethods)))
        XCTAssertTrue(writeVerbs.isDisjoint(with: Set(RanchOSLivestockConnectionRequestMethod.allCases.map(\.rawValue))))

        let operationNames = RanchOSLivestockConnectionOperation.allCases.map { $0.rawValue.lowercased() }
        for token in ["post", "patch", "put", "delete", "create", "update", "remove", "mutate", "write"] {
            XCTAssertFalse(
                operationNames.contains { $0.contains(token) },
                "Livestock connection operations must not include write token \(token)")
        }
    }

    func testLivestockConnectionStoresNoURLOrCredentials() {
        let labels = Mirror(reflecting: RanchOSLivestockConnection.pending).children.compactMap(\.label)
        let joined = labels.joined(separator: " ").lowercased()

        for banned in ["url", "endpoint", "host", "apikey", "credential", "password", "token", "authorization"] {
            XCTAssertFalse(joined.contains(banned), "Livestock connection must not store \(banned)")
        }
    }

    func testHealthIsAbsentFromTheHubModuleRegistry() {
        XCTAssertEqual(RanchOSModule.allCases, [.property, .livestock, .finance])
        XCTAssertEqual(RanchOSHubDashboard.developmentFixture.modules, [.property, .livestock, .finance])
        XCTAssertNil(RanchOSModule(rawValue: "health"))
        XCTAssertFalse(RanchOSModule.allCases.map(\.rawValue).contains("health"))
        XCTAssertFalse(RanchOSModule.allCases.map(\.title).contains("My Health"))
        XCTAssertFalse(RanchOSHubDashboard.developmentFixture.modules.map(\.title).contains("Health"))
    }
}

private struct StubLivestockReadProvider: RanchOSLivestockAuthorizedReadProvider {
    let dashboard: RanchOSLivestockDashboard

    func readDashboard() async throws -> RanchOSLivestockDashboard {
        dashboard
    }
}

private struct FailingLivestockReadProvider: RanchOSLivestockAuthorizedReadProvider {
    func readDashboard() async throws -> RanchOSLivestockDashboard {
        throw RanchOSLivestockReadFailure()
    }
}

private struct RanchOSLivestockReadFailure: Error {}

private struct CancellingLivestockReadProvider: RanchOSLivestockAuthorizedReadProvider {
    func readDashboard() async throws -> RanchOSLivestockDashboard {
        throw CancellationError()
    }
}
