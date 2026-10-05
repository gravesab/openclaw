import AppKit
import Foundation

extension Error {
    /// SwiftUI cancels `.task` work when a view disappears or its id changes; that is not a failure.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let apiError = self as? PropertyAPIError, case .transport(let underlying) = apiError {
            return underlying.isCancellation
        }
        return (self as? URLError)?.code == .cancelled
    }
}

enum PropertyAPIError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case notFound(String?)
    case unauthorized(String?)
    case serverMessage(String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "API base URL is invalid."
        case .badStatus(let code):
            return "Server returned HTTP \(code)."
        case .notFound(let message):
            return message ?? "Server returned HTTP 404."
        case .unauthorized(let message):
            return message ?? "The server rejected the API key or operator PIN."
        case .serverMessage(let message):
            return message
        case .decoding(let error):
            return "Could not decode response: \(error.localizedDescription)"
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

/// Live PropertyManager API client (same Postgres-backed API the iPhone uses).
struct PropertyAPIClient {
    var baseURLString: String
    /// PROPERTYMANAGER_API_KEY from Mini ~/.config/openclaw/db.env
    var apiKey: String = ""
    /// PROPERTYMANAGER_OPERATOR_PIN from Mini ~/.config/openclaw/db.env (optional if API key set)
    var operatorPIN: String = ""
    var operatorIdentity: String = PropertyAPIClient.defaultOperatorIdentity

    static let defaultOperatorIdentity = "mac-operator"

    /// Bounded network session — never use URLSession.shared (default timeouts can hang UI tasks).
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.full.date(from: raw) {
                return date
            }
            if let date = ISO8601DateFormatter.fractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date: \(raw)"
            )
        }
        return decoder
    }

    func makeURL(_ path: String, versioned: Bool = false) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = versioned ? "/v1" : ""
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: trimmed + prefix + normalized) else {
            throw PropertyAPIError.invalidURL
        }
        return url
    }

    struct HealthStatus: Decodable {
        let status: String?
        let service: String?
        let dbMode: String?

        enum CodingKeys: String, CodingKey {
            case status
            case service
            case dbMode = "db_mode"
        }
    }

    struct AssetManualLibraryEntry: Decodable, Identifiable, Equatable {
        let manualID: UUID
        let assetID: UUID
        let title: String
        let documentType: String
        let manufacturer: String?
        let modelNumber: String?
        let versionID: UUID
        let versionNumber: Int
        let sourceDisplayName: String
        let mimeType: String
        let ingestionStatus: String
        let reviewStatus: String
        let lifecycleStatus: String
        let createdAt: Date?
        let extractedAt: Date?
        let taskCount: Int

        var id: UUID { versionID }

        enum CodingKeys: String, CodingKey {
            case manualID = "manual_id"
            case assetID = "asset_id"
            case title
            case documentType = "document_type"
            case manufacturer
            case modelNumber = "model_number"
            case versionID = "version_id"
            case versionNumber = "version_number"
            case sourceDisplayName = "source_display_name"
            case mimeType = "mime_type"
            case ingestionStatus = "ingestion_status"
            case reviewStatus = "review_status"
            case lifecycleStatus = "lifecycle_status"
            case createdAt = "created_at"
            case extractedAt = "extracted_at"
            case taskCount = "task_count"
        }
    }

    struct AssetManualExtractionChunk: Encodable, Equatable {
        let pageNumber: Int?
        let sectionHeading: String?
        let content: String

        enum CodingKeys: String, CodingKey {
            case pageNumber = "page_number"
            case sectionHeading = "section_heading"
            case content
        }
    }

    struct TaskDeleteResult: Decodable {
        let deleted: Bool?
        let taskId: String?

        enum CodingKeys: String, CodingKey {
            case deleted
            case taskId = "task_id"
        }
    }

    struct CategoryDeleteResult: Decodable {
        let deleted: Bool?
        let categoryId: String?
        let categoryName: String?
        let reassignedTo: String?
        let tasksReassigned: Int?

        enum CodingKeys: String, CodingKey {
            case deleted
            case categoryId = "category_id"
            case categoryName = "category_name"
            case reassignedTo = "reassigned_to"
            case tasksReassigned = "tasks_reassigned"
        }
    }

    /// Authenticated GET. Every read carries the same credentials as writes so
    /// a server that requires auth on reads never sees anonymous traffic.
    func authorizedGET(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(&request)
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return data
        } catch let error as PropertyAPIError {
            throw error
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func health() async throws -> HealthStatus {
        let data = try await authorizedGET(makeURL("/health"))
        do {
            return try JSONDecoder().decode(HealthStatus.self, from: data)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    /// Verifies the configured API key / operator PIN without exposing identity details.
    func authCheck() async throws {
        _ = try await authorizedGET(makeURL("/auth/check"))
    }

    func fetchCategories() async throws -> [CategoryDefinition] {
        let data = try await authorizedGET(makeURL("/categories"))
        do {
            let rows = try decoder.decode([APICategoryDTO].self, from: data)
            return rows.map(\.asCategoryDefinition)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    func createCategory(_ category: CategoryDefinition) async throws -> CategoryDefinition {
        let url = try makeURL("/categories")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": category.id.uuidString,
            "name": category.name,
            "icon": category.icon,
            "color_name": category.colorName,
            "is_built_in": category.isBuiltIn,
        ])

        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            let row = try decoder.decode(APICategoryDTO.self, from: data)
            return row.asCategoryDefinition
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func deleteCategory(id: UUID, reassignTo: String? = nil) async throws -> CategoryDeleteResult {
        let url = try makeURL("/categories/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(&request)
        if let reassignTo, !reassignTo.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["reassign_to": reassignTo]
            )
        }

        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return try JSONDecoder().decode(CategoryDeleteResult.self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func fetchTasks() async throws -> [MaintenanceTask] {
        let data = try await authorizedGET(makeURL("/tasks"))
        do {
            let rows = try decoder.decode([APITaskDTO].self, from: data)
            return rows.map(\.asMaintenanceTask)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    func fetchTask(id: UUID) async throws -> MaintenanceTask {
        let data = try await authorizedGET(makeURL("/tasks/\(id.uuidString)"))
        do {
            return try decodeTask(data)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    func decodeTask(_ data: Data) throws -> MaintenanceTask {
        try decoder.decode(APITaskDTO.self, from: data).asMaintenanceTask
    }

    /// Partial update limited to the server's PATCHABLE_FIELDS. Unlike the
    /// POST upsert it never rewrites history, dates, or parts.
    func patchTask(id: UUID, fields: [String: Any]) async throws -> MaintenanceTask {
        try await sendTaskJSON(
            method: "PATCH",
            path: "/tasks/\(id.uuidString)",
            body: fields
        )
    }

    func replaceTaskParts(id: UUID, parts: [PartRequirement]) async throws -> MaintenanceTask {
        try await sendTaskJSON(
            method: "PUT",
            path: "/tasks/\(id.uuidString)/parts",
            body: PartRequirement.apiPayload(parts)
        )
    }

    /// Moves the task to its next scheduled occurrence without recording a completion.
    func skipTask(id: UUID, note: String?) async throws -> MaintenanceTask {
        var body: [String: Any] = [:]
        if let note { body["note"] = note }
        return try await sendTaskJSON(method: "POST", path: "/tasks/\(id.uuidString)/skip", body: body)
    }

    /// Body carries exactly one of `next_due` (`YYYY-MM-DD`) or `next_due_meter_value`.
    func rescheduleTask(id: UUID, body: [String: Any]) async throws -> MaintenanceTask {
        try await sendTaskJSON(method: "POST", path: "/tasks/\(id.uuidString)/reschedule", body: body)
    }

    func fetchScheduleEvents(taskID: UUID) async throws -> [TaskScheduleEvent] {
        let data = try await authorizedGET(makeURL("/tasks/\(taskID.uuidString)"))
        do {
            return try JSONDecoder().decode(TaskScheduleEventsBody.self, from: data).scheduleEvents
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    private struct TaskScheduleEventsBody: Decodable {
        let scheduleEvents: [TaskScheduleEvent]

        enum CodingKeys: String, CodingKey { case scheduleEvents = "schedule_events" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scheduleEvents = try c.decodeIfPresent([TaskScheduleEvent].self, forKey: .scheduleEvents) ?? []
        }
    }

    private func sendTaskJSON(method: String, path: String, body: Any) async throws -> MaintenanceTask {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return try decodeTask(data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func fetchAssetManuals(assetID: UUID) async throws -> [AssetManualLibraryEntry] {
        let url = try makeURL("/assets/\(assetID.uuidString)/manuals", versioned: true)
        var request = URLRequest(url: url)
        applyAuth(&request)
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return try decoder.decode([AssetManualLibraryEntry].self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func downloadAssetManual(
        _ manual: AssetManualLibraryEntry,
        manualLibraryBaseURL: String
    ) async throws -> Data {
        let url = try manualLibraryContentURL(manual, manualLibraryBaseURL: manualLibraryBaseURL)
        var request = URLRequest(url: url)
        applyAuth(&request)
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return data
        } catch let error as PropertyAPIError {
            throw error
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    /// Uploads and IntelMini storage copies can outlast the shared session's 25-second resource limit.
    static let manualUploadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Stores the PDF in the Dashboard library (reusing an identical stored copy) and connects it to the asset.
    func uploadManualToLibrary(
        fileURL: URL,
        assetID: UUID,
        manualLibraryBaseURL: String
    ) async throws -> String {
        let base = manualLibraryBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(
            string: base + "/pm/manual-library/api/assets/\(assetID.uuidString.lowercased())/manuals"
        ) else {
            throw PropertyAPIError.invalidURL
        }
        let pdf = try Data(contentsOf: fileURL)
        guard pdf.count <= 50 * 1024 * 1024 else {
            throw PropertyAPIError.serverMessage("The PDF is larger than the 50 MB library limit.")
        }
        let boundary = "PropertyManager-\(UUID().uuidString)"
        let filename = fileURL.lastPathComponent
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"pdf_file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(pdf)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        struct UploadReply: Decodable { let message: String }
        do {
            let (data, response) = try await Self.manualUploadSession.upload(for: request, from: body)
            try validate(response, data: data)
            return try JSONDecoder().decode(UploadReply.self, from: data).message
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func manualLibraryContentURL(
        _ manual: AssetManualLibraryEntry,
        manualLibraryBaseURL: String
    ) throws -> URL {
        let base = manualLibraryBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(
            string: base
                + "/pm/manual-library/content/\(manual.assetID.uuidString)"
                + "/\(manual.manualID.uuidString)/\(manual.versionID.uuidString)"
        ) else {
            throw PropertyAPIError.invalidURL
        }
        return url
    }

    func recordAssetManualExtraction(
        _ manual: AssetManualLibraryEntry,
        chunks: [AssetManualExtractionChunk]
    ) async throws -> AssetManualLibraryEntry {
        struct ExtractionRequest: Encodable {
            let extractorName: String
            let extractorVersion: String
            let chunks: [AssetManualExtractionChunk]

            enum CodingKeys: String, CodingKey {
                case extractorName = "extractor_name"
                case extractorVersion = "extractor_version"
                case chunks
            }
        }
        let url = try makeURL(
            "/assets/\(manual.assetID.uuidString)/manuals/\(manual.manualID.uuidString)/versions/\(manual.versionID.uuidString)/extraction",
            versioned: true
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONEncoder().encode(
            ExtractionRequest(
                extractorName: AppleManualExtractor.extractorName,
                extractorVersion: AppleManualExtractor.extractorVersion,
                chunks: chunks
            )
        )
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(AssetManualLibraryEntry.self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func linkAssetManualTasks(
        _ manual: AssetManualLibraryEntry,
        taskIDs: [UUID]
    ) async throws {
        struct TaskLinkRequest: Encodable {
            let taskIDs: [UUID]

            enum CodingKeys: String, CodingKey {
                case taskIDs = "task_ids"
            }
        }
        let url = try makeURL(
            "/assets/\(manual.assetID.uuidString)/manuals/\(manual.manualID.uuidString)/versions/\(manual.versionID.uuidString)/tasks/link",
            versioned: true
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONEncoder().encode(TaskLinkRequest(taskIDs: taskIDs))
        let (data, response) = try await Self.sharedSession.data(for: request)
        try validate(response, data: data)
    }

    func upsertTask(_ task: MaintenanceTask) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: APITaskDTO.payload(from: task))

        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            let row = try decoder.decode(APITaskDTO.self, from: data)
            return row.asMaintenanceTask.mergingLocalOnlyFields(from: task)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    /// A stable representation of the fields the task API actually persists.
    /// UI-only state such as a downloaded photo name must not trigger another
    /// task upsert after the API has already acknowledged the task.
    func taskPayloadSignature(_ task: MaintenanceTask) -> Data? {
        guard JSONSerialization.isValidJSONObject(APITaskDTO.payload(from: task)) else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: APITaskDTO.payload(from: task),
            options: [.sortedKeys]
        )
    }

    func completeTask(id: UUID, note: String?, meterValueAtCompletion: Double? = nil, confirmCurrentMeter: Bool = false) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks/\(id.uuidString)/complete")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        var completeBody: [String: Any] = ["note": note ?? ""]
        if let meterValueAtCompletion { completeBody["meter_value_at_completion"] = meterValueAtCompletion }
        else if confirmCurrentMeter { completeBody["confirm_current_meter"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: completeBody)

        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            let row = try decoder.decode(APITaskDTO.self, from: data)
            return row.asMaintenanceTask
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func deleteTask(id: UUID) async throws -> TaskDeleteResult {
        let url = try makeURL("/tasks/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(&request)

        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return try JSONDecoder().decode(TaskDeleteResult.self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    private struct PhotoUploadResult: Decodable {
        let fileName: String

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
        }
    }

    func uploadPhoto(taskID: UUID, fileURL: URL) async throws -> String {
        let url = try makeURL("/tasks/\(taskID.uuidString)/photos")
        let fileData = try normalizedTaskPhotoData(fileURL)
        let boundary = "PropertyManager-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"task-photo.jpg\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = body
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(PhotoUploadResult.self, from: data).fileName
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    private func normalizedTaskPhotoData(_ fileURL: URL) throws -> Data {
        guard let sourceImage = NSImage(contentsOf: fileURL) else {
            throw PropertyAPIError.serverMessage("Choose a readable JPEG, PNG, or HEIC photo.")
        }

        // Keep the multipart body comfortably below the server's 25 MiB
        // per-photo limit, including its multipart framing.
        let maximumEncodedBytes = 10 * 1024 * 1024
        var maximumDimension: CGFloat = 4_096
        var compression: CGFloat = 0.82

        for _ in 0..<5 {
            let scale = min(1, maximumDimension / max(sourceImage.size.width, sourceImage.size.height))
            let targetSize = NSSize(
                width: max(1, floor(sourceImage.size.width * scale)),
                height: max(1, floor(sourceImage.size.height * scale))
            )
            let normalizedImage = NSImage(size: targetSize)
            normalizedImage.lockFocus()
            sourceImage.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: sourceImage.size),
                operation: .copy,
                fraction: 1
            )
            normalizedImage.unlockFocus()

            if let tiff = normalizedImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpeg = bitmap.representation(
                   using: .jpeg,
                   properties: [.compressionFactor: compression]
               ), jpeg.count <= maximumEncodedBytes {
                return jpeg
            }

            maximumDimension *= 0.7
            compression = max(0.45, compression * 0.8)
        }

        throw PropertyAPIError.serverMessage("This photo could not be reduced to the upload limit. Choose a smaller photo.")
    }

    func deletePhoto(taskID: UUID, fileName: String) async throws {
        let url = try makeURL("/tasks/\(taskID.uuidString)/photos")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_name": fileName])
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func downloadPhoto(taskID: UUID, fileName: String) async throws -> Data {
        let base = try makeURL("/tasks/\(taskID.uuidString)/photos/content")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PropertyAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "file_name", value: fileName)]
        guard let url = components.url else {
            throw PropertyAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(&request)
        do {
            let (data, response) = try await Self.sharedSession.data(for: request)
            try validate(response, data: data)
            return data
        } catch let error as PropertyAPIError {
            throw error
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }


    /// Mutating-request auth: Bearer/X-API-Key and optional X-Operator-PIN.
    func applyAuth(_ request: inout URLRequest) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        let pin = operatorPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pin.isEmpty {
            request.setValue(pin, forHTTPHeaderField: "X-Operator-PIN")
        }
        let identity = operatorIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(
            identity.isEmpty ? Self.defaultOperatorIdentity : identity,
            forHTTPHeaderField: "X-Operator-Identity"
        )
    }

    func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PropertyAPIError.badStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            var message: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let text = obj["message"] as? String, !text.isEmpty {
                    message = text
                } else if let text = obj["error"] as? String, !text.isEmpty {
                    message = text
                } else if let error = obj["error"] as? [String: Any],
                          let text = error["message"] as? String,
                          !text.isEmpty {
                    message = text
                }
            }
            if http.statusCode == 404 {
                throw PropertyAPIError.notFound(message)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw PropertyAPIError.unauthorized(message)
            }
            if let message {
                throw PropertyAPIError.serverMessage(message)
            }
            throw PropertyAPIError.badStatus(http.statusCode)
        }
    }
}

// MARK: - API DTOs (snake_case wire format)

private struct APICategoryDTO: Decodable {
    let id: UUID
    let name: String
    let icon: String
    let colorName: String
    let isBuiltIn: Bool
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case colorName = "color_name"
        case isBuiltIn = "is_built_in"
        case sortOrder = "sort_order"
    }

    var asCategoryDefinition: CategoryDefinition {
        CategoryDefinition(
            id: id,
            name: name,
            icon: icon,
            colorName: colorName,
            isBuiltIn: isBuiltIn
        )
    }
}

private struct APIPartDTO: Decodable {
    let id: UUID?
    let name: String?
    let oemPartNumber: String?
    let partNumber: String?
    let buyURL: String?
    let cost: Double?
    let quantity: Double?
    let vendor: String?
    let notes: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, cost, quantity, vendor, notes
        case oemPartNumber = "oem_part_number"
        case partNumber = "part_number"
        case buyURL = "buy_url"
        case sortOrder = "sort_order"
    }

    var asPartRequirement: PartRequirement {
        PartRequirement(
            id: id ?? UUID(),
            name: name ?? "",
            oemPartNumber: oemPartNumber ?? "",
            partNumber: partNumber ?? "",
            buyURL: buyURL ?? "",
            cost: cost ?? 0,
            quantity: quantity ?? 1,
            vendor: vendor ?? "",
            notes: notes ?? ""
        )
    }
}

private struct APIPhotoDTO: Decodable {
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
    }
}

private struct APITaskDTO: Decodable {
    let id: UUID
    let area: String
    let item: String
    let categoryName: String
    let kind: String?
    let priority: String
    let frequency: String
    let taskDescription: String?
    let responseInstructions: String?
    let suppliesNeeded: String?
    let notes: String?
    let resultNotes: String?
    let estimatedMinutes: Int?
    let warningDays: Int
    let criticalDays: Int
    let lastDone: Date?
    let nextDue: Date
    let sendTelegramUpdate: Bool?
    let includeInDailyBriefing: Bool?
    let alertIfOverdue: Bool?
    let isActive: Bool?
    let manufacturer: String?
    let sourceManualName: String?
    let origin: String?
    let completionHistory: [String]?
    let toolsRequired: [ToolRequirement]?
    let parts: [APIPartDTO]?
    let photos: [APIPhotoDTO]?
    let scheduleKind: String?
    let meterIntervalValue: Decimal?
    let meterIntervalUnit: String?
    let nextDueMeterValue: Decimal?
    let remainingMeter: Decimal?
    let dueMeter: Bool?
    let overdueMeter: Bool?
    let assetId: UUID?
    let deferredUntil: String?
    let deferred: Bool?

    enum CodingKeys: String, CodingKey {
        case id, area, item, kind, priority, frequency, notes, manufacturer, origin, parts, photos
        case categoryName = "category_name"
        case taskDescription = "task_description"
        case responseInstructions = "response_instructions"
        case suppliesNeeded = "supplies_needed"
        case resultNotes = "result_notes"
        case estimatedMinutes = "estimated_minutes"
        case warningDays = "warning_days"
        case criticalDays = "critical_days"
        case lastDone = "last_done"
        case nextDue = "next_due"
        case sendTelegramUpdate = "send_telegram_update"
        case includeInDailyBriefing = "include_in_daily_briefing"
        case alertIfOverdue = "alert_if_overdue"
        case isActive = "is_active"
        case sourceManualName = "source_manual_name"
        case completionHistory = "completion_history"
        case toolsRequired = "tools_required"
        case scheduleKind = "schedule_kind"
        case meterIntervalValue = "meter_interval_value"
        case meterIntervalUnit = "meter_interval_unit"
        case nextDueMeterValue = "next_due_meter_value"
        case remainingMeter = "remaining_meter"
        case dueMeter = "due_meter"
        case overdueMeter = "overdue_meter"
        case assetId = "asset_id"
        case deferredUntil = "deferred_until"
        case deferred
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        area = try c.decode(String.self, forKey: .area)
        item = try c.decode(String.self, forKey: .item)
        categoryName = try c.decode(String.self, forKey: .categoryName)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        priority = try c.decode(String.self, forKey: .priority)
        frequency = try c.decode(String.self, forKey: .frequency)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription)
        responseInstructions = try c.decodeIfPresent(String.self, forKey: .responseInstructions)
        suppliesNeeded = try c.decodeIfPresent(String.self, forKey: .suppliesNeeded)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        resultNotes = try c.decodeIfPresent(String.self, forKey: .resultNotes)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        warningDays = try c.decode(Int.self, forKey: .warningDays)
        criticalDays = try c.decode(Int.self, forKey: .criticalDays)
        lastDone = try c.decodeIfPresent(Date.self, forKey: .lastDone)
        nextDue = try c.decode(Date.self, forKey: .nextDue)
        sendTelegramUpdate = try c.decodeIfPresent(Bool.self, forKey: .sendTelegramUpdate)
        includeInDailyBriefing = try c.decodeIfPresent(Bool.self, forKey: .includeInDailyBriefing)
        alertIfOverdue = try c.decodeIfPresent(Bool.self, forKey: .alertIfOverdue)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        sourceManualName = try c.decodeIfPresent(String.self, forKey: .sourceManualName)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        completionHistory = try c.decodeIfPresent([String].self, forKey: .completionHistory)
        toolsRequired = try c.decodeIfPresent([ToolRequirement].self, forKey: .toolsRequired)
        parts = try c.decodeIfPresent([APIPartDTO].self, forKey: .parts)
        photos = try c.decodeIfPresent([APIPhotoDTO].self, forKey: .photos)
        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind)
        meterIntervalValue = Self.decodeFlexibleDecimal(c, forKey: .meterIntervalValue)
        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)
        nextDueMeterValue = Self.decodeFlexibleDecimal(c, forKey: .nextDueMeterValue)
        remainingMeter = Self.decodeFlexibleDecimal(c, forKey: .remainingMeter)
        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)
        deferredUntil = try c.decodeIfPresent(String.self, forKey: .deferredUntil)
        deferred = try c.decodeIfPresent(Bool.self, forKey: .deferred)
    }

    private 
    static func decodeFlexibleDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Decimal? {
        if let v = try? c.decodeIfPresent(Decimal.self, forKey: key) { return v }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Decimal(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Decimal(string: String(d))
        }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: s.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    var asMaintenanceTask: MaintenanceTask {
        let mappedKind = TaskKind(rawValue: kind ?? "") ?? .scheduled
        let mappedPriority = TaskPriority(rawValue: priority) ?? .medium
        let mappedFrequency: TaskFrequency
        switch frequency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "every 7 days":
            mappedFrequency = .weekly
        case "every 30 days":
            mappedFrequency = .monthly
        case "every 90 days":
            mappedFrequency = .quarterly
        case "every 105 days":
            mappedFrequency = .everyThreeToFourMonths
        case "every 365 days":
            mappedFrequency = .yearly
        case "every 730 days":
            mappedFrequency = .biennial
        default:
            mappedFrequency = TaskFrequency(rawValue: frequency) ?? .monthly
        }
        let mappedOrigin = TaskOrigin(rawValue: origin ?? "")
            ?? ((sourceManualName ?? "").isEmpty ? .owner : .manufacturer)
        let mappedParts = (parts ?? []).map(\.asPartRequirement)
        let photoNames = (photos ?? []).compactMap { photo -> String? in
            let name = photo.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }

        return MaintenanceTask(
            id: id,
            area: area,
            item: item,
            category: categoryName,
            kind: mappedKind,
            priority: mappedPriority,
            frequency: mappedFrequency,
            taskDescription: taskDescription ?? "",
            responseInstructions: responseInstructions ?? "",
            suppliesNeeded: suppliesNeeded ?? "",
            notes: notes ?? "",
            resultNotes: resultNotes ?? "",
            completionHistory: completionHistory ?? [],
            estimatedMinutes: estimatedMinutes ?? 30,
            warningDays: warningDays,
            criticalDays: criticalDays,
            lastDone: lastDone,
            nextDue: nextDue,
            sendTelegramUpdate: sendTelegramUpdate ?? true,
            includeInDailyBriefing: includeInDailyBriefing ?? true,
            alertIfOverdue: alertIfOverdue ?? true,
            isActive: isActive ?? true,
            manufacturer: manufacturer ?? "",
            sourceManualName: sourceManualName ?? "",
            origin: mappedOrigin,
            partNumbers: mappedParts.map(\.partNumber).filter { !$0.isEmpty },
            referenceURLs: mappedParts.map(\.buyURL).filter { !$0.isEmpty },
            toolsRequired: toolsRequired ?? [],
            parts: mappedParts,
            photoFileNames: photoNames,
            manualImport: nil,
            scheduleKind: scheduleKind ?? "calendar",
            meterIntervalValue: meterIntervalValue,
            meterIntervalUnit: meterIntervalUnit,
            nextDueMeterValue: nextDueMeterValue,
            remainingMeter: remainingMeter,
            dueMeter: dueMeter,
            overdueMeter: overdueMeter,
            assetId: assetId,
            deferredUntil: deferredUntil,
            deferred: deferred
        )
    }

    static func payload(from task: MaintenanceTask) -> [String: Any] {
        let iso = ISO8601DateFormatter.full
        let body: [String: Any] = [
            "id": task.id.uuidString,
            "area": task.area,
            "item": task.item,
            "category_name": task.category,
            "kind": task.kind.rawValue,
            "priority": task.priority.rawValue,
            "frequency": task.frequency.rawValue,
            "task_description": task.taskDescription,
            "response_instructions": task.responseInstructions,
            "supplies_needed": task.suppliesNeeded,
            "notes": task.notes,
            "result_notes": task.resultNotes,
            "estimated_minutes": task.estimatedMinutes,
            "warning_days": task.warningDays,
            "critical_days": task.criticalDays,
            "last_done": task.lastDone.map { iso.string(from: $0) } ?? NSNull(),
            "next_due": iso.string(from: task.nextDue),
            "send_telegram_update": task.sendTelegramUpdate,
            "include_in_daily_briefing": task.includeInDailyBriefing,
            "alert_if_overdue": task.alertIfOverdue,
            "is_active": task.isActive,
            "manufacturer": task.manufacturer,
            "source_manual_name": task.sourceManualName,
            "origin": task.origin.rawValue,
            "completion_history": task.completionHistory,
            "tools_required": task.toolsRequired.map { tool -> [String: Any] in
                [
                    "id": tool.id.uuidString,
                    "name": tool.name,
                    "size": tool.size,
                    "notes": tool.notes,
                ]
            },
            "schedule_kind": task.scheduleKind,
            "meter_interval_value": task.meterIntervalValue.map { NSDecimalNumber(decimal: $0).stringValue } as Any,
            "meter_interval_unit": task.meterIntervalUnit as Any,
            "next_due_meter_value": task.nextDueMeterValue.map { NSDecimalNumber(decimal: $0).stringValue } as Any,
            "asset_id": task.assetId?.uuidString as Any,
            "parts": PartRequirement.apiPayload(task.parts),
        ]
        return body
    }

}


private extension MaintenanceTask {
    /// Preserve Mac-only fields the API does not round-trip yet.
    func mergingLocalOnlyFields(from local: MaintenanceTask) -> MaintenanceTask {
        var merged = self
        if merged.manualImport == nil {
            merged.manualImport = local.manualImport
        }
        if merged.photoFileNames.isEmpty, !local.photoFileNames.isEmpty {
            merged.photoFileNames = local.photoFileNames
        }
        return merged
    }
}

private extension ISO8601DateFormatter {
    static let full: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
