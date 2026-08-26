import XCTest
@testable import PropertyManager

final class WorkRequestPayloadTests: XCTestCase {
    func testPayloadRequiresDescriptionAndLocationOrAsset() {
        XCTAssertThrowsError(try WorkRequestPayload.make(
            description: " ", area: "North barn", assetID: nil, materials: [], attachmentIDs: []
        ))
        XCTAssertThrowsError(try WorkRequestPayload.make(
            description: "Leak", area: " ", assetID: nil, materials: [], attachmentIDs: []
        ))
    }

    func testPayloadRetainsDraftMaterialButNeverStoragePath() throws {
        var material = WorkRequestMaterial()
        material.name = "PVC fitting"
        material.quantity = "2"
        material.unit = "each"
        let payload = try WorkRequestPayload.make(
            description: "Leak behind wash rack", area: "North barn", assetID: nil,
            materials: [material], attachmentIDs: ["opaque-attachment-id"]
        )
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("opaque-attachment-id"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("storage_path"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("file://"))
        XCTAssertEqual(payload.materials.first?.name, "PVC fitting")
    }
}
