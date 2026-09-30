import Foundation

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
    let ingestionStatus: String
    let reviewStatus: String
    let extractedAt: String?
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
        case ingestionStatus = "ingestion_status"
        case reviewStatus = "review_status"
        case extractedAt = "extracted_at"
        case taskCount = "task_count"
    }
}

/// A PDF uploaded to the Dashboard Assets library. Only its locator is shared, never its bytes.
struct DashboardLibraryPDF: Decodable, Identifiable, Hashable {
    let relativePath: String
    let title: String

    var id: String { relativePath }
    var filename: String { (relativePath as NSString).lastPathComponent }

    /// Subfolder under Assets/, such as "Landscape/Chainsaws", or empty.
    var folder: String {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return "" }
        return parts.dropFirst().dropLast().joined(separator: "/")
    }

    /// True when a word of the asset name (3+ characters) appears in the PDF path,
    /// so "DR Chipper" suggests Assets/DR_Chipper_Manual.pdf.
    func isSuggested(forAssetName name: String) -> Bool {
        let path = relativePath
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
            .contains { path.localizedCaseInsensitiveContains($0) }
    }

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case title
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

extension PropertyAPIClient {
    static let manualLibraryUploadLimitBytes = 50 * 1024 * 1024

    /// Uploads and Intel Mini storage copies can outlast URLSession.shared defaults on cellular.
    static let manualTransferSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func fetchAssetManuals(assetID: UUID) async throws -> [AssetManualLibraryEntry] {
        let url = try makeURL("/assets/\(assetID.uuidString)/manuals", versioned: true)
        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
        try validate(response, data: data)
        return try decoder.decode([AssetManualLibraryEntry].self, from: data)
    }

    /// Stores the PDF in the Dashboard library (reusing an identical stored copy) and connects it to the asset.
    func uploadManualToLibrary(
        pdf: Data,
        filename: String,
        assetID: UUID,
        manualLibraryBaseURL: String
    ) async throws -> String {
        let url = try Self.manualLibraryURL(
            manualLibraryBaseURL,
            path: "/pm/manual-library/api/assets/\(assetID.uuidString.lowercased())/manuals"
        )
        guard pdf.count <= Self.manualLibraryUploadLimitBytes else {
            throw PropertyAPIError.serverMessage("The PDF is larger than the 50 MB library limit.")
        }
        let boundary = "PropertyManager-\(UUID().uuidString)"
        let safeName = filename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"pdf_file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(pdf)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        struct UploadReply: Decodable { let message: String }
        let (data, response) = try await Self.manualTransferSession.upload(for: request, from: body)
        try validate(response, data: data)
        return try JSONDecoder().decode(UploadReply.self, from: data).message
    }

    func fetchDashboardLibraryPDFs(manualLibraryBaseURL: String) async throws -> [DashboardLibraryPDF] {
        struct LibraryReply: Decodable { let documents: [DashboardLibraryPDF] }
        let url = try Self.manualLibraryURL(manualLibraryBaseURL, path: "/pm/manual-library/api/library")
        let (data, response) = try await Self.manualTransferSession.data(for: authorizedRequest(url: url))
        try validate(response, data: data)
        return try JSONDecoder().decode(LibraryReply.self, from: data).documents
    }

    /// Connects a stored library PDF to the asset without copying it. Returns the manual version to extract.
    func connectDashboardLibraryPDF(
        _ pdf: DashboardLibraryPDF,
        assetID: UUID,
        manualLibraryBaseURL: String
    ) async throws -> UUID? {
        struct ConnectReply: Decodable {
            let versionID: String?
            enum CodingKeys: String, CodingKey { case versionID = "version_id" }
        }
        let url = try Self.manualLibraryURL(
            manualLibraryBaseURL,
            path: "/pm/manual-library/api/assets/\(assetID.uuidString.lowercased())/manuals/link"
        )
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["relative_path": pdf.relativePath])
        let (data, response) = try await Self.manualTransferSession.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(ConnectReply.self, from: data).versionID.flatMap(UUID.init(uuidString:))
    }

    func downloadAssetManual(
        _ manual: AssetManualLibraryEntry,
        manualLibraryBaseURL: String
    ) async throws -> Data {
        let url = try Self.manualLibraryURL(
            manualLibraryBaseURL,
            path: "/pm/manual-library/content/\(manual.assetID.uuidString)"
                + "/\(manual.manualID.uuidString)/\(manual.versionID.uuidString)"
        )
        let (data, response) = try await Self.manualTransferSession.data(for: authorizedRequest(url: url))
        try validate(response, data: data)
        return data
    }

    func recordAssetManualExtraction(
        _ manual: AssetManualLibraryEntry,
        extractorName: String,
        extractorVersion: String,
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
        let url = try makeURL(Self.manualVersionPath(manual) + "/extraction", versioned: true)
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ExtractionRequest(extractorName: extractorName, extractorVersion: extractorVersion, chunks: chunks)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(AssetManualLibraryEntry.self, from: data)
    }

    func linkAssetManualTasks(_ manual: AssetManualLibraryEntry, taskIDs: [UUID]) async throws {
        let url = try makeURL(Self.manualVersionPath(manual) + "/tasks/link", versioned: true)
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["task_ids": taskIDs.map(\.uuidString)])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    func createTask(payload: [String: Any]) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks")
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(MaintenanceTask.self, from: data)
    }

    private static func manualVersionPath(_ manual: AssetManualLibraryEntry) -> String {
        "/assets/\(manual.assetID.uuidString)/manuals/\(manual.manualID.uuidString)"
            + "/versions/\(manual.versionID.uuidString)"
    }

    private static func manualLibraryURL(_ base: String, path: String) throws -> URL {
        let trimmed = base
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw PropertyAPIError.serverMessage("Set the Manual Library Dashboard URL in Settings first.")
        }
        guard let url = URL(string: trimmed + path) else { throw PropertyAPIError.invalidURL }
        return url
    }
}
