import XCTest
@testable import PropertyManagerApp

final class ManualLibraryClientTests: XCTestCase {
    func testManualContentUsesDashboardRouteNotPropertyManagerAPI() throws {
        let manual = PropertyAPIClient.AssetManualLibraryEntry(
            manualID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Ranger Manual",
            documentType: "operator_manual",
            manufacturer: "Polaris",
            modelNumber: nil,
            versionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            versionNumber: 1,
            sourceDisplayName: "Ranger.pdf",
            mimeType: "application/pdf",
            ingestionStatus: "pending",
            reviewStatus: "pending",
            lifecycleStatus: "draft",
            createdAt: nil,
            extractedAt: nil,
            taskCount: 0
        )

        let client = PropertyAPIClient(
            baseURLString: "http://propertymanager-dev.example:5062",
            apiKey: "not-used-by-this-test"
        )
        let url = try client.manualLibraryContentURL(
            manual,
            manualLibraryBaseURL: "https://dashboard-dev.example/"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://dashboard-dev.example/pm/manual-library/content/"
                + "00000000-0000-0000-0000-000000000002/"
                + "00000000-0000-0000-0000-000000000001/"
                + "00000000-0000-0000-0000-000000000003"
        )
        XCTAssertFalse(url.absoluteString.contains("propertymanager-dev.example"))
    }
}
