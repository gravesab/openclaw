import XCTest

final class RanchVAAssetGraphTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testSameNameAssetsStayDistinctAndZeroTaskAssetsRemain() throws {
        let assets = try RanchOSPropertyLiveAsset.decode(from: Data("""
        {"items":[{"id":"\(first)","name":"Pump"},{"id":"\(second)","name":"Pump"}]}
        """.utf8))
        let tasks = try RanchOSPropertyLiveDashboard.decode(from: Data("""
        [{"id":"t1","item":"Inspect","asset_id":"\(first.uuidString.lowercased())"},
         {"id":"t2","item":"Pump","area":"Pump"},
         {"id":"t3","item":"Orphan","asset_id":"00000000-0000-0000-0000-000000000099"},
         {"id":"t4","item":"Malformed link","asset_id":"bad"}]
        """.utf8)).tasks
        let hierarchy = RanchVAAssetHierarchy(assets: assets, tasks: tasks)
        XCTAssertEqual(hierarchy.groups.count, 2)
        XCTAssertEqual(hierarchy.groups.first?.tasks.map(\.id), ["t1"])
        XCTAssertEqual(hierarchy.groups.last?.tasks.count, 0)
        XCTAssertEqual(hierarchy.unlinked.map(\.id), ["t2", "t3", "t4"])
    }

    func testNoGraphTruncationBeyondTwelveAssetsOrTasks() throws {
        let assets = (0..<30).map { index in
            RanchOSPropertyLiveAsset(id: UUID(), name: "Asset \(index)", category: nil, location: nil, manufacturer: nil, model: nil)
        }
        let tasks = (0..<40).compactMap { index in
            RanchOSPropertyLiveTask(payload: ["id": "t\(index)", "item": "Inspect", "asset_id": assets[0].id.uuidString])
        }
        let hierarchy = RanchVAAssetHierarchy(assets: assets, tasks: tasks)
        XCTAssertEqual(hierarchy.groups.count, 30)
        XCTAssertEqual(hierarchy.groups.first?.tasks.count, 40)
        XCTAssertTrue(hierarchy.unlinked.isEmpty)
    }

    func testAssetTasksRetainPartsSuppliesAndInstructionsFromReadFeed() throws {
        let task = try XCTUnwrap(RanchOSPropertyLiveTask(payload: [
            "id": "t1", "item": "Oil service", "asset_id": first.uuidString,
            "task_description": "Service engine", "response_instructions": "Let engine cool",
            "supplies_needed": "Oil", "notes": "Annual service", "frequency": "Yearly",
            "parts": [["name": "Filter", "part_number": "F-100", "oem_part_number": "OEM-1", "quantity": 2, "cost": "12.50", "vendor": "Supplier"]]
        ]))
        XCTAssertEqual(task.instructions, "Let engine cool")
        XCTAssertEqual(task.supplies, "Oil")
        XCTAssertEqual(task.parts?.first?.number, "F-100")
        XCTAssertEqual(task.parts?.first?.quantity, "2")
        XCTAssertEqual(task.parts?.first?.cost, "12.50")
        XCTAssertNil(task.legacyPart)
        XCTAssertNil(RanchOSPropertyLiveTask(payload: ["id": "missing", "item": "No parts field"])?.parts)
        XCTAssertEqual(RanchOSPropertyLiveTask(payload: ["id": "empty", "item": "Empty parts", "parts": []])?.parts, [])
    }

    func testGraphLabelsPreserveEveryWordWithoutTruncation() {
        let title = "Inspect and replace the engine oil filter and check all hydraulic connections before operating the tractor"
        let wrapped = RanchVAGraphLabels.wrapped(title, width: 20)
        XCTAssertGreaterThan(wrapped.split(separator: "\n").count, 3)
        XCTAssertEqual(wrapped.split(whereSeparator: \.isWhitespace), title.split(whereSeparator: \.isWhitespace))
    }

    func testMalformedDuplicateAndEmptyAssetResponses() throws {
        XCTAssertEqual(try RanchOSPropertyLiveAsset.decode(from: Data("[]".utf8)), [])
        for payload in ["{}", "[{\"id\":\"bad\",\"name\":\"Pump\"}]", "[{\"id\":\"\(first)\",\"name\":\" \"}]",
                        "[{\"id\":\"\(first)\",\"name\":\"Pump\"},{\"id\":\"\(first)\",\"name\":\"Other\"}]"] {
            XCTAssertThrowsError(try RanchOSPropertyLiveAsset.decode(from: Data(payload.utf8)))
        }
    }
}
