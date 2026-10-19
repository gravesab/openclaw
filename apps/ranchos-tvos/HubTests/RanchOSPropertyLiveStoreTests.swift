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
        XCTAssertEqual(dashboard.tasks.first?.categoryName, RanchOSPropertyLiveTask.uncategorizedName)
        XCTAssertEqual(dashboard.tasks.first?.detail, "Uncategorized · North pasture · Due 2026-09-18T10:00:00.000Z")
    }

    func testLiveTaskDecodesCategoryNameForDueTaskFilter() throws {
        let data = try XCTUnwrap("""
        [
          {"id":"house-1","item":"Replace filter","area":"Main house","category_name":"House","next_due":"2026-10-09T10:00:00.000Z","is_active":true},
          {"id":"grounds-1","item":"Mow lane","area":"Drive","category_name":"Grounds","next_due":"2026-10-09T10:00:00.000Z","is_active":true},
          {"id":"inactive-1","item":"Retired pump","area":"Barn","category_name":"Equipment","is_active":false},
          {"id":"blank-1","item":"Check gate","area":"North","category_name":"  ","is_active":true}
        ]
        """.data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(
            dashboard.dueTaskCategoryFilters.map(\.label),
            ["All categories", "Grounds", "House", "Uncategorized"])
        XCTAssertEqual(dashboard.dueTasks(matching: .all).map(\.id), ["house-1", "grounds-1", "blank-1"])
        XCTAssertEqual(dashboard.dueTasks(matching: .category("House")).map(\.id), ["house-1"])
        XCTAssertEqual(dashboard.dueTasks(matching: .category("Equipment")), [])
        XCTAssertEqual(dashboard.resolvedFilter(.category("Tractor")), .all)
        XCTAssertEqual(dashboard.resolvedFilter(.category("House")), .category("House"))
    }

    func testMalformedLiveTaskIsExcludedRatherThanInvented() throws {
        let data = try XCTUnwrap("[{\"id\":\"task-1\"},{\"id\":\"task-2\",\"item\":\"Inspect water\"}]".data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(dashboard.tasks.map(\.id), ["task-2"])
    }
}
