import Foundation

struct AssetMeter: Codable, Hashable {
    var meterType: String
    var currentValue: Double?
    var unit: String
    var latestReadingAt: Date?
    var updatedAt: Date?
    var activated: Bool?

    enum CodingKeys: String, CodingKey {
        case meterType = "meter_type"
        case currentValue = "current_value"
        case unit
        case latestReadingAt = "latest_reading_at"
        case updatedAt = "updated_at"
        case activated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meterType = try c.decodeIfPresent(String.self, forKey: .meterType) ?? "none"
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        latestReadingAt = FlexibleDate.decode(c, key: .latestReadingAt)
        updatedAt = FlexibleDate.decode(c, key: .updatedAt)
        activated = try c.decodeIfPresent(Bool.self, forKey: .activated)
        currentValue = FlexibleDecimal.decode(c, key: .currentValue)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meterType, forKey: .meterType)
        try c.encodeIfPresent(currentValue, forKey: .currentValue)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(latestReadingAt, forKey: .latestReadingAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(activated, forKey: .activated)
    }

    var updateButtonTitle: String {
        switch meterType {
        case "runtime_hours": return "Update Hours"
        case "mileage": return "Update Miles"
        case "cycles": return "Update Cycles"
        default: return "Update Meter"
        }
    }

    var hasMeter: Bool { meterType != "none" && (activated ?? true) }
}

struct ProposedMeter: Codable, Hashable {
    var meterType: String?
    var unit: String?
    var activatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case meterType = "meter_type"
        case unit
        case activatedAt = "activated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meterType = try c.decodeIfPresent(String.self, forKey: .meterType)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        activatedAt = FlexibleDate.decode(c, key: .activatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(meterType, forKey: .meterType)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(activatedAt, forKey: .activatedAt)
    }
}

struct AssetTaskSummary: Codable, Hashable, Identifiable {
    var id: UUID
    var item: String
    var scheduleKind: String?
    var meterIntervalValue: Decimal?
    var meterIntervalUnit: String?
    var nextDueMeterValue: Decimal?
    var remainingMeter: Decimal?
    var dueMeter: Bool?
    var overdueMeter: Bool?

    enum CodingKeys: String, CodingKey {
        case id, item
        case scheduleKind = "schedule_kind"
        case meterIntervalValue = "meter_interval_value"
        case meterIntervalUnit = "meter_interval_unit"
        case nextDueMeterValue = "next_due_meter_value"
        case remainingMeter = "remaining_meter"
        case dueMeter = "due_meter"
        case overdueMeter = "overdue_meter"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try FlexibleUUID.decode(c, key: .id)
        item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind)
        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)
        meterIntervalValue = FlexibleDecimal.decodeDecimal(c, key: .meterIntervalValue)
        nextDueMeterValue = FlexibleDecimal.decodeDecimal(c, key: .nextDueMeterValue)
        remainingMeter = FlexibleDecimal.decodeDecimal(c, key: .remainingMeter)
        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(item, forKey: .item)
        try c.encodeIfPresent(scheduleKind, forKey: .scheduleKind)
        try c.encodeIfPresent(meterIntervalValue, forKey: .meterIntervalValue)
        try c.encodeIfPresent(meterIntervalUnit, forKey: .meterIntervalUnit)
        try c.encodeIfPresent(nextDueMeterValue, forKey: .nextDueMeterValue)
        try c.encodeIfPresent(remainingMeter, forKey: .remainingMeter)
        try c.encodeIfPresent(dueMeter, forKey: .dueMeter)
        try c.encodeIfPresent(overdueMeter, forKey: .overdueMeter)
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
}

struct AssetPMSummary: Codable, Hashable {
    var overdueMeterCount: Int
    var dueSoonCount: Int

    enum CodingKeys: String, CodingKey {
        case overdueMeterCount = "overdue_meter_count"
        case dueSoonCount = "due_soon_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overdueMeterCount = try c.decodeIfPresent(Int.self, forKey: .overdueMeterCount) ?? 0
        dueSoonCount = try c.decodeIfPresent(Int.self, forKey: .dueSoonCount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overdueMeterCount, forKey: .overdueMeterCount)
        try c.encode(dueSoonCount, forKey: .dueSoonCount)
    }
}

struct RanchAsset: Identifiable, Codable, Hashable {
    let id: UUID
    var externalId: String
    var name: String
    var manufacturer: String?
    var model: String?
    var category: String?
    var location: String?
    var aliases: [String]?
    var qrToken: String?
    var meter: AssetMeter?
    var proposedMeter: ProposedMeter?
    var meterActivatedAt: Date?
    var tasks: [AssetTaskSummary]?
    var pmSummary: AssetPMSummary?

    enum CodingKeys: String, CodingKey {
        case id, name, manufacturer, model, category, location, aliases, tasks, meter
        case externalId = "external_id"
        case qrToken = "qr_token"
        case proposedMeter = "proposed_meter"
        case meterActivatedAt = "meter_activated_at"
        case pmSummary = "pm_summary"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try FlexibleUUID.decode(c, key: .id)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId) ?? ""
        name = try c.decode(String.self, forKey: .name)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
        qrToken = try c.decodeIfPresent(String.self, forKey: .qrToken)
        meter = try c.decodeIfPresent(AssetMeter.self, forKey: .meter)
        proposedMeter = try c.decodeIfPresent(ProposedMeter.self, forKey: .proposedMeter)
        meterActivatedAt = FlexibleDate.decode(c, key: .meterActivatedAt)
        tasks = try c.decodeIfPresent([AssetTaskSummary].self, forKey: .tasks)
        pmSummary = try c.decodeIfPresent(AssetPMSummary.self, forKey: .pmSummary)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(externalId, forKey: .externalId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(aliases, forKey: .aliases)
        try c.encodeIfPresent(qrToken, forKey: .qrToken)
        try c.encodeIfPresent(meter, forKey: .meter)
        try c.encodeIfPresent(proposedMeter, forKey: .proposedMeter)
        try c.encodeIfPresent(meterActivatedAt, forKey: .meterActivatedAt)
        try c.encodeIfPresent(tasks, forKey: .tasks)
        try c.encodeIfPresent(pmSummary, forKey: .pmSummary)
    }

    var meterNeedsActivation: Bool {
        meterActivatedAt == nil && proposedMeter?.meterType != nil && proposedMeter?.meterType != "none"
    }
}

struct MeterReading: Identifiable, Codable, Hashable {
    let id: UUID
    var assetId: UUID
    var value: Double
    var readingAt: Date
    var entryMethod: String?
    var note: String?
    var correctionReason: String?
    var usageSincePrevious: Double?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, value, note
        case assetId = "asset_id"
        case readingAt = "reading_at"
        case entryMethod = "entry_method"
        case correctionReason = "correction_reason"
        case usageSincePrevious = "usage_since_previous"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try FlexibleUUID.decode(c, key: .id)
        assetId = try FlexibleUUID.decode(c, key: .assetId)
        if let date = FlexibleDate.decode(c, key: .readingAt) {
            readingAt = date
        } else {
            readingAt = try c.decode(Date.self, forKey: .readingAt)
        }
        entryMethod = try c.decodeIfPresent(String.self, forKey: .entryMethod)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        correctionReason = try c.decodeIfPresent(String.self, forKey: .correctionReason)
        createdAt = FlexibleDate.decode(c, key: .createdAt)
        value = FlexibleDecimal.decode(c, key: .value) ?? 0
        usageSincePrevious = FlexibleDecimal.decode(c, key: .usageSincePrevious)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(value, forKey: .value)
        try c.encode(readingAt, forKey: .readingAt)
        try c.encodeIfPresent(entryMethod, forKey: .entryMethod)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(correctionReason, forKey: .correctionReason)
        try c.encodeIfPresent(usageSincePrevious, forKey: .usageSincePrevious)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

struct MeterParseResult: Codable {
    var assetId: UUID
    var assetName: String?
    var value: Double
    var unit: String?
    var meterType: String?
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case value, unit, confidence
        case assetId = "asset_id"
        case assetName = "asset_name"
        case meterType = "meter_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try FlexibleUUID.decode(c, key: .assetId)
        assetName = try c.decodeIfPresent(String.self, forKey: .assetName)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        meterType = try c.decodeIfPresent(String.self, forKey: .meterType)
        confidence = FlexibleDecimal.decode(c, key: .confidence)
        value = FlexibleDecimal.decode(c, key: .value) ?? 0
    }
}

struct LowerReadingPreview: Codable {
    var code: String
    var previousValue: String?
    var proposedValue: String?
    var options: [String]?
    var previewToken: String

    enum CodingKeys: String, CodingKey {
        case code, options
        case previousValue = "previous_value"
        case proposedValue = "proposed_value"
        case previewToken = "preview_token"
    }
}

// MARK: - Flexible decoding (live API: string decimals, UUID strings, Postgres timestamps)

enum FlexibleDecimal {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d
        }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) {
            return Double(i)
        }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else {
            return nil
        }
        return Double(s)
    }

    static func decodeDecimal<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) -> Decimal? {
        if let d = try? c.decodeIfPresent(Decimal.self, forKey: key) {
            return d
        }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) {
            return Decimal(i)
        }
        if let dbl = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Decimal(string: String(dbl))
        }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else {
            return nil
        }
        return Decimal(string: s.replacingOccurrences(of: ",", with: "."))
    }
}

enum FlexibleUUID {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> UUID {
        if let id = try? c.decode(UUID.self, forKey: key) {
            return id
        }
        let raw = try c.decode(String.self, forKey: key)
        guard let id = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: c,
                debugDescription: "Invalid UUID string: \(raw)"
            )
        }
        return id
    }
}

/// Postgres/Flask timestamps often have 1–6 fractional digits; Apple ISO8601 is picky.
enum FlexibleDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) -> Date? {
        if c.contains(key), (try? c.decodeNil(forKey: key)) == true {
            return nil
        }
        if let date = try? c.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        guard let raw = try? c.decodeIfPresent(String.self, forKey: key), !raw.isEmpty else {
            return nil
        }
        return parse(raw)
    }

    static func parse(_ raw: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: raw) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        if let normalized = normalizeFractional(raw) {
            if let date = fractional.date(from: normalized) {
                return date
            }
            if let date = full.date(from: normalized) {
                return date
            }
        }
        return nil
    }

    private static func normalizeFractional(_ raw: String) -> String? {
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let afterDot = raw.index(after: dot)
        var end = afterDot
        while end < raw.endIndex, raw[end].isNumber {
            end = raw.index(after: end)
        }
        let frac = String(raw[afterDot..<end])
        guard !frac.isEmpty else { return nil }
        let padded: String
        if frac.count >= 3 {
            padded = String(frac.prefix(3))
        } else {
            padded = frac.padding(toLength: 3, withPad: "0", startingAt: 0)
        }
        return String(raw[..<afterDot]) + padded + String(raw[end...])
    }
}
