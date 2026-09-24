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

    func testRecoverableFailureRetainsFullDraftAttachmentsAndIdempotencyKeyForRetry() async throws {
        let description = String(repeating: "Leaking wash-rack water line. ", count: 399)
            + "Leaking wash-rack water line."
        let attachmentIDs = ["opaque-photo-one", "opaque-photo-two"]
        var draft = WorkRequestIntakeDraft()
        draft.description = description
        draft.area = "North barn"
        draft.attachmentIDs = attachmentIDs
        let originalKey = draft.idempotencyKey
        var attempts: [(WorkRequestSubmission, String)] = []

        do {
            _ = try await draft.submit { payload, key in
                attempts.append((payload, key))
                throw PropertyAPIError.serverMessage("Temporary network failure")
            }
            XCTFail("The simulated first submission must fail")
        } catch {
            // A recoverable failure must not mutate the draft used by Retry.
        }

        let submitted = try await draft.submit { payload, key in
            attempts.append((payload, key))
            return SubmittedWorkRequest(
                id: UUID(), requestNumber: "WR-1", intakeState: "submitted", idempotentReplay: true
            )
        }

        XCTAssertEqual(submitted.intakeState, "submitted")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.map { $0.0.description }, [description, description])
        XCTAssertEqual(attempts.map { $0.0.attachmentIDs }, [attachmentIDs, attachmentIDs])
        XCTAssertEqual(attempts.map { $0.1 }, [originalKey, originalKey])
    }

    func testReplacingPhotosInvalidatesUploadedAttachmentsAndRetryKey() {
        var draft = WorkRequestIntakeDraft()
        draft.attachmentIDs = ["opaque-photo-one"]
        let originalKey = draft.idempotencyKey

        draft.replacePhotoSelection()

        XCTAssertTrue(draft.attachmentIDs.isEmpty)
        XCTAssertNotEqual(draft.idempotencyKey, originalKey)
    }

    func testSuccessfulSubmissionResetStartsWithNoPriorAttachments() {
        var draft = WorkRequestIntakeDraft()
        draft.description = "Leaking wash-rack water line"
        draft.area = "North barn"
        draft.attachmentIDs = ["opaque-photo-one"]
        let originalKey = draft.idempotencyKey

        draft.resetAfterSuccessfulSubmission()

        XCTAssertTrue(draft.description.isEmpty)
        XCTAssertTrue(draft.area.isEmpty)
        XCTAssertTrue(draft.attachmentIDs.isEmpty)
        XCTAssertNotEqual(draft.idempotencyKey, originalKey)
    }
}
