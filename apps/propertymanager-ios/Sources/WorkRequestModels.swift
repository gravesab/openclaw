import Foundation

struct WorkRequestMaterial: Identifiable, Codable, Hashable {
    let id = UUID()
    var name = ""
    var quantity = ""
    var unit = ""
    var note = ""

    static func manualEntry() -> WorkRequestMaterial {
        var material = WorkRequestMaterial()
        material.quantity = "1"
        return material
    }
}

struct WorkRequestSubmission: Codable {
    let description: String
    let area: String?
    let assetID: UUID?
    let materials: [WorkRequestMaterialPayload]
    let attachmentIDs: [String]

    enum CodingKeys: String, CodingKey {
        case description, area, materials
        case assetID = "asset_id"
        case attachmentIDs = "attachment_ids"
    }
}

struct WorkRequestIntakeDraft {
    var description = ""
    var area = ""
    var assetID: UUID?
    var materials: [WorkRequestMaterial] = []
    var attachmentIDs: [String] = []
    var idempotencyKey = UUID().uuidString
    private(set) var frozenSubmission: WorkRequestSubmission?
    private(set) var frozenIdempotencyKey: String?

    var hasFrozenSubmission: Bool { frozenSubmission != nil }

    func payload() throws -> WorkRequestSubmission {
        try WorkRequestPayload.make(
            description: description,
            area: area,
            assetID: assetID,
            materials: materials,
            attachmentIDs: attachmentIDs
        )
    }

    mutating func beginSubmissionAttempt() throws -> (WorkRequestSubmission, String) {
        if let frozenSubmission, let frozenIdempotencyKey {
            return (frozenSubmission, frozenIdempotencyKey)
        }
        let payload = try self.payload()
        let key = idempotencyKey
        frozenSubmission = payload
        frozenIdempotencyKey = key
        return (payload, key)
    }

    mutating func submit(
        using sender: (WorkRequestSubmission, String) async throws -> SubmittedWorkRequest
    ) async throws -> SubmittedWorkRequest {
        let (payload, key) = try beginSubmissionAttempt()
        return try await sender(payload, key)
    }

    /// Clears the frozen retry and rotates the key. The edited draft can then be submitted as a new request.
    mutating func releaseFrozenSubmission() {
        frozenSubmission = nil
        frozenIdempotencyKey = nil
        idempotencyKey = UUID().uuidString
    }

    @discardableResult
    mutating func replacePhotoSelection() -> Bool {
        guard frozenSubmission == nil else { return false }
        attachmentIDs = []
        idempotencyKey = UUID().uuidString
        return true
    }

    mutating func resetAfterSuccessfulSubmission() {
        self = WorkRequestIntakeDraft()
    }
}

struct WorkRequestMaterialPayload: Codable {
    let name: String
    let quantity: String
    let unit: String
    let note: String
}

struct SubmittedWorkRequest: Codable, Identifiable {
    let id: UUID
    let requestNumber: String
    let intakeState: String
    let idempotentReplay: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case requestNumber = "request_number"
        case intakeState = "intake_state"
        case idempotentReplay = "idempotent_replay"
    }
}

enum WorkRequestPayload {
    static func make(
        description: String,
        area: String,
        assetID: UUID?,
        materials: [WorkRequestMaterial],
        attachmentIDs: [String]
    ) throws -> WorkRequestSubmission {
        let report = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !report.isEmpty else { throw PropertyAPIError.serverMessage("Describe the work is required.") }
        let location = area.trimmingCharacters(in: .whitespacesAndNewlines)
        guard assetID != nil || !location.isEmpty else {
            throw PropertyAPIError.serverMessage("Choose an asset or enter an area/location.")
        }
        var materialPayloads: [WorkRequestMaterialPayload] = []
        for material in materials {
            let trimmedName = material.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            guard let quantity = WorkRequestQuantities.accepted(material.quantity) else {
                throw PropertyAPIError.serverMessage(
                    "Enter a positive quantity for \(trimmedName), or remove that material."
                )
            }
            materialPayloads.append(
                WorkRequestMaterialPayload(
                    name: trimmedName,
                    quantity: quantity,
                    unit: material.unit.trimmingCharacters(in: .whitespacesAndNewlines),
                    note: material.note.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        return WorkRequestSubmission(
            description: report,
            area: location.isEmpty ? nil : location,
            assetID: assetID,
            materials: materialPayloads,
            attachmentIDs: attachmentIDs
        )
    }
}
