import Foundation

struct MaintenanceCategory: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let icon: String
    let colorName: String
    let isBuiltIn: Bool
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case colorName = "color_name"
        case isBuiltIn = "is_built_in"
        case sortOrder = "sort_order"
    }
}

struct TaskPart: Identifiable, Codable, Hashable {
    let id: UUID?
    var name: String?
    var oemPartNumber: String?
    var partNumber: String?
    var buyURL: String?
    var cost: Double?
    var quantity: Double?
    var vendor: String?
    var notes: String?
    var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case oemPartNumber = "oem_part_number"
        case partNumber = "part_number"
        case buyURL = "buy_url"
        case cost
        case quantity
        case vendor
        case notes
        case sortOrder = "sort_order"
    }

    var displayPartNumber: String? {
        let primary = partNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primary.isEmpty { return primary }
        let oem = oemPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return oem.isEmpty ? nil : oem
    }

    var displayTitle: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let number = displayPartNumber {
            return number
        }
        return "Part"
    }
}

struct MaintenanceTask: Identifiable, Codable, Hashable {
    let id: UUID
    var area: String
    var item: String
    var categoryName: String
    var priority: String
    var frequency: String
    var taskDescription: String?
    var responseInstructions: String?
    var suppliesNeeded: String?
    var notes: String?
    var resultNotes: String?
    var estimatedMinutes: Int?
    var warningDays: Int
    var criticalDays: Int
    var lastDone: Date
    var nextDue: Date
    var sendTelegramUpdate: Bool
    var includeInDailyBriefing: Bool
    var alertIfOverdue: Bool
    var isActive: Bool
    var scheduleKind: String?
    var meterIntervalValue: Decimal?
    var meterIntervalUnit: String?
    var nextDueMeterValue: Decimal?
    var assetId: UUID?
    var remainingMeter: Decimal?
    var dueMeter: Bool?
    var overdueMeter: Bool?
    var partURL: String?
    var vendor: String?
    var partNumber: String?
    var partCost: Double?
    var annualCost: Double?
    var manufacturer: String?
    var sourceManualName: String?
    var origin: TaskOrigin
    var parts: [TaskPart]?
    var photoFileNames: [String]
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case area
        case item
        case categoryName = "category_name"
        case priority
        case frequency
        case taskDescription = "task_description"
        case responseInstructions = "response_instructions"
        case suppliesNeeded = "supplies_needed"
        case notes
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
        case scheduleKind = "schedule_kind"
        case meterIntervalValue = "meter_interval_value"
        case meterIntervalUnit = "meter_interval_unit"
        case nextDueMeterValue = "next_due_meter_value"
        case assetId = "asset_id"
        case remainingMeter = "remaining_meter"
        case dueMeter = "due_meter"
        case overdueMeter = "overdue_meter"
        case partURL = "part_url"
        case vendor
        case partNumber = "part_number"
        case partCost = "part_cost"
        case annualCost = "annual_cost"
        case manufacturer
        case sourceManualName = "source_manual_name"
        case origin
        case parts
        case photoFileNames = "photo_file_names"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        area = try c.decode(String.self, forKey: .area)
        item = try c.decode(String.self, forKey: .item)
        categoryName = try c.decode(String.self, forKey: .categoryName)
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
        sendTelegramUpdate = try c.decode(Bool.self, forKey: .sendTelegramUpdate)
        includeInDailyBriefing = try c.decode(Bool.self, forKey: .includeInDailyBriefing)
        alertIfOverdue = try c.decode(Bool.self, forKey: .alertIfOverdue)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind)
        meterIntervalValue = FlexibleDecimal.decodeDecimal(c, key: .meterIntervalValue)
        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)
        nextDueMeterValue = FlexibleDecimal.decodeDecimal(c, key: .nextDueMeterValue)
        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)
        remainingMeter = FlexibleDecimal.decodeDecimal(c, key: .remainingMeter)
        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
        partURL = try c.decodeIfPresent(String.self, forKey: .partURL)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber)
        partCost = try c.decodeIfPresent(Double.self, forKey: .partCost)
        annualCost = try c.decodeIfPresent(Double.self, forKey: .annualCost)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        sourceManualName = try c.decodeIfPresent(String.self, forKey: .sourceManualName)
        if let decoded = try c.decodeIfPresent(TaskOrigin.self, forKey: .origin) {
            origin = decoded
        } else {
            let manual = sourceManualName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            origin = manual.isEmpty ? .owner : .manufacturer
        }
        parts = try c.decodeIfPresent([TaskPart].self, forKey: .parts)
        photoFileNames = try c.decodeIfPresent([String].self, forKey: .photoFileNames) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var requiresMeterOnComplete: Bool {
        scheduleKind == "meter" || scheduleKind == "both"
    }

    var showsRunHoursTrigger: Bool {
        if assetId != nil { return true }
        let cat = categoryName.lowercased()
        return cat.contains("equipment") || cat.contains("tractor") || area.lowercased().contains("equipment")
    }

    var runHoursBadge: String? {
        if overdueMeter == true { return "Overdue" }
        if dueMeter == true { return "Due now" }
        if let rem = remainingMeter, rem > 0 {
            return "\(NSDecimalNumber(decimal: rem).stringValue) hrs left"
        }
        if let trigger = nextDueMeterValue {
            return "Due at \(NSDecimalNumber(decimal: trigger).stringValue) hrs"
        }
        return nil
    }

    var dueStatus: DueStatus {
        let now = Date()
        let seconds = nextDue.timeIntervalSince(now)
        let days = Int(seconds / 86_400)

        if nextDue < now {
            let overdueDays = max(1, Int(now.timeIntervalSince(nextDue) / 86_400))
            if overdueDays >= criticalDays {
                return .critical(overdueDays)
            }
            return .overdue(overdueDays)
        }

        if days <= warningDays {
            return .dueSoon(max(0, days))
        }
        return .ok(days)
    }

    var hasPartInfo: Bool {
        if let parts, !parts.isEmpty {
            return true
        }
        let hasText = [vendor, partNumber, partURL].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText || partCost != nil || annualCost != nil
    }

    var primaryPartNumber: String? {
        if let partNumber, !partNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return partNumber
        }
        return parts?.compactMap(\.displayPartNumber).first
    }
}

enum TaskOrigin: String, Codable, Hashable, CaseIterable, Identifiable {
    case manufacturer
    case owner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manufacturer:
            return "Manufacturer"
        case .owner:
            return "Owner-added"
        }
    }
}

enum OriginFilter: String, CaseIterable, Identifiable {
    case all = "All Origins"
    case manufacturer = "Manufacturer"
    case owner = "Owner-added"

    var id: String { rawValue }

    var matches: TaskOrigin? {
        switch self {
        case .all: return nil
        case .manufacturer: return .manufacturer
        case .owner: return .owner
        }
    }
}

enum DueStatus: Hashable {
    case ok(Int)
    case dueSoon(Int)
    case overdue(Int)
    case critical(Int)

    var label: String {
        switch self {
        case .ok(let days):
            return "Due in \(days)d"
        case .dueSoon(let days):
            return days == 0 ? "Due today" : "Due in \(days)d"
        case .overdue(let days):
            return "Overdue \(days)d"
        case .critical(let days):
            return "Critical \(days)d"
        }
    }

    var sortRank: Int {
        switch self {
        case .critical: return 0
        case .overdue: return 1
        case .dueSoon: return 2
        case .ok: return 3
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case due = "Due"
    case overdue = "Overdue"

    var id: String { rawValue }
}
