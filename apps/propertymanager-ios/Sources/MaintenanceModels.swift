import Foundation

enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case due = "Due"
    case overdue = "Overdue"

    var id: String { rawValue }
}

/// Matches Mac PropertyManager labels (`manufacturer` / `owner` from API `origin`).
enum TaskOrigin: String, Codable, Hashable, CaseIterable, Identifiable {
    case manufacturer
    case owner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manufacturer: return "Manufacturer"
        case .owner: return "Owner-added"
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

enum DueStatus: String, Codable {
    case ok
    case dueSoon = "due_soon"
    case overdue
    case critical

    var label: String {
        switch self {
        case .ok: return "OK"
        case .dueSoon: return "Due soon"
        case .overdue: return "Overdue"
        case .critical: return "Critical"
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

struct MaintenanceCategory: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var colorName: String?
    var isBuiltIn: Bool
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case colorName = "color_name"
        case isBuiltIn = "is_built_in"
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
        colorName = try c.decodeIfPresent(String.self, forKey: .colorName)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
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
    var notes: String?
    var suppliesNeeded: String?
    var partNumber: String?
    var partURL: String?
    var partCost: Double?
    var annualCost: Double?
    var vendor: String?
    var estimatedMinutes: Int?
    var warningDays: Int
    var criticalDays: Int
    var lastDone: Date?
    var nextDue: Date
    var scheduleKind: String?
    var meterIntervalValue: Decimal?
    var meterIntervalUnit: String?
    var nextDueMeterValue: Decimal?
    var assetId: UUID?
    var remainingMeter: Decimal?
    var dueMeter: Bool?
    var overdueMeter: Bool?
    var isActive: Bool
    var primaryPartNumber: String?
    var manufacturer: String?
    var sourceManualName: String?
    var origin: TaskOrigin
    var parts: [MaintenancePart]?

    enum CodingKeys: String, CodingKey {
        case id, area, item, priority, frequency, notes, vendor, parts, manufacturer, origin
        case categoryName = "category_name"
        case taskDescription = "task_description"
        case responseInstructions = "response_instructions"
        case suppliesNeeded = "supplies_needed"
        case partNumber = "part_number"
        case partURL = "part_url"
        case partCost = "part_cost"
        case annualCost = "annual_cost"
        case estimatedMinutes = "estimated_minutes"
        case warningDays = "warning_days"
        case criticalDays = "critical_days"
        case lastDone = "last_done"
        case nextDue = "next_due"
        case scheduleKind = "schedule_kind"
        case meterIntervalValue = "meter_interval_value"
        case meterIntervalUnit = "meter_interval_unit"
        case nextDueMeterValue = "next_due_meter_value"
        case assetId = "asset_id"
        case remainingMeter = "remaining_meter"
        case dueMeter = "due_meter"
        case overdueMeter = "overdue_meter"
        case isActive = "is_active"
        case primaryPartNumber = "primary_part_number"
        case sourceManualName = "source_manual_name"
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
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        suppliesNeeded = try c.decodeIfPresent(String.self, forKey: .suppliesNeeded)
        partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber)
        partURL = try c.decodeIfPresent(String.self, forKey: .partURL)
        partCost = try c.decodeIfPresent(Double.self, forKey: .partCost)
        annualCost = try c.decodeIfPresent(Double.self, forKey: .annualCost)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        warningDays = try c.decodeIfPresent(Int.self, forKey: .warningDays) ?? 7
        criticalDays = try c.decodeIfPresent(Int.self, forKey: .criticalDays) ?? 14
        lastDone = try c.decodeIfPresent(Date.self, forKey: .lastDone)
        nextDue = try c.decode(Date.self, forKey: .nextDue)
        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind)
        meterIntervalValue = FlexibleDecimal.decodeDecimal(c, key: .meterIntervalValue)
        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)
        nextDueMeterValue = FlexibleDecimal.decodeDecimal(c, key: .nextDueMeterValue)
        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)
        remainingMeter = FlexibleDecimal.decodeDecimal(c, key: .remainingMeter)
        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        primaryPartNumber = try c.decodeIfPresent(String.self, forKey: .primaryPartNumber)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        sourceManualName = try c.decodeIfPresent(String.self, forKey: .sourceManualName)
        if let decoded = try c.decodeIfPresent(TaskOrigin.self, forKey: .origin) {
            origin = decoded
        } else {
            let manual = sourceManualName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            origin = manual.isEmpty ? .owner : .manufacturer
        }
        parts = try c.decodeIfPresent([MaintenancePart].self, forKey: .parts)
    }

    var dueStatus: DueStatus {
        let now = Date()
        if nextDue < now {
            let daysPast = Calendar.current.dateComponents([.day], from: nextDue, to: now).day ?? 0
            if daysPast >= criticalDays { return .critical }
            return .overdue
        }
        let daysUntil = Calendar.current.dateComponents([.day], from: now, to: nextDue).day ?? 999
        if daysUntil <= warningDays { return .dueSoon }
        return .ok
    }

    var requiresMeterOnComplete: Bool {
        scheduleKind == "meter" || scheduleKind == "both"
    }

    /// Controlling rule: linked activated runtime_hours asset (category is not authoritative).
    func showsRunHoursTrigger(linkedAsset: RanchAsset?) -> Bool {
        guard assetId != nil, let linkedAsset else { return false }
        return linkedAsset.meter?.meterType == "runtime_hours" && linkedAsset.meterActivatedAt != nil
    }

    /// Edit-sheet heuristic when the linked asset is not loaded yet.
    var showsRunHoursTrigger: Bool {
        if assetId != nil { return true }
        let cat = categoryName.lowercased()
        return cat.contains("equipment") || cat.contains("tractor") || area.lowercased().contains("equipment")
    }

    var hasPartInfo: Bool {
        if let parts, !parts.isEmpty { return true }
        let hasText = [vendor, partNumber, partURL].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText || partCost != nil || annualCost != nil
    }

    var runHoursBadge: String? {
        if overdueMeter == true { return "Overdue" }
        if dueMeter == true { return "Due now" }
        if let rem = remainingMeter, rem > 0 {
            return "\(Self.formatMeter(rem)) hrs left"
        }
        if let trigger = nextDueMeterValue {
            return "Due at \(Self.formatMeter(trigger)) hrs"
        }
        return nil
    }

    private static func formatMeter(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

struct MaintenancePart: Identifiable, Codable, Hashable {
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
        case id, name, cost, quantity, vendor, notes
        case oemPartNumber = "oem_part_number"
        case partNumber = "part_number"
        case buyURL = "buy_url"
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
        if let number = displayPartNumber { return number }
        return "Part"
    }
}

typealias TaskPart = MaintenancePart
