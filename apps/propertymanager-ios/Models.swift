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
    var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case oemPartNumber = "oem_part_number"
        case partNumber = "part_number"
        case buyURL = "buy_url"
        case cost
        case sortOrder = "sort_order"
    }

    var displayPartNumber: String? {
        let primary = partNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primary.isEmpty { return primary }
        let oem = oemPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return oem.isEmpty ? nil : oem
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
    var partURL: String?
    var vendor: String?
    var partNumber: String?
    var partCost: Double?
    var annualCost: Double?
    var parts: [TaskPart]?
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
        case partURL = "part_url"
        case vendor
        case partNumber = "part_number"
        case partCost = "part_cost"
        case annualCost = "annual_cost"
        case parts
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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
