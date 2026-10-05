import XCTest
@testable import PropertyManagerApp

final class TaskAssetContextTests: XCTestCase {
    func testNoSelectionIncludesEveryTask() {
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: UUID(), selectedAssetId: nil))
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: nil, selectedAssetId: nil))
    }

    func testSelectionIncludesOnlyMatchingAssetTasks() {
        let selected = UUID()
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: selected, selectedAssetId: selected))
        XCTAssertFalse(TaskAssetContext.includes(taskAssetId: UUID(), selectedAssetId: selected))
        XCTAssertFalse(TaskAssetContext.includes(taskAssetId: nil, selectedAssetId: selected))
    }
}
