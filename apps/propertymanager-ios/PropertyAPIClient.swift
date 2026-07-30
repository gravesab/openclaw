import Foundation

enum PropertyAPIError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case serverMessage(String)
    case decoding(Error)
    case transport(Error)
    case lowerReadingConfirmation(LowerReadingPreview)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "API base URL is invalid."
        case .badStatus(let code):
            return "Server returned HTTP \(code)."
        case .serverMessage(let message):
            return message
        case .decoding(let error):
            return "Could not decode response: \(error.localizedDescription)"
        case .transport(let error):
            return error.localizedDescription
        case .lowerReadingConfirmation:
            return "Reading is lower than current. Confirmation required."
        }
    }
}

struct APIErrorBody: Codable {
    var code: String?
    var message: String?
    var field: String?
}

struct PropertyAPIClient {
    var baseURLString: String
    var apiKey: String?
    var operatorPIN: String?
    var operatorIdentity: String?

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

    init(
        baseURLString: String,
        apiKey: String? = nil,
        operatorPIN: String? = nil,
        operatorIdentity: String? = nil
    ) {
        self.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.operatorPIN = operatorPIN
        self.operatorIdentity = operatorIdentity
    }

    /// Asset/meter endpoints use `/v1/`; task endpoints remain at root.
    func makeURL(_ path: String, versioned: Bool = false) throws -> URL {
        let trimmed = baseURLString
        let prefix = versioned ? "/v1" : ""
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: trimmed + prefix + normalized) else {
            throw PropertyAPIError.invalidURL
        }
        return url
    }

    /// Bearer + X-API-Key (Mac-compatible) and optional operator PIN/identity.
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

    func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PropertyAPIError.badStatus(-1)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let data {
                if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data),
                   let message = err.message ?? err.code, !message.isEmpty
                {
                    throw PropertyAPIError.serverMessage(message)
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = obj["error"] as? String,
                   !message.isEmpty
                {
                    throw PropertyAPIError.serverMessage(message)
                }
            }
            throw PropertyAPIError.badStatus(http.statusCode)
        }
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

    func health() async throws -> HealthStatus {
        let url = try makeURL("/health")
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        do {
            return try JSONDecoder().decode(HealthStatus.self, from: data)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    func fetchCategories() async throws -> [MaintenanceCategory] {
        let url = try makeURL("/categories")
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        do {
            return try decoder.decode([MaintenanceCategory].self, from: data)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    func fetchTasks() async throws -> [MaintenanceTask] {
        let url = try makeURL("/tasks")
        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        do {
            return try decoder.decode([MaintenanceTask].self, from: data)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(MaintenanceTask.self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    func updateTask(id: UUID, fields: [String: Any]) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(MaintenanceTask.self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
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

    struct TaskDeleteResult: Decodable {
        let deleted: Bool?
        let taskId: String?

        enum CodingKeys: String, CodingKey {
            case deleted
            case taskId = "task_id"
        }
    }

    func deleteTask(id: UUID) async throws -> TaskDeleteResult {
        let url = try makeURL("/tasks/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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

    func deleteCategory(id: UUID, reassignTo: String? = nil) async throws -> CategoryDeleteResult {
        let url = try makeURL("/categories/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)
        if let reassignTo, !reassignTo.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["reassign_to": reassignTo]
            )
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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

    func replaceParts(taskID: UUID, parts: [[String: Any]]) async throws -> MaintenanceTask {
        let url = try makeURL("/tasks/\(taskID.uuidString)/parts")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: parts)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(MaintenanceTask.self, from: data)
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
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
