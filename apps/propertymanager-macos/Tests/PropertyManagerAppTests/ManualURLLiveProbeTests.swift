import XCTest
@testable import PropertyManagerApp

final class ManualURLLiveProbeTests: XCTestCase {
    func testDeereDraftReviewOnly() async throws {
        guard ProcessInfo.processInfo.environment["PM_MANUAL_LIVE_TEST"] == "1" else {
            throw XCTSkip("Explicit local live diagnostic only")
        }
        let result = try await URLManualImporter.importDrafts(from: "http://manuals.deere.com/omview/OMLVU28480_19/?tM=") { progress in
            print("LIVE_PROGRESS \(progress)")
        }
        print("LIVE_DRAFT_COUNT \(result.drafts.count)")
        XCTAssertFalse(result.drafts.isEmpty)
    }
}
