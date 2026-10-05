import XCTest

final class RanchOSPropertyLiveStoreTests: XCTestCase {
    func testLiveTaskPayloadDecodesOnlyReadableTaskFields() throws {
        let data = try XCTUnwrap("""
        [{"id":"task-1","item":"Inspect north gate","area":"North pasture","next_due":"2026-09-18T10:00:00.000Z","is_active":true,"priority":"High"}]
        """.data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(dashboard.activeTaskCount, 1)
        XCTAssertEqual(dashboard.tasks.first?.title, "Inspect north gate")
        XCTAssertEqual(dashboard.tasks.first?.area, "North pasture")
        XCTAssertEqual(dashboard.tasks.first?.detail, "North pasture · Due 2026-09-18T10:00:00.000Z")
    }

    func testMalformedLiveTaskIsExcludedRatherThanInvented() throws {
        let data = try XCTUnwrap("[{\"id\":\"task-1\"},{\"id\":\"task-2\",\"item\":\"Inspect water\"}]".data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(dashboard.tasks.map(\.id), ["task-2"])
    }
}
