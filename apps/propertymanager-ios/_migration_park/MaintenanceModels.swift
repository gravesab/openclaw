import Foundation

enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case due = "Due"
    case overdue = "Overdue"

    var id: String { rawValue }
}

enum DueStatus: String, Codable {
    case ok
    case dueSoon = "due_soon"
    case overdue
    case critical

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
    var notes: String?
    var suppliesNeeded: String?
    var partNumber: String?
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
    var parts: [MaintenancePart]?

    enum CodingKeys: String, CodingKey {
        case id, area, item, priority, frequency, notes, vendor, parts
        case categoryName = "category_name"
        case taskDescription = "task_description"
        case suppliesNeeded = "supplies_needed"
        case partNumber = "part_number"
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
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        suppliesNeeded = try c.decodeIfPresent(String.self, forKey: .suppliesNeeded)
        partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber)
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
    let id: UUID
    var name: String
    var partNumber: String?
    var cost: Double?
    var quantity: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, cost, quantity
        case partNumber = "part_number"
    }
}
