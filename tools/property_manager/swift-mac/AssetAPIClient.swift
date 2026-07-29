import Foundation

// Mac PropertyManager asset API extensions (mirrors iPhone client).
// Uses v1/ path prefix compatible with Mac PropertyAPIClient.makeURL.
// Decodes live GET /v1/assets: bare array of assets with nested meter/proposed_meter,
// decimal strings, UUID strings, and optional fields.

extension PropertyAPIClient {
    func fetchAssets() async throws -> [MacRanchAsset] {
        let url = try makeURL("v1/assets")
        let (data, response) = try await Self.sharedSession.data(from: url)
        try validate(response, data: data)
        return try MacAssetList.decode(from: data, using: decoder)
    }

    func fetchAsset(id: UUID) async throws -> MacRanchAsset {
        let url = try makeURL("v1/assets/\(id.uuidString)")
        let (data, response) = try await Self.sharedSession.data(from: url)
        try validate(response, data: data)
        return try decoder.decode(MacRanchAsset.self, from: data)
    }

    func fetchMeterReadings(assetId: UUID, limit: Int = 50) async throws -> [MacMeterReading] {
        let url = try makeURL("v1/assets/\(assetId.uuidString)/meter-readings?limit=\(limit)")
        let (data, response) = try await Self.sharedSession.data(from: url)
        try validate(response, data: data)
        let page = try decoder.decode(MacMeterReadingPage.self, from: data)
        return page.items
    }

    func submitMeterReading(
        assetId: UUID,
        value: Double,
        note: String?,
        entryMethod: String = "manual"
    ) async throws -> MacRanchAsset {
        let url = try makeURL("v1/assets/\(assetId.uuidString)/meter-readings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        meterApplyAuth(&request)
        var body: [String: Any] = ["value": String(value), "entry_method": entryMethod]
        if let note, !note.isEmpty { body["note"] = note }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.sharedSession.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            if let preview = try? JSONDecoder().decode(MacLowerReadingPreview.self, from: data),
               preview.code == "LOWER_READING_CONFIRMATION_REQUIRED" {
                throw MacMeterError.lowerReadingConfirmation(preview)
            }
        }
        try validate(response, data: data)
        let result = try decoder.decode(MacMeterReadingResult.self, from: data)
        return result.asset
    }

    func confirmMeterReading(
        assetId: UUID,
        preview: MacLowerReadingPreview,
        correctionReason: String,
        note: String? = nil
    ) async throws -> MacRanchAsset {
        let url = try makeURL("v1/assets/\(assetId.uuidString)/meter-readings/confirm")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        meterApplyAuth(&request)
        var body: [String: Any] = [
            "preview_token": preview.previewToken,
            "correction_reason": correctionReason,
            "operator_identity": "mac-operator",
        ]
        if let note, !note.isEmpty { body["note"] = note }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.sharedSession.data(for: request)
        try validate(response, data: data)
        let result = try decoder.decode(MacMeterReadingResult.self, from: data)
        return result.asset
    }

    func activateMeter(assetId: UUID) async throws -> MacRanchAsset {
        let url = try makeURL("v1/assets/\(assetId.uuidString)/activate-meter")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        meterApplyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: String])
        let (data, response) = try await Self.sharedSession.data(for: request)
        try validate(response, data: data)
        let result = try decoder.decode(MacActivateMeterResult.self, from: data)
        return result.asset
    }

    /// Auth headers for meter mutating calls (API key and/or operator PIN).
    fileprivate func meterApplyAuth(_ request: inout URLRequest) {
        applyAuth(&request)
    }
}

enum MacMeterError: LocalizedError {
    case lowerReadingConfirmation(MacLowerReadingPreview)

    var errorDescription: String? {
        switch self {
        case .lowerReadingConfirmation:
            return "Reading is lower than current. Confirmation required."
        }
    }
}

/// Accepts live bare `[...]` or `{ "items": [...] }` wrappers.
private enum MacAssetList {
    private struct Wrapped: Decodable {
        var items: [MacRanchAsset]
    }

    static func decode(from data: Data, using decoder: JSONDecoder) throws -> [MacRanchAsset] {
        if let list = try? decoder.decode([MacRanchAsset].self, from: data) {
            return list
        }
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            return wrapped.items
        }
        return try decoder.decode([MacRanchAsset].self, from: data)
    }
}

private struct MacMeterReadingPage: Codable {
    var items: [MacMeterReading]
}

private struct MacMeterReadingResult: Codable {
    var asset: MacRanchAsset
}

private struct MacActivateMeterResult: Codable {
    var asset: MacRanchAsset
}

struct MacLowerReadingPreview: Codable {
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

struct MacAssetMeter: Codable, Hashable, Identifiable {
    var id: UUID { assetId }
    let assetId: UUID
    var meterType: String
    var currentValue: Double?
    var unit: String
    var latestReadingAt: Date?
    var activated: Bool?

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case meterType = "meter_type"
        case currentValue = "current_value"
        case unit
        case latestReadingAt = "latest_reading_at"
        case activated
    }

    init(from asset: MacRanchAsset) {
        assetId = asset.id
        meterType = asset.meter?.meterType ?? "none"
        currentValue = asset.meter?.currentValue
        unit = asset.meter?.unit ?? ""
        latestReadingAt = asset.meter?.latestReadingAt
        activated = asset.meter?.activated
    }
}

struct MacRanchAsset: Identifiable, Codable, Hashable {
    let id: UUID
    var externalId: String
    var name: String
    var category: String?
    var meter: MacMeterInfo?
    var proposedMeter: MacProposedMeter?
    var meterActivatedAt: Date?
    var tasks: [MacAssetTaskSummary]?
    var pmSummary: MacPMSummary?

    enum CodingKeys: String, CodingKey {
        case id, name, category, meter, tasks
        case externalId = "external_id"
        case proposedMeter = "proposed_meter"
        case meterActivatedAt = "meter_activated_at"
        case pmSummary = "pm_summary"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try MacFlexibleUUID.decode(c, key: .id)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId) ?? ""
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        meter = try c.decodeIfPresent(MacMeterInfo.self, forKey: .meter)
        proposedMeter = try c.decodeIfPresent(MacProposedMeter.self, forKey: .proposedMeter)
        meterActivatedAt = MacFlexibleDate.decode(c, key: .meterActivatedAt)
        tasks = try c.decodeIfPresent([MacAssetTaskSummary].self, forKey: .tasks)
        pmSummary = try c.decodeIfPresent(MacPMSummary.self, forKey: .pmSummary)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(externalId, forKey: .externalId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
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

struct MacProposedMeter: Codable, Hashable {
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
        activatedAt = MacFlexibleDate.decode(c, key: .activatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(meterType, forKey: .meterType)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(activatedAt, forKey: .activatedAt)
    }
}

struct MacMeterInfo: Codable, Hashable {
    var meterType: String
    var currentValue: Double?
    var unit: String
    var latestReadingAt: Date?
    var activated: Bool?

    enum CodingKeys: String, CodingKey {
        case meterType = "meter_type"
        case currentValue = "current_value"
        case unit
        case latestReadingAt = "latest_reading_at"
        case activated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meterType = try c.decodeIfPresent(String.self, forKey: .meterType) ?? "none"
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        latestReadingAt = MacFlexibleDate.decode(c, key: .latestReadingAt)
        activated = try c.decodeIfPresent(Bool.self, forKey: .activated)
        currentValue = MacDecimal.decode(c, key: .currentValue)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meterType, forKey: .meterType)
        try c.encodeIfPresent(currentValue, forKey: .currentValue)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(latestReadingAt, forKey: .latestReadingAt)
        try c.encodeIfPresent(activated, forKey: .activated)
    }

    var hasMeter: Bool { meterType != "none" && (activated ?? true) }
    var updateTitle: String {
        switch meterType {
        case "runtime_hours": return "Update Hours"
        case "mileage": return "Update Miles"
        case "cycles": return "Update Cycles"
        default: return "Update Meter"
        }
    }
}

struct MacAssetTaskSummary: Codable, Hashable, Identifiable {
    let id: UUID
    var item: String
    var remainingMeter: Double?
    var overdueMeter: Bool?

    enum CodingKeys: String, CodingKey {
        case id, item
        case remainingMeter = "remaining_meter"
        case overdueMeter = "overdue_meter"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try MacFlexibleUUID.decode(c, key: .id)
        item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
        // Live API returns Decimal as JSON string (e.g. "50"), not number.
        remainingMeter = MacDecimal.decode(c, key: .remainingMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(item, forKey: .item)
        try c.encodeIfPresent(remainingMeter, forKey: .remainingMeter)
        try c.encodeIfPresent(overdueMeter, forKey: .overdueMeter)
    }
}

struct MacPMSummary: Codable, Hashable {
    var overdueMeterCount: Int
    var dueSoonCount: Int?

    enum CodingKeys: String, CodingKey {
        case overdueMeterCount = "overdue_meter_count"
        case dueSoonCount = "due_soon_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overdueMeterCount = try c.decodeIfPresent(Int.self, forKey: .overdueMeterCount) ?? 0
        dueSoonCount = try c.decodeIfPresent(Int.self, forKey: .dueSoonCount)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overdueMeterCount, forKey: .overdueMeterCount)
        try c.encodeIfPresent(dueSoonCount, forKey: .dueSoonCount)
    }
}

struct MacMeterReading: Identifiable, Codable, Hashable {
    let id: UUID
    var value: Double
    var readingAt: Date
    var usageSincePrevious: Double?

    enum CodingKeys: String, CodingKey {
        case id, value
        case readingAt = "reading_at"
        case usageSincePrevious = "usage_since_previous"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try MacFlexibleUUID.decode(c, key: .id)
        if let date = MacFlexibleDate.decode(c, key: .readingAt) {
            readingAt = date
        } else {
            readingAt = try c.decode(Date.self, forKey: .readingAt)
        }
        value = MacDecimal.decode(c, key: .value) ?? 0
        usageSincePrevious = MacDecimal.decode(c, key: .usageSincePrevious)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(value, forKey: .value)
        try c.encode(readingAt, forKey: .readingAt)
        try c.encodeIfPresent(usageSincePrevious, forKey: .usageSincePrevious)
    }
}

private enum MacDecimal {
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
}

private enum MacFlexibleUUID {
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
private enum MacFlexibleDate {
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
        // Normalize variable-length fractional seconds to 3 digits for Apple parsers.
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
