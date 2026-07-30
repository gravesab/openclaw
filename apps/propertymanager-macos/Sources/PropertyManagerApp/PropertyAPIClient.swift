import Foundation

enum PropertyAPIError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case serverMessage(String)
    case decoding(Error)
    case transport(Error)

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

    func health() async throws -> HealthStatus {
        let url = try makeURL("/health")
        let (data, response) = try await Self.sharedSession.data(from: url)
        try validate(response, data: data)
        do {
            return try JSONDecoder().decode(HealthStatus.self, from: data)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
    }

    func fetchCategories() async throws -> [CategoryDefinition] {
        let url = try makeURL("/categories")
        let (data, response) = try await Self.sharedSession.data(from: url)
        try validate(response, data: data)
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
        let url = try makeURL("/tasks")
        let (data, response) = try await Self.sharedSession.data(from: url)
        try validate(response, data: data)
        do {
            let rows = try decoder.decode([APITaskDTO].self, from: data)
            return rows.map(\.asMaintenanceTask)
        } catch {
            throw PropertyAPIError.decoding(error)
        }
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
        request.setValue("mac-operator", forHTTPHeaderField: "X-Operator-Identity")
    }

    func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PropertyAPIError.badStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = obj["error"] as? String,
               !message.isEmpty
            {
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
            cost: cost ?? 0
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
    let lastDone: Date
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
        lastDone = try c.decode(Date.self, forKey: .lastDone)
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
        let mappedFrequency = TaskFrequency(rawValue: frequency) ?? .monthly
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
            assetId: assetId
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
            "last_done": iso.string(from: task.lastDone),
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
            "parts": task.parts.enumerated().map { index, part -> [String: Any] in
                [
                    "id": part.id.uuidString,
                    "name": part.name,
                    "oem_part_number": part.oemPartNumber,
                    "part_number": part.partNumber,
                    "buy_url": part.buyURL,
                    "cost": part.cost,
                    "quantity": 1,
                    "sort_order": index,
                ]
            },
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
