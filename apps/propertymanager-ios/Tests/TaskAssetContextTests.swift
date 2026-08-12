import XCTest
@testable import PropertyManager

final class TaskAssetContextTests: XCTestCase {
    func testNoSelectionIncludesEveryTask() {
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: UUID(), selectedAssetId: nil))
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: nil, selectedAssetId: nil))
    }

    func testSelectionIncludesOnlyTasksForSelectedAsset() {
        let selected = UUID()

        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: selected, selectedAssetId: selected))
        XCTAssertFalse(TaskAssetContext.includes(taskAssetId: UUID(), selectedAssetId: selected))
        XCTAssertFalse(TaskAssetContext.includes(taskAssetId: nil, selectedAssetId: selected))
    }
}
