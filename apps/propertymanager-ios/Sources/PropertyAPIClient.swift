import Foundation

enum PropertyAPIError: LocalizedError {
    case invalidURL
    case serverMessage(String)
    case lowerReadingConfirmation(LowerReadingPreview)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL."
        case .serverMessage(let message):
            return message
        case .lowerReadingConfirmation:
            return "Reading is lower than current. Confirmation required."
        }
    }
}

/// Shared HTTP client for PropertyManager REST API.
/// Asset/meter endpoints use `/v1/`; task endpoints remain at root (Phase 1 API).
final class PropertyAPIClient {
    let baseURLString: String
    var apiKey: String?
    var operatorPIN: String?
    var operatorIdentity: String?

    /// Shared by AssetAPIClient / task fetch extensions in other files.
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(baseURLString: String, apiKey: String? = nil, operatorPIN: String? = nil, operatorIdentity: String? = nil) {
        self.baseURLString = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.operatorPIN = operatorPIN
        self.operatorIdentity = operatorIdentity
    }

    func makeURL(_ path: String, versioned: Bool = false) throws -> URL {
        let prefix = versioned ? "/v1" : ""
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: baseURLString + prefix + normalized) else {
            throw PropertyAPIError.invalidURL
        }
        return url
    }

    func applyAuth(to request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let operatorPIN, !operatorPIN.isEmpty {
            request.setValue(operatorPIN, forHTTPHeaderField: "X-Operator-PIN")
        }
        if let operatorIdentity, !operatorIdentity.isEmpty {
            request.setValue(operatorIdentity, forHTTPHeaderField: "X-Operator-Identity")
        }
    }

    func authorizedRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyAuth(to: &request)
        return request
    }

    func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ... 299).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw PropertyAPIError.serverMessage(err.message ?? err.code ?? "HTTP \(http.statusCode)")
            }
            throw PropertyAPIError.serverMessage("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Health

    func health() async throws -> APIHealth {
        let url = try makeURL("/health")
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(APIHealth.self, from: data)
    }

    // MARK: - Categories

    func fetchCategories() async throws -> [MaintenanceCategory] {
        let url = try makeURL("/categories")
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode([MaintenanceCategory].self, from: data)
    }

    func deleteCategory(id: UUID, reassignTo: String? = nil) async throws -> CategoryDeleteResult {
        let url = try makeURL("/categories/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)
        if let reassignTo, !reassignTo.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["reassign_to": reassignTo])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(CategoryDeleteResult.self, from: data)
    }

    // MARK: - Tasks

    func fetchTasks() async throws -> [MaintenanceTask] {
        let url = try makeURL("/tasks")
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode([MaintenanceTask].self, from: data)
    }

    func updateTask(id: UUID, fields: [String: Any]) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(MaintenanceTask.self, from: data)
    }

    func replaceParts(taskID: UUID, parts: [[String: Any]]) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks/\(taskID.uuidString)/parts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["parts": parts])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(MaintenanceTask.self, from: data)
    }

    func deleteTask(id: UUID) async throws {
        let url = try makeURL("/tasks/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    func completeTask(
        id: UUID,
        note: String?,
        meterValueAtCompletion: Double? = nil,
        confirmCurrentMeter: Bool = false
    ) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks/\(id.uuidString)/complete")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        var body: [String: Any] = ["note": note ?? ""]
        if let meterValueAtCompletion {
            body["meter_value_at_completion"] = meterValueAtCompletion
        } else if confirmCurrentMeter {
            body["confirm_current_meter"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(MaintenanceTask.self, from: data)
    }

    // MARK: - PostgreSQL task photos

    private struct PhotoUploadResult: Decodable {
        let fileName: String

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
        }
    }

    func uploadPhoto(
        taskID: UUID,
        data: Data,
        fileName: String = "iphone-photo.jpg",
        mimeType: String = "image/jpeg"
    ) async throws -> String {
        let url = try makeURL("/tasks/\(taskID.uuidString)/photos")
        let boundary = "PropertyManager-iOS-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = body
        let (responseData, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: responseData)
        return try decoder.decode(PhotoUploadResult.self, from: responseData).fileName
    }

    func downloadPhoto(taskID: UUID, fileName: String) async throws -> Data {
        let base = try makeURL("/tasks/\(taskID.uuidString)/photos/content")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PropertyAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "file_name", value: fileName)]
        guard let url = components.url else { throw PropertyAPIError.invalidURL }
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return data
    }

    func deletePhoto(taskID: UUID, fileName: String) async throws {
        let url = try makeURL("/tasks/\(taskID.uuidString)/photos")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_name": fileName])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }
}

struct APIErrorBody: Codable {
    var code: String?
    var message: String?
    var field: String?
}

struct APIHealth: Codable {
    var status: String?
    var service: String?
    var apiVersion: String?
    var dbMode: String?
    var schemaVersion: String?

    enum CodingKeys: String, CodingKey {
        case status, service
        case apiVersion = "api_version"
        case dbMode = "db_mode"
        case schemaVersion = "schema_version"
    }
}

struct CategoryDeleteResult: Codable {
    var deleted: Bool?
    var categoryId: String?
    var categoryName: String?
    var reassignedTo: String?
    var tasksReassigned: Int?

    enum CodingKeys: String, CodingKey {
        case deleted
        case categoryId = "category_id"
        case categoryName = "category_name"
        case reassignedTo = "reassigned_to"
        case tasksReassigned = "tasks_reassigned"
    }
}
