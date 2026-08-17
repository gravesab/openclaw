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
    var deviceInstallID: String?
    var deviceLabel: String?
    var appEnvironment: String?

    /// Shared by AssetAPIClient / task fetch extensions in other files.
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        baseURLString: String,
        apiKey: String? = nil,
        operatorPIN: String? = nil,
        operatorIdentity: String? = nil,
        deviceInstallID: String? = nil,
        deviceLabel: String? = nil,
        appEnvironment: String? = nil
    ) {
        self.baseURLString = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.operatorPIN = operatorPIN
        self.operatorIdentity = operatorIdentity
        self.deviceInstallID = deviceInstallID
        self.deviceLabel = deviceLabel
        self.appEnvironment = appEnvironment
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
        if let deviceInstallID, !deviceInstallID.isEmpty {
            request.setValue(deviceInstallID, forHTTPHeaderField: "X-Device-Install-ID")
        }
        if let deviceLabel, !deviceLabel.isEmpty {
            request.setValue(deviceLabel, forHTTPHeaderField: "X-Device-Label")
        }
        if let appEnvironment, !appEnvironment.isEmpty {
            request.setValue(appEnvironment, forHTTPHeaderField: "X-App-Environment")
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


    func completeTaskWithReceipt(
        id: UUID,
        note: String?,
        meterValueAtCompletion: Double? = nil,
        confirmCurrentMeter: Bool = false
    ) async throws -> TaskCompletionReceipt {
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

        let task = try decoder.decode(MaintenanceTask.self, from: data)
        let metadata = try decoder.decode(TaskCompletionReceiptMetadata.self, from: data)

        return TaskCompletionReceipt(
            task: task,
            completionID: metadata.completionID,
            completedAt: metadata.completedAt,
            completedBy: metadata.completedBy,
            deviceInstallID: metadata.deviceInstallID,
            deviceLabel: metadata.deviceLabel,
            appEnvironment: metadata.appEnvironment
        )
    }

    func acknowledgeCompletion(
        taskID: UUID,
        completionID: UUID
    ) async throws -> CompletionAcknowledgement {
        let url = try makeURL(
            "/tasks/\(taskID.uuidString)/completions/\(completionID.uuidString)/acknowledge"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(CompletionAcknowledgement.self, from: data)
    }

    func undoCompletion(
        taskID: UUID,
        completionID: UUID
    ) async throws -> MaintenanceTask {
        let url = try makeURL(
            "/tasks/\(taskID.uuidString)/completions/\(completionID.uuidString)/undo"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(MaintenanceTask.self, from: data)
    }
}

struct TaskCompletionReceipt: Identifiable {
    var id: UUID { completionID }

    let task: MaintenanceTask
    let completionID: UUID
    let completedAt: String
    let completedBy: String
    let deviceInstallID: String
    let deviceLabel: String
    let appEnvironment: String
}

private struct TaskCompletionReceiptMetadata: Decodable {
    let completionID: UUID
    let completedAt: String
    let completedBy: String
    let deviceInstallID: String
    let deviceLabel: String
    let appEnvironment: String

    enum CodingKeys: String, CodingKey {
        case completionID = "completion_id"
        case completedAt = "completed_at"
        case completedBy = "completed_by"
        case deviceInstallID = "device_install_id"
        case deviceLabel = "device_label"
        case appEnvironment = "app_environment"
    }
}

struct CompletionAcknowledgement: Decodable {
    let completionID: UUID
    let taskID: UUID
    let acknowledgedAt: String
    let acknowledgedBy: String?

    enum CodingKeys: String, CodingKey {
        case completionID = "completion_id"
        case taskID = "task_id"
        case acknowledgedAt = "acknowledged_at"
        case acknowledgedBy = "acknowledged_by"
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
