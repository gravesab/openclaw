import Foundation

struct WorkRequestMaterial: Identifiable, Codable, Hashable {
    let id = UUID()
    var name = ""
    var quantity = "1"
    var unit = ""
    var note = ""

    func payload() -> [String: Any]? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return ["name": trimmedName, "quantity": quantity, "unit": unit, "note": note]
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

    func payload() throws -> WorkRequestSubmission {
        try WorkRequestPayload.make(
            description: description,
            area: area,
            assetID: assetID,
            materials: materials,
            attachmentIDs: attachmentIDs
        )
    }

    func submit(
        using sender: (WorkRequestSubmission, String) async throws -> SubmittedWorkRequest
    ) async throws -> SubmittedWorkRequest {
        try await sender(try payload(), idempotencyKey)
    }

    mutating func replacePhotoSelection() {
        attachmentIDs = []
        idempotencyKey = UUID().uuidString
    }

    mutating func resetAfterSuccessfulSubmission() {
        self = WorkRequestIntakeDraft()
    }
}

struct WorkRequestPhotoImportResult {
    let photos: [Data]
    let selectedCount: Int

    var isComplete: Bool { photos.count == selectedCount }
}

struct PreparedWorkRequestPhotos {
    let photos: [Data]
    let attachmentIDs: [String]
}

@MainActor
enum WorkRequestPhotoSubmissionGate {
    static func prepare(
        pendingImport: Task<WorkRequestPhotoImportResult, Never>?,
        fallbackImport: WorkRequestPhotoImportResult,
        existingAttachmentIDs: [String],
        idempotencyKey: String,
        allocator: ([Data], [String], String) async throws -> [String]
    ) async throws -> PreparedWorkRequestPhotos {
        let imported = if let pendingImport {
            await pendingImport.value
        } else {
            fallbackImport
        }
        guard imported.isComplete else {
            throw PropertyAPIError.serverMessage(
                "Every selected photo must finish importing before submission."
            )
        }
        let attachmentIDs = try await allocator(
            imported.photos,
            existingAttachmentIDs,
            idempotencyKey
        )
        guard attachmentIDs.count == imported.photos.count,
              attachmentIDs.allSatisfy({ UUID(uuidString: $0) != nil })
        else {
            throw PropertyAPIError.serverMessage(
                "Every selected photo must have a valid attachment ID before submission."
            )
        }
        return PreparedWorkRequestPhotos(photos: imported.photos, attachmentIDs: attachmentIDs)
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
        return WorkRequestSubmission(
            description: report,
            area: location.isEmpty ? nil : location,
            assetID: assetID,
            materials: materials.compactMap { material in
                guard let value = material.payload() else { return nil }
                return WorkRequestMaterialPayload(
                    name: value["name"] as? String ?? "",
                    quantity: value["quantity"] as? String ?? "1",
                    unit: value["unit"] as? String ?? "",
                    note: value["note"] as? String ?? ""
                )
            },
            attachmentIDs: attachmentIDs
        )
    }
}
