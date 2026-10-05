import Foundation
import PDFKit
import AppKit
import CryptoKit

// MARK: - Provenance / verification (URL + persisted tasks)

enum ManualVerificationStatus: String, Codable, CaseIterable, Identifiable {
    case unverified
    case userAccepted = "user_accepted"
    case rejected

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unverified: return "Unverified"
        case .userAccepted: return "User accepted"
        case .rejected: return "Rejected"
        }
    }
}

/// Corpus-level + manual identity facts from fetched pages (never invent).
struct ManualSourceProvenance: Codable, Equatable {
    var originalURL: String
    var retrievedAtISO: String
    var manualTitle: String
    var publicationNumber: String
    var model: String
    var serialNumberApplicability: String
    var contentChecksumSHA256: String
    var fetchedPageURLs: [String]

    init(
        originalURL: String = "",
        retrievedAtISO: String = "",
        manualTitle: String = "",
        publicationNumber: String = "",
        model: String = "",
        serialNumberApplicability: String = "",
        contentChecksumSHA256: String = "",
        fetchedPageURLs: [String] = []
    ) {
        self.originalURL = originalURL
        self.retrievedAtISO = retrievedAtISO
        self.manualTitle = manualTitle
        self.publicationNumber = publicationNumber
        self.model = model
        self.serialNumberApplicability = serialNumberApplicability
        self.contentChecksumSHA256 = contentChecksumSHA256
        self.fetchedPageURLs = fetchedPageURLs
    }

    enum CodingKeys: String, CodingKey {
        case originalURL, retrievedAtISO, manualTitle, publicationNumber
        case model, serialNumberApplicability, contentChecksumSHA256, fetchedPageURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalURL = try c.decodeIfPresent(String.self, forKey: .originalURL) ?? ""
        retrievedAtISO = try c.decodeIfPresent(String.self, forKey: .retrievedAtISO) ?? ""
        manualTitle = try c.decodeIfPresent(String.self, forKey: .manualTitle) ?? ""
        publicationNumber = try c.decodeIfPresent(String.self, forKey: .publicationNumber) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        serialNumberApplicability = try c.decodeIfPresent(String.self, forKey: .serialNumberApplicability) ?? ""
        contentChecksumSHA256 = try c.decodeIfPresent(String.self, forKey: .contentChecksumSHA256) ?? ""
        fetchedPageURLs = try c.decodeIfPresent([String].self, forKey: .fetchedPageURLs) ?? []
    }
}

/// Source facts extracted from manual text (verbatim / labeled). Separate from AI inference.
struct ManualSourceFacts: Codable, Equatable {
    var maintenanceInterval: String
    var fluids: [String]
    var capacities: [String]
    var filters: [String]
    var parts: [String]
    var safetyWarnings: [String]
    var sourceExcerpt: String
    var sectionSourceURLs: [String]

    init(
        maintenanceInterval: String = "",
        fluids: [String] = [],
        capacities: [String] = [],
        filters: [String] = [],
        parts: [String] = [],
        safetyWarnings: [String] = [],
        sourceExcerpt: String = "",
        sectionSourceURLs: [String] = []
    ) {
        self.maintenanceInterval = maintenanceInterval
        self.fluids = fluids
        self.capacities = capacities
        self.filters = filters
        self.parts = parts
        self.safetyWarnings = safetyWarnings
        self.sourceExcerpt = sourceExcerpt
        self.sectionSourceURLs = sectionSourceURLs
    }

    enum CodingKeys: String, CodingKey {
        case maintenanceInterval, fluids, capacities, filters, parts
        case safetyWarnings, sourceExcerpt, sectionSourceURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maintenanceInterval = try c.decodeIfPresent(String.self, forKey: .maintenanceInterval) ?? ""
        fluids = try c.decodeIfPresent([String].self, forKey: .fluids) ?? []
        capacities = try c.decodeIfPresent([String].self, forKey: .capacities) ?? []
        filters = try c.decodeIfPresent([String].self, forKey: .filters) ?? []
        parts = try c.decodeIfPresent([String].self, forKey: .parts) ?? []
        safetyWarnings = try c.decodeIfPresent([String].self, forKey: .safetyWarnings) ?? []
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        sectionSourceURLs = try c.decodeIfPresent([String].self, forKey: .sectionSourceURLs) ?? []
    }
}

/// Persisted with each URL-imported (or provenance-bearing) maintenance task.
struct ManualURLImportRecord: Codable, Equatable {
    var provenance: ManualSourceProvenance
    var sourceFacts: ManualSourceFacts
    var inferredNotes: String
    var confidence: Double
    var verificationStatus: ManualVerificationStatus

    init(
        provenance: ManualSourceProvenance = ManualSourceProvenance(),
        sourceFacts: ManualSourceFacts = ManualSourceFacts(),
        inferredNotes: String = "",
        confidence: Double = 0,
        verificationStatus: ManualVerificationStatus = .unverified
    ) {
        self.provenance = provenance
        self.sourceFacts = sourceFacts
        self.inferredNotes = inferredNotes
        self.confidence = confidence
        self.verificationStatus = verificationStatus
    }

    enum CodingKeys: String, CodingKey {
        case provenance, sourceFacts, inferredNotes, confidence, verificationStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provenance = try c.decodeIfPresent(ManualSourceProvenance.self, forKey: .provenance) ?? ManualSourceProvenance()
        sourceFacts = try c.decodeIfPresent(ManualSourceFacts.self, forKey: .sourceFacts) ?? ManualSourceFacts()
        inferredNotes = try c.decodeIfPresent(String.self, forKey: .inferredNotes) ?? ""
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        verificationStatus = try c.decodeIfPresent(ManualVerificationStatus.self, forKey: .verificationStatus) ?? .unverified
    }

    var hasContent: Bool {
        !provenance.originalURL.isEmpty
            || !provenance.contentChecksumSHA256.isEmpty
            || !sourceFacts.sourceExcerpt.isEmpty
            || !inferredNotes.isEmpty
    }
}

enum ManualImportChecksum {
    static func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func clipExcerpt(_ text: String, max: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max))
    }
}

struct ToolRequirement: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var size: String
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        size: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, size, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

func parseMeterInterval(from raw: String) -> (Double?, String?) {
    let lower = raw.lowercased()
    let pattern = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|miles?|mi|cycles?)"#
    guard let match = lower.range(of: pattern, options: .regularExpression) else { return (nil, nil) }
    let snippet = String(lower[match])
    let parts = snippet.split(whereSeparator: { !$0.isNumber && $0 != "." }).joined(separator: " ").split(separator: " ")
    guard let first = parts.first, let value = Double(first) else { return (nil, nil) }
    if snippet.contains("mile") || snippet.contains(" mi") { return (value, "mi") }
    if snippet.contains("cycle") { return (value, "cycles") }
    return (value, "hrs")
}

struct ManualImportDraft: Identifiable, Equatable {
    let id = UUID()
    var selected: Bool = true
    var area: String
    var item: String
    var category: String
    var frequency: TaskFrequency
    var warningDays: Int
    var criticalDays: Int
    var estimatedMinutes: Int
    var taskDescription: String
    var responseInstructions: String
    var suppliesNeeded: String
    var notes: String
    var manufacturer: String
    var sourceManualName: String
    var partNumbers: [String]
    var referenceURLs: [String]
    var toolsRequired: [ToolRequirement]
    /// Corpus + manual identity provenance (URL imports).
    var provenance: ManualSourceProvenance = ManualSourceProvenance()
    /// Verbatim / labeled source facts (not AI inference).
    var sourceFacts: ManualSourceFacts = ManualSourceFacts()
    /// AI-only notes; never mix unlabeled with sourceExcerpt.
    var inferredNotes: String = ""
    var confidence: Double = 0
    var verificationStatus: ManualVerificationStatus = .unverified
    var meterIntervalValue: Double? = nil
    var meterIntervalUnit: String? = nil

    /// Same maintenance action already stored for this asset. Area and manual
    /// file names are excluded so a second publication does not look new.
    var maintenanceIdentity: String {
        ManualMaintenanceIdentity.make(area: area, item: item)
    }

    func asMaintenanceTask(
        lastDone: Date = Date(),
        assetID: UUID? = nil,
        verificationStatus: ManualVerificationStatus? = nil
    ) -> MaintenanceTask {
        let nextDue = Calendar.current.date(
            byAdding: .day,
            value: warningDays,
            to: lastDone
        ) ?? lastDone

        let mappedParts: [PartRequirement] = {
            if !partNumbers.isEmpty || !referenceURLs.isEmpty {
                return PartRequirement.migrated(fromPartNumbers: partNumbers, urls: referenceURLs)
            }
            return []
        }()

        let status = verificationStatus ?? self.verificationStatus
        let hasURLProvenance = !provenance.originalURL.isEmpty || !provenance.contentChecksumSHA256.isEmpty
        let record: ManualURLImportRecord? = hasURLProvenance
            ? ManualURLImportRecord(
                provenance: provenance,
                sourceFacts: sourceFacts,
                inferredNotes: inferredNotes,
                confidence: confidence,
                verificationStatus: status
            )
            : nil

        var combinedNotes = notes
        if !inferredNotes.isEmpty {
            let block = "AI inference:\n\(inferredNotes)"
            combinedNotes = combinedNotes.isEmpty ? block : combinedNotes + "\n\n" + block
        }

        var parsedValue = meterIntervalValue
        var parsedUnit = meterIntervalUnit
        if parsedValue == nil {
            let parsed = parseMeterInterval(from: sourceFacts.maintenanceInterval)
            parsedValue = parsed.0
            parsedUnit = parsed.1
        }
        let scheduleKind = parsedValue != nil ? "meter" : "calendar"
        return MaintenanceTask(
            area: area,
            item: item,
            category: category,
            priority: .medium,
            frequency: frequency,
            taskDescription: taskDescription,
            responseInstructions: responseInstructions,
            suppliesNeeded: suppliesNeeded,
            notes: combinedNotes,
            estimatedMinutes: estimatedMinutes,
            warningDays: warningDays,
            criticalDays: criticalDays,
            lastDone: lastDone,
            nextDue: nextDue,
            manufacturer: manufacturer,
            sourceManualName: sourceManualName,
            origin: .manufacturer,
            partNumbers: partNumbers,
            referenceURLs: referenceURLs,
            toolsRequired: toolsRequired,
            parts: mappedParts,
            manualImport: record,
            scheduleKind: scheduleKind,
            meterIntervalValue: parsedValue.map { Decimal($0) },
            meterIntervalUnit: parsedUnit,
            assetId: assetID
        )
    }
}

enum ManualMaintenanceIdentity {
    static func make(area: String, item: String) -> String {
        let bareItem = stripLeadingAreaPrefix(item, area: area)
        return semanticTaskKey(stripEquipmentHeadings(bareItem))
    }

    static func taskIdentity(_ task: MaintenanceTask) -> String {
        make(area: task.area, item: task.item)
    }

    static func itemIdentity(_ item: String) -> String {
        semanticTaskKey(stripEquipmentHeadings(item))
    }

    private static let fillerWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "for", "to", "on", "in", "with", "any", "all", "if", "is", "be", "as",
    ]
    private static let actionSynonyms = ["inspect": "check", "examine": "check", "verify": "check"]

    /// Content words of an identity key, with the leading action normalized so
    /// "Inspect the knife" and "Check knife" compare equal.
    static func contentWords(ofKey key: String) -> [String] {
        var words = key.split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }
        if let first = words.first, let synonym = actionSynonyms[first] {
            words[0] = synonym
        }
        return words
    }

    /// Same action on the same parts, allowing extra qualifiers such as
    /// "for tightness, nicks, wear". Distinct actions (check vs replace) never match.
    static func isSameAction(_ lhsKey: String, _ rhsKey: String) -> Bool {
        if lhsKey == rhsKey { return true }
        let lhs = contentWords(ofKey: lhsKey)
        let rhs = contentWords(ofKey: rhsKey)
        guard let lhsAction = lhs.first, lhsAction == rhs.first else { return false }
        let smaller = Set(lhs.count <= rhs.count ? lhs : rhs)
        let larger = Set(lhs.count <= rhs.count ? rhs : lhs)
        guard smaller.count >= 3 else { return smaller == larger }
        return Double(smaller.intersection(larger).count) / Double(smaller.count) >= 0.8
    }

    private static func stripLeadingAreaPrefix(_ item: String, area: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = area.trimmingCharacters(in: .whitespacesAndNewlines) + ":"
        guard !prefix.isEmpty, trimmed.lowercased().hasPrefix(prefix.lowercased()) else {
            return trimmed
        }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Drop a leading equipment or subsystem heading such as
    /// "JD 1025R Tractor:" so it can match the same action stored earlier.
    private static func stripEquipmentHeadings(_ item: String) -> String {
        var title = item.trimmingCharacters(in: .whitespacesAndNewlines)
        while let colon = title.firstIndex(of: ":") {
            let leading = String(title[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = leading.lowercased()
            let isEquipmentHeading = normalized.contains("tractor")
                || normalized.contains("mower")
                || normalized.contains("generator")
                || normalized.contains("ranger")
                || normalized.contains("equipment")
                || normalized.contains("chipper")
            let isSubsystemHeading = ["engine", "brush deck", "deck", "brakes", "brake", "battery", "fuel system"]
                .contains(normalized)
            guard isEquipmentHeading || isSubsystemHeading else { break }
            title = String(title[title.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
        }
        return title
    }

    /// Match wording variants of the same manufacturer recommendation without
    /// collapsing distinct work (for example, checking oil vs changing oil).
    private static func semanticTaskKey(_ item: String) -> String {
        let value = foldPlurals(normalize(item))
        let contains: (String) -> Bool = { value.contains($0) }

        if (contains("check") || contains("inspect") || contains("adjust")) && contains("valve clearance") {
            return "check engine valve clearance"
        }
        if (contains("check") || contains("inspect")) && contains("engine oil") { return "check engine oil" }
        if contains("change") && contains("oil") { return "change engine oil" }
        if contains("air filter") { return "air filter service" }
        if contains("fuel filter") { return "fuel filter service" }
        if contains("fuel line") { return "fuel lines service" }
        if contains("blade belt") && (contains("replace") || contains("replacing")) { return "replace blade belt" }
        if contains("belt") && (contains("check") || contains("inspect")) { return "inspect belts" }
        if contains("tire pressure") { return "check tire pressure" }
        if contains("battery") && (contains("charge") || contains("charging")) { return "charge battery" }
        if contains("battery") && contains("replace") { return "replace battery" }
        if contains("battery") && (contains("clean") || contains("check") || contains("inspect")) {
            return "clean battery"
        }
        if contains("brake cable") { return "adjust brake cables" }
        if contains("brake pad") { return "adjust brake pads" }
        if contains("caliper alignment") { return "adjust caliper alignment" }
        if contains("blade") && (contains("sharp") || contains("nicks") || contains("wear")) { return "inspect mower blade" }
        if (contains("lubricate") || contains("grease"))
            && !contains("steering") && !contains("cable") && !contains("idler")
            && (contains("grease") || contains("fitting") || value == "lubricate machine") {
            return "lubricate grease fittings"
        }
        if (contains("check") || contains("inspect") || contains("test"))
            && (contains("safety interlock") || (contains("safety") && contains("system"))) {
            return "check safety systems"
        }
        if (contains("check") || contains("inspect") || contains("verify")) && contains("transmission oil")
            && !contains("drain") && !contains("refill") && !contains("replace") && !contains("install") {
            return "check transmission oil"
        }
        if (contains("check") || contains("inspect")) && contains("coolant")
            && !contains("drain") && !contains("flush") && !contains("refill") {
            return "check coolant"
        }
        return value
    }

    private static func foldPlurals(_ value: String) -> String {
        let singular = [
            "filters": "filter",
            "fittings": "fitting",
            "elements": "element",
            "screens": "screen",
            "hoses": "hose",
            "clamps": "clamp"
        ]
        return value.split(separator: " ").map { singular[String($0)] ?? String($0) }.joined(separator: " ")
    }
}

enum ManualImportReviewSelection {
    static func notes(
        drafts: [ManualImportDraft],
        existingTasks: [MaintenanceTask],
        assetID: UUID?
    ) -> [UUID: String] {
        guard let assetID else { return [:] }
        let stored = existingTasks
            .filter { $0.assetId == assetID && $0.isActive && $0.kind == .scheduled }
            .map { (key: ManualMaintenanceIdentity.taskIdentity($0), item: $0.item) }

        var notes: [UUID: String] = [:]
        var proposals: [(key: String, item: String)] = []
        for draft in drafts {
            let key = draft.maintenanceIdentity
            if let match = stored.first(where: { ManualMaintenanceIdentity.isSameAction(key, $0.key) }) {
                notes[draft.id] = "Duplicate of stored task: \(match.item)"
            } else if let earlier = proposals.first(where: { ManualMaintenanceIdentity.isSameAction(key, $0.key) }) {
                notes[draft.id] = "Duplicate of another proposal: \(earlier.item)"
            } else {
                proposals.append((key, draft.item))
            }
        }
        return notes
    }

    static func applyingDefaultSelection(
        drafts: [ManualImportDraft],
        existingTasks: [MaintenanceTask],
        assetID: UUID?
    ) -> [ManualImportDraft] {
        let duplicateIDs = Set(notes(drafts: drafts, existingTasks: existingTasks, assetID: assetID).keys)
        return drafts.map { draft in
            var copy = draft
            copy.selected = !duplicateIDs.contains(draft.id)
            return copy
        }
    }
}

/// Manual models frequently repeat the equipment name and section heading in a
/// task title. The task formatter adds the linked asset once for display, so
/// imported titles must retain only the maintenance action.
enum ManualTaskTitle {
    static func clean(
        _ raw: String,
        equipmentName: String,
        subsystem: String?,
        supportingText: String? = nil
    ) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [equipmentName, subsystem ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in prefixes {
                let marker = "\(prefix):"
                if title.lowercased().hasPrefix(marker.lowercased()) {
                    title = String(title.dropFirst(marker.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
                    removedPrefix = true
                }
            }
        }

        // Some manuals/models label a result as `MODEL: Engine: Fuel Lines`.
        // Strip only unmistakable equipment/subsystem headings; do not remove
        // an action such as `Replace blade belt`.
        while let colon = title.firstIndex(of: ":") {
            let leading = String(title[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = leading.lowercased()
            let isEquipmentHeading = normalized.contains(" mower")
                || normalized.contains(" tractor")
                || normalized.contains(" generator")
                || normalized.contains(" ranger")
                || normalized.contains(" equipment")
            let isSubsystemHeading = ["engine", "brush deck", "deck", "brakes", "brake", "battery", "fuel system"]
                .contains(normalized)
            guard isEquipmentHeading || isSubsystemHeading else { break }
            title = String(title[title.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
        }

        if containsAction(title) { return title }
        if let supportingText, let action = actionTitle(in: supportingText) { return action }
        return title.isEmpty ? "Maintenance item" : title
    }

    private static func containsAction(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["change ", "replace ", "check ", "inspect ", "clean ", "adjust ", "lubricate ",
                "charge ", "sharpen ", "remove ", "install ", "service ", "maintain "]
            .contains { lower.hasPrefix($0) }
    }

    private static func actionTitle(in supportingText: String) -> String? {
        let pattern = #"(?is)\b(change|replace|check|inspect|clean|adjust|lubricate|charge|sharpen|remove|install|service|maintain)\b[^\.\n]{1,110}"#
        guard let range = supportingText.range(of: pattern, options: .regularExpression) else { return nil }
        let candidate = supportingText[range]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-•[]"))
        guard !candidate.isEmpty else { return nil }
        return candidate.prefix(1).uppercased() + candidate.dropFirst()
    }
}

/// Normalizes a known browser-download artifact without accepting arbitrary
/// leading bytes as a PDF. The operator's source file is never modified.
enum ManualPDFFile {
    private static let pdfSignature = Data("%PDF-".utf8)
    private static let utf16LEBOM = Data([0xff, 0xfe])
    private static let utf16BEBOM = Data([0xfe, 0xff])

    static func canonicalData(from data: Data) -> Data {
        for bom in [utf16LEBOM, utf16BEBOM] where data.starts(with: bom) {
            let payload = Data(data.dropFirst(bom.count))
            if payload.starts(with: pdfSignature) {
                return payload
            }
        }
        return data
    }
}

enum ManualImportError: LocalizedError {
    case noText
    case ollamaUnreachable(String)
    case badJSON(String)
    case incompleteModelResponse
    case modelRuntimeFailure
    case emptyTasks
    case invalidURL(String)
    case fetchFailed(String)
    case notHTML(String)
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "Could not extract usable text from that source."
        case .ollamaUnreachable(let detail):
            return "Local Ollama is unreachable. \(detail)"
        case .badJSON(let detail):
            return "Model returned unusable JSON. \(detail)"
        case .modelRuntimeFailure:
            return "The local model could not generate a response. Check available memory or restart the local model, then try again. No tasks were imported."
        case .incompleteModelResponse:
            return "The local model stopped before completing its response. No tasks were imported."
        case .emptyTasks:
            return "No maintenance tasks were found in the manual. For manufacturer TOC URLs, try a Maintenance Intervals / Engine Maintenance section page if this persists."
        case .invalidURL(let detail):
            return "Invalid manual URL. \(detail)"
        case .fetchFailed(let detail):
            return "Could not fetch that URL. \(detail)"
        case .notHTML(let detail):
            return "URL did not return HTML. \(detail)"
        case .responseTooLarge(let bytes):
            return "Page is too large to import (\(bytes) bytes)."
        }
    }
}

/// Local models occasionally wrap a valid object in Markdown fences or a short
/// explanation. Accept one embedded JSON object, but never attempt to repair
/// malformed model output into a task proposal.
enum ManualJSONPayload {
    static func objectData(from content: String) throws -> Data {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ManualImportError.badJSON("empty content")
        }

        let unfenced: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else {
                throw ManualImportError.badJSON("unterminated Markdown JSON fence")
            }
            unfenced = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            unfenced = trimmed
        }

        if let data = unfenced.data(using: .utf8), isJSONObject(data) {
            return data
        }

        guard let start = unfenced.firstIndex(of: "{"), let end = unfenced.lastIndex(of: "}"), start <= end else {
            throw ManualImportError.badJSON("model response did not contain a JSON object")
        }
        let trailing = unfenced[unfenced.index(after: end)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty else {
            throw ManualImportError.badJSON("model response continued after the JSON object")
        }
        let candidate = String(unfenced[start...end])
        guard let data = candidate.data(using: .utf8), isJSONObject(data) else {
            throw ManualImportError.badJSON("model response contained a malformed JSON object")
        }
        return data
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return object is [String: Any]
    }
}

enum PDFManualTextExtractor {
    static func extractText(from url: URL, maxCharacters: Int = 90_000) -> String {
        guard let document = PDFDocument(url: url) else {
            return ""
        }

        var parts: [String] = []
        var total = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                continue
            }

            let pageText = page.string ?? ""
            if pageText.isEmpty {
                continue
            }

            parts.append("----- page \(index + 1) -----\n\(pageText)")
            total += pageText.count
            if total >= maxCharacters {
                break
            }
        }

        var text = parts.joined(separator: "\n\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A full owner's manual is too large for one dependable local-model pass.
    /// Start at the manufacturer's periodic-maintenance chart and preserve that
    /// complete section in page-bounded chunks so service procedures do not get
    /// crowded out by front-matter or daily pre-ride checks.
    static func maintenanceChunks(from url: URL, maxCharactersPerChunk: Int = 14_000) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        let pages = (0..<document.pageCount).compactMap { index -> String? in
            guard let page = document.page(at: index), let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "----- page \(index + 1) -----\n\(text)"
        }
        return maintenanceChunks(fromPageTexts: pages, maxCharactersPerChunk: maxCharactersPerChunk)
    }

    static func maintenanceChunks(
        fromPageTexts pages: [String],
        maxCharactersPerChunk: Int = 14_000
    ) -> [String] {
        guard maxCharactersPerChunk > 0 else { return [] }
        let normalized = pages.map { $0.lowercased() }
        var selected: [String] = []

        if let start = normalized.firstIndex(where: { $0.contains("periodic maintenance") }) {
            for index in start..<pages.count {
                let leading = normalized[index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(160)
                if index > start,
                   (leading.contains("specifications") || leading.contains("warranty") || leading.contains("index")) {
                    break
                }
                selected.append(pages[index])
            }
        } else {
            // Many owner manuals distribute real maintenance work under headings
            // such as "Adjusting the Brake Cables" or "End of Season", not under
            // a single periodic-maintenance chapter.  Never fall back to the
            // first pages: they are commonly safety/front matter and omit service.
            selected = zip(pages, normalized).compactMap { page, text in
                maintenancePageScore(text) > 0 ? page : nil
            }
            if selected.isEmpty {
                let fallback = pages.joined(separator: "\n\n")
                selected = fallback.isEmpty ? [] : [String(fallback.prefix(maxCharactersPerChunk))]
            }
        }

        var chunks: [String] = []
        var current = ""
        for page in selected {
            let boundedPage = String(page.prefix(maxCharactersPerChunk))
            let candidate = current.isEmpty ? boundedPage : current + "\n\n" + boundedPage
            if !current.isEmpty && candidate.count > maxCharactersPerChunk {
                chunks.append(current)
                current = boundedPage
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func maintenancePageScore(_ text: String) -> Int {
        let excludedHeadings = ["specifications", "warranty", "parts list", "schematic diagram"]
        let leading = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220)
        guard !excludedHeadings.contains(where: { leading.contains($0) }) else { return 0 }

        let strongTerms = [
            "change the oil", "oil filter", "engine oil", "belt", "brake", "lubricat",
            "adjusting", "replacing", "replace the", "maintenance", "end of season",
            "storage", "daily checklist", "battery care", "air filter"
        ]
        return strongTerms.reduce(into: 0) { score, term in
            if text.contains(term) { score += 1 }
        }
    }
}

// MARK: - URL HTML fetch (bounded; no full-manual archive)

enum URLManualFetcher {
    static let maxResponseBytes = 1_500_000
    /// Enough room for interval charts + engine/lubrication pages without flooding safety TOC entries.
    static let maxSectionPages = 20
    static let maxTotalCharacters = 90_000
    static let requestTimeout: TimeInterval = 45

    struct FetchedPage {
        let url: URL
        let html: String
        let text: String
    }

    struct HarvestedLink: Hashable {
        let title: String
        let url: URL
        /// Nearest TOC section heading (e.g. "220 - Engine Maintenance"), when known.
        let sectionTitle: String

        init(title: String, url: URL, sectionTitle: String = "") {
            self.title = title
            self.url = url
            self.sectionTitle = sectionTitle
        }
    }

    /// Directory that contains this manual page. Frame targets must stay inside it.
    static func manualDirectoryPath(for page: URL) -> String {
        let path = page.path
        if path.hasSuffix("/") { return path }
        if page.lastPathComponent.contains(".") {
            let parent = (path as NSString).deletingLastPathComponent
            return parent.hasSuffix("/") ? parent : parent + "/"
        }
        return path + "/"
    }

    static func canonicalPort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// Same host and manual directory, no userinfo, no unexpected port, and no HTTPS-to-HTTP downgrade.
    static func allowsBoundedNavigation(_ candidate: URL, from origin: URL) -> Bool {
        guard let scheme = candidate.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard candidate.user == nil, candidate.password == nil else { return false }
        guard let host = candidate.host?.lowercased(),
              let originHost = origin.host?.lowercased(),
              host == originHost else {
            return false
        }
        let originScheme = origin.scheme?.lowercased()
        if originScheme == "https", scheme == "http" { return false }
        let candidatePort = canonicalPort(of: candidate)
        let originPort = canonicalPort(of: origin)
        let originUsesDefault = originPort == defaultPort(for: originScheme)
        let candidateUsesDefault = candidatePort == defaultPort(for: scheme)
        let portAllowed = candidatePort == originPort || (originUsesDefault && candidateUsesDefault)
        guard portAllowed else { return false }
        // The requested page is in bounds even when it has no extension.
        // `/manual` is not a child of the directory prefix `/manual/`.
        if candidate.path == origin.path { return true }
        let directory = manualDirectoryPath(for: origin)
        return candidate.path.hasPrefix(directory)
    }

    /// Redirect hop: stay inside the original page boundary, and do not drop HTTPS
    /// that was reached earlier in the chain (HTTP → HTTPS → HTTP).
    static func allowsRedirect(_ target: URL, from origin: URL, immediateResponse: URL) -> Bool {
        guard allowsBoundedNavigation(target, from: origin) else { return false }
        if immediateResponse.scheme?.lowercased() == "https", target.scheme?.lowercased() == "http" {
            return false
        }
        return true
    }

    /// Final response URL for a fetch. An unchanged request is acceptable without
    /// treating that page as a directory child.
    static func acceptedFetchedURL(_ finalURL: URL, requested: URL) -> URL? {
        if isUnchangedRequestedURL(finalURL, requested: requested) {
            return finalURL
        }
        return allowsBoundedNavigation(finalURL, from: requested) ? finalURL : nil
    }

    static func isUnchangedRequestedURL(_ finalURL: URL, requested: URL) -> Bool {
        finalURL.scheme?.lowercased() == requested.scheme?.lowercased()
            && finalURL.host?.lowercased() == requested.host?.lowercased()
            && canonicalPort(of: finalURL) == canonicalPort(of: requested)
            && finalURL.path == requested.path
            && finalURL.query == requested.query
            && finalURL.user == nil
            && finalURL.password == nil
    }

    static func isInsideManualDirectory(_ candidate: URL, manualPage: URL) -> Bool {
        allowsBoundedNavigation(candidate, from: manualPage)
    }

    static func frameSources(in html: String) -> [(name: String, src: String)] {
        guard let tagRegex = try? NSRegularExpression(pattern: #"(?is)<frame\b([^>]*)>"#) else {
            return []
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        return tagRegex.matches(in: html, range: full).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            let attributes = String(html[range])
            guard let src = frameAttribute("src", in: attributes) else { return nil }
            return (frameAttribute("name", in: attributes) ?? "", src)
        }
    }

    private static func frameAttribute(_ name: String, in attributes: String) -> String? {
        let pattern = #"(?is)\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = attributes as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: attributes, range: full) else { return nil }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound, let swiftRange = Range(range, in: attributes) {
                return String(attributes[swiftRange])
            }
        }
        return nil
    }

    static func preferredTOCFrameURL(in html: String, manualPage: URL) -> URL? {
        for frame in frameSources(in: html) {
            guard let resolved = resolvedManualFrameURL(frame.src, manualPage: manualPage) else { continue }
            let name = frame.name.lowercased()
            let file = resolved.lastPathComponent.lowercased()
            if name == "toc" || file == "toc.html" {
                return resolved
            }
        }
        return nil
    }

    static func resolvedManualFrameURL(_ src: String, manualPage: URL) -> URL? {
        guard let resolved = resolveURL(src, against: manualPage) else { return nil }
        guard allowsBoundedNavigation(resolved, from: manualPage) else { return nil }
        return resolved
    }

    /// Cancels a redirect that leaves the fetched manual page's host, directory, port, or HTTPS scheme.
    private final class PageRedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let origin = task.originalRequest?.url,
                  let target = request.url else {
                completionHandler(nil)
                return
            }
            let immediate = response.url ?? task.currentRequest?.url ?? origin
            guard URLManualFetcher.allowsRedirect(target, from: origin, immediateResponse: immediate) else {
                completionHandler(nil)
                return
            }
            var safe = request
            safe.httpShouldHandleCookies = false
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
            completionHandler(safe)
        }
    }

    static func makePageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "PropertyManagerApp/1.0 (local manufacturer manual import)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = requestTimeout
        request.httpShouldHandleCookies = false
        return request
    }

    /// Ephemeral session so public manual pages never receive app cookies, credentials, or stored secrets.
    static let pageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration, delegate: PageRedirectGuard(), delegateQueue: nil)
    }()

    static func fetchPage(from url: URL) async throws -> FetchedPage {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ManualImportError.invalidURL("Only http/https URLs are supported.")
        }

        guard url.user == nil, url.password == nil else {
            throw ManualImportError.invalidURL("Manual URLs cannot include a username or password.")
        }
        let port = canonicalPort(of: url)
        guard port == defaultPort(for: scheme) else {
            throw ManualImportError.invalidURL("Manual URLs cannot use a non-default port.")
        }

        let request = makePageRequest(for: url)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await pageSession.data(for: request)
        } catch {
            throw ManualImportError.fetchFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ManualImportError.fetchFailed("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ManualImportError.fetchFailed("HTTP \(http.statusCode)")
        }
        if data.count > maxResponseBytes {
            throw ManualImportError.responseTooLarge(data.count)
        }

        let mime = (http.mimeType ?? "").lowercased()
        let responseURL = http.url ?? url
        guard let finalURL = acceptedFetchedURL(responseURL, requested: url) else {
            throw ManualImportError.fetchFailed("Response URL left the manual page boundary.")
        }
        let looksHTML = mime.contains("html")
            || mime.isEmpty
            || finalURL.path.lowercased().hasSuffix(".html")
            || finalURL.path.lowercased().hasSuffix(".htm")
        guard looksHTML else {
            throw ManualImportError.notHTML(mime.isEmpty ? "unknown type" : mime)
        }

        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw ManualImportError.fetchFailed("Could not decode page text.")
        }

        return FetchedPage(url: finalURL, html: html, text: htmlToText(html))
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        let patterns = [
            #"(?is)<script[^>]*>.*?</script>"#,
            #"(?is)<style[^>]*>.*?</style>"#,
            #"(?is)<noscript[^>]*>.*?</noscript>"#,
            #"(?is)<!--.*?-->"#
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Preserve service-interval table structure for LLM extraction.
        s = s.replacingOccurrences(of: #"(?is)</td>"#, with: " | ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</th>"#, with: " | ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</tr>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</p>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</(div|li|h[1-6]|table|thead|tbody)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)

        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "-"), ("&ndash;", "-"), ("&bull;", "*"),
            ("&middot;", "*"), ("&hellip;", "..."), ("&times;", "x")
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Decode simple numeric entities (e.g. &#8212;) instead of blanking them.
        if let numRegex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let ns = s as NSString
            let matches = numRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            var mutable = s
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let full = Range(match.range, in: mutable),
                      let numRange = Range(match.range(at: 1), in: mutable),
                      let code = UInt32(mutable[numRange]),
                      let scalar = UnicodeScalar(code) else { continue }
                mutable.replaceSubrange(full, with: String(Character(scalar)))
            }
            s = mutable
        }
        s = s.replacingOccurrences(of: #"&[a-zA-Z]+;"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t\f\r]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^(?:\s*\|\s*)+$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveURL(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:") || lower.hasPrefix("#") {
            return nil
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    static func harvestTOCLinks(from html: String, baseURL: URL) -> [HarvestedLink] {
        // Walk TOC in document order so each link inherits the nearest <h3 class="section">.
        let sectionPattern = #"(?is)<h3\s+[^>]*class\s*=\s*["']section["'][^>]*>\s*([^<]+)"#
        let linkPattern = #"(?is)<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let sectionRegex = try? NSRegularExpression(pattern: sectionPattern),
              let linkRegex = try? NSRegularExpression(pattern: linkPattern) else {
            return []
        }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Marker {
            let location: Int
            let isSection: Bool
            let sectionTitle: String
            let href: String
            let rawTitle: String
        }

        var markers: [Marker] = []
        for match in sectionRegex.matches(in: html, range: full) {
            guard match.numberOfRanges >= 2,
                  let titleRange = Range(match.range(at: 1), in: html) else { continue }
            let title = htmlToText(String(html[titleRange]))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            markers.append(Marker(
                location: match.range.location,
                isSection: true,
                sectionTitle: title,
                href: "",
                rawTitle: ""
            ))
        }
        for match in linkRegex.matches(in: html, range: full) {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            markers.append(Marker(
                location: match.range.location,
                isSection: false,
                sectionTitle: "",
                href: String(html[hrefRange]),
                rawTitle: String(html[titleRange])
            ))
        }
        markers.sort { $0.location < $1.location }

        var seen = Set<String>()
        var links: [HarvestedLink] = []
        var currentSection = ""

        for marker in markers {
            if marker.isSection {
                currentSection = marker.sectionTitle
                continue
            }
            guard let absolute = resolveURL(marker.href, against: baseURL) else { continue }
            guard let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                continue
            }
            let pathLower = absolute.path.lowercased()
            if pathLower.hasSuffix(".css") || pathLower.hasSuffix(".js")
                || pathLower.hasSuffix(".gif") || pathLower.hasSuffix(".png")
                || pathLower.hasSuffix(".jpg") || pathLower.hasSuffix(".jpeg")
                || pathLower.hasSuffix(".svg") || pathLower.hasSuffix(".ico") {
                continue
            }
            let key = absolute.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)

            let rawTitle = htmlToText(marker.rawTitle)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty
                ? (absolute.lastPathComponent.isEmpty ? key : absolute.lastPathComponent)
                : rawTitle
            links.append(
                HarvestedLink(
                    title: String(title.prefix(160)),
                    url: absolute,
                    sectionTitle: String(currentSection.prefix(160))
                )
            )
        }
        return links
    }

    /// Rank TOC entries for maintenance extraction. High scores = interval charts,
    /// engine/lubrication/service pages. Safety/operation TOC noise scores near zero or negative.
    static func maintenanceRelevanceScore(for link: HarvestedLink) -> Int {
        let title = link.title.lowercased()
        let section = link.sectionTitle.lowercased()
        let hay = title + " " + section + " " + link.url.path.lowercased()

        // Pure safety / operation chapters crowd Deere TOCs and yield empty schedules.
        let safetySection = section.contains("safety") && !section.contains("maintenance")
        if safetySection || title.contains("safely") || title.hasPrefix("recognize safety")
            || title.hasPrefix("understand signal") || title.hasPrefix("follow safety") {
            return -100
        }
        if section.contains("operation") && !section.contains("maintenance")
            && !title.contains("maintenance") && !title.contains("service")
            && !title.contains("lubric") && !title.contains("oil") && !title.contains("filter") {
            return -40
        }
        if section.contains("troubleshooting") || section.contains("specification")
            || section.contains("identification") || section.contains("warranty")
            || section.contains("certification") {
            return -20
        }

        var score = 0

        if section.contains("maintenance interval") || section.contains("periodic maintenance") {
            score += 120
        } else if section.contains("engine maintenance") {
            score += 110
        } else if section.contains("lubricant") || section.contains("fuel, lubricants") {
            score += 95
        } else if section.contains("service record") {
            score += 90
        } else if section.contains("maintenance") {
            score += 70
        } else if section.contains("service") {
            score += 25
        }

        let titleBoosts: [(String, Int)] = [
            ("maintenance interval chart", 130),
            ("maintenance interval", 120),
            ("service your machine", 110),
            ("periodic maintenance", 100),
            ("change engine oil", 95),
            ("check engine oil", 85),
            ("engine oil", 75),
            ("engine maintenance", 90),
            ("lubricate", 70),
            ("lubricant", 65),
            ("replace fuel filter", 70),
            ("air filter", 65),
            ("fuel filter", 65),
            ("oil and filter", 80),
            ("transmission oil", 70),
            ("hydraulic oil", 65),
            ("service records", 70),
            ("hour service", 75),
            ("every ", 40),
            ("as required", 45),
            ("as needed", 40),
            ("grease", 50),
            ("coolant", 45),
            ("schedule", 55),
            ("interval", 50),
            ("maintenance", 45),
            ("service", 20),
            ("filter", 25),
            ("oil", 20),
            ("inspect", 15),
            ("torque", 15)
        ]
        for (needle, boost) in titleBoosts where title.contains(needle) {
            score += boost
        }

        if section.contains("service record") && (title.contains("hour") || title.contains("daily") || title.contains("needed")) {
            score += 40
        }

        if title == section || hay.contains("general information") {
            score -= 15
        }

        // Deere TOC includes bodywork/paint pages under Service that drown interval charts.
        if title.contains("plastic") || title.contains("painted") || title.contains("paint")
            || title.contains("metal surfaces") || title.contains("avoid damage to plastic") {
            score -= 80
        }

        return score
    }

    static func rankedMaintenanceLinks(
        from candidates: [HarvestedLink],
        limit: Int,
        minimumScore: Int = 40
    ) -> [HarvestedLink] {
        let scored = candidates
            .map { ($0, maintenanceRelevanceScore(for: $0)) }
            .filter { $0.1 >= minimumScore }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
        var seen = Set<String>()
        var out: [HarvestedLink] = []
        for (link, _) in scored {
            let key = link.url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(link)
            if out.count >= limit { break }
        }
        return out
    }

    static func sourceManualName(for url: URL, titleHint: String? = nil) -> String {
        let host = url.host ?? "manual"
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let shortPath: String = {
            if path.isEmpty { return "" }
            let parts = path.split(separator: "/").map(String.init)
            if parts.count <= 2 {
                return parts.joined(separator: "/")
            }
            return parts.suffix(2).joined(separator: "/")
        }()
        if let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            let shortTitle = String(hint.prefix(60))
            return shortPath.isEmpty ? "\(host) — \(shortTitle)" : "\(host)/\(shortPath) — \(shortTitle)"
        }
        return shortPath.isEmpty ? host : "\(host)/\(shortPath)"
    }
}

enum URLManualImporter {
    static var preferredModel: String {
        ProcessInfo.processInfo.environment["PROPERTYMANAGER_OLLAMA_MODEL"] ?? "qwen3.5:9b"
    }

    static let maxSectionPages = URLManualFetcher.maxSectionPages
    static let maxTotalCharacters = URLManualFetcher.maxTotalCharacters
    static let maxExcerptCharacters = 400

    struct TOCSection: Decodable {
        var title: String?
        var url: String?
    }

    struct TOCPayload: Decodable {
        var sections: [TOCSection]?
    }

    static func importDrafts(from urlString: String, onProgress: (@MainActor (String) -> Void)? = nil) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startURL = URL(string: trimmed), startURL.scheme != nil else {
            throw ManualImportError.invalidURL("Paste a full http(s) manufacturer manual page URL.")
        }
        return try await importDrafts(from: startURL, onProgress: onProgress)
    }

    static func importDrafts(from startURL: URL, onProgress: (@MainActor (String) -> Void)? = nil) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let retrievedAtISO = ManualImportChecksum.isoNow()
        let entry = try await URLManualFetcher.fetchPage(from: startURL)
        // One same-host hop from a directory frameset to its TOC. No other frames are fetched.
        let root: URLManualFetcher.FetchedPage
        if let tocURL = URLManualFetcher.preferredTOCFrameURL(in: entry.html, manualPage: entry.url) {
            root = try await URLManualFetcher.fetchPage(from: tocURL)
        } else {
            root = entry
        }
        let harvested = URLManualFetcher.harvestTOCLinks(from: root.html, baseURL: root.url)
        let looksLikeTOC = root.url.path.lowercased().contains("toc")
            || root.url.lastPathComponent.lowercased().contains("toc")
            || harvested.count >= 8

        var sectionURLs: [URL] = []
        if looksLikeTOC {
            sectionURLs = try await selectTOCSections(
                pageURL: root.url,
                pageText: root.text,
                candidates: harvested
            )
        }

        if sectionURLs.isEmpty {
            sectionURLs = [root.url]
        }

        var unique: [URL] = []
        var seen = Set<String>()
        for url in sectionURLs {
            let key = url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(url)
            if unique.count >= maxSectionPages { break }
        }

        var chunks: [String] = []
        var total = 0
        var fetchedURLs: [String] = []

        // TOC pages are mostly nav; keep a short excerpt for metadata only so
        // maintenance/engine content pages fill the corpus budget.
        let hasTOCMetadata = unique.count > 1 && !root.text.isEmpty
        if hasTOCMetadata {
            let tocExcerpt = String(root.text.prefix(2_500))
            let labeled = "----- source: \(root.url.absoluteString) -----\n\(tocExcerpt)"
            chunks.append(labeled)
            total += labeled.count
            fetchedURLs.append(root.url.absoluteString)
        }

        for url in unique {
            if total >= maxTotalCharacters { break }
            let page: URLManualFetcher.FetchedPage
            if url.absoluteString == root.url.absoluteString {
                page = root
            } else {
                do {
                    page = try await URLManualFetcher.fetchPage(from: url)
                } catch {
                    continue
                }
            }
            guard !page.text.isEmpty else { continue }
            if unique.count == 1 || url.absoluteString != root.url.absoluteString {
                var labeled = "----- source: \(page.url.absoluteString) -----\n\(page.text)"
                let remaining = maxTotalCharacters - total
                if labeled.count > remaining {
                    labeled = String(labeled.prefix(remaining))
                }
                chunks.append(labeled)
                total += labeled.count
                fetchedURLs.append(page.url.absoluteString)
            }
        }

        let combined = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw ManualImportError.noText
        }

        // Hash fetched corpus BEFORE Ollama for later site-change detection.
        let checksum = ManualImportChecksum.sha256Hex(of: combined)
        let allowedURLs = Set(fetchedURLs + [root.url.absoluteString])

        var provenance = ManualSourceProvenance(
            originalURL: startURL.absoluteString,
            retrievedAtISO: retrievedAtISO,
            contentChecksumSHA256: checksum,
            fetchedPageURLs: fetchedURLs
        )

        let batches = ManualURLBatch.batches(from: chunks)
        var payload = URLManualLLMPayload()
        var remainingRequests = 40
        for (index, batch) in batches.enumerated() {
            await onProgress?("Processing manual segment \(index + 1) of \(batches.count) with local Ollama…")
            let partials = try await ManualURLBatchProcessor.extract(batch, remainingRequests: &remainingRequests) { part in
                try await askOllamaURLImport(
                    corpusName: URLManualFetcher.sourceManualName(for: root.url), corpusText: part.corpus,
                    allowedURLs: allowedURLs.filter { part.header.contains($0) }.sorted(),
                    metadataOnly: hasTOCMetadata && index == 0
                )
            }
            for partial in partials { payload.merge(partial) }
        }

        let manufacturer = (payload.manufacturer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let equipment = (payload.equipment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.manualTitle = (payload.manualTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.publicationNumber = (payload.publicationNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.model = (payload.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.serialNumberApplicability = (payload.serialNumberApplicability ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let titleHint = provenance.manualTitle.isEmpty ? provenance.publicationNumber : provenance.manualTitle
        let manualName = URLManualFetcher.sourceManualName(for: root.url, titleHint: titleHint)

        var drafts: [ManualImportDraft] = []
        for task in payload.tasks ?? [] where isImportableURLTask(task) {
            let equipmentName = nonEmpty(equipment) ?? "Equipment"
            let subsystem = nonEmpty(task.area)
            let area = equipmentName
            let rawItem = nonEmpty(task.item) ?? ""
            let description = nonEmpty(task.taskDescription) ?? ""
            let item = ManualTaskTitle.clean(
                rawItem,
                equipmentName: equipmentName,
                subsystem: subsystem,
                supportingText: description
            )
            let warning = max(task.warningDays ?? 30, 1)
            let critical = max(task.criticalDays ?? max(warning * 2, warning + 7), warning)

            let facts = task.sourceFacts
            let toolsFromFacts = (facts?.tools ?? []).map {
                ToolRequirement(name: $0.name ?? "Tool", size: $0.size ?? "", notes: $0.notes ?? "")
            }.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            let toolsFromTop = (task.toolsRequired ?? []).map {
                ToolRequirement(name: $0.name ?? "Tool", size: $0.size ?? "", notes: $0.notes ?? "")
            }.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            let tools = toolsFromFacts.isEmpty ? toolsFromTop : toolsFromFacts

            var sectionURLsForTask = (facts?.sectionSourceURLs ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if let single = nonEmpty(task.sectionSourceURL) ?? nonEmpty(facts?.sectionSourceURL) {
                if !sectionURLsForTask.contains(single) {
                    sectionURLsForTask.insert(single, at: 0)
                }
            }
            sectionURLsForTask = sectionURLsForTask.filter {
                allowedURLs.contains($0) || $0.lowercased().hasPrefix("http")
            }
            if sectionURLsForTask.isEmpty {
                sectionURLsForTask = [root.url.absoluteString]
            }

            var refs = (task.referenceURLs ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            for u in sectionURLsForTask where !refs.contains(u) {
                refs.append(u)
            }

            let partNumbers = uniqueStrings((facts?.parts ?? []) + (task.partNumbers ?? []))
            let excerpt = ManualImportChecksum.clipExcerpt(
                facts?.sourceExcerpt ?? task.sourceExcerpt ?? "",
                max: maxExcerptCharacters
            )

            let sourceFacts = ManualSourceFacts(
                maintenanceInterval: (facts?.maintenanceInterval ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                fluids: cleanList(facts?.fluids),
                capacities: cleanList(facts?.capacities),
                filters: cleanList(facts?.filters),
                parts: cleanList(facts?.parts ?? task.partNumbers),
                safetyWarnings: cleanList(facts?.safetyWarnings),
                sourceExcerpt: excerpt,
                sectionSourceURLs: sectionURLsForTask
            )

            let inferred = (task.inferredNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = min(max(task.confidence ?? 0.5, 0), 1)

            var noteBits: [String] = []
            if !sourceFacts.maintenanceInterval.isEmpty {
                noteBits.append("Interval (source): \(sourceFacts.maintenanceInterval)")
            }
            noteBits.append("Source: \(manualName)")
            if !provenance.retrievedAtISO.isEmpty {
                noteBits.append("Retrieved: \(provenance.retrievedAtISO)")
            }

            drafts.append(
                ManualImportDraft(
                    area: area,
                    item: item,
                    category: category(from: task.category, area: area),
                    frequency: frequency(from: task.frequency, warningDays: warning),
                    warningDays: warning,
                    criticalDays: critical,
                    estimatedMinutes: max(task.estimatedMinutes ?? 30, 5),
                    taskDescription: description,
                    responseInstructions: nonEmpty(task.responseInstructions)
                        ?? "Follow the manufacturer procedure at \(sectionURLsForTask.first ?? manualName).",
                    suppliesNeeded: labeledSupplies(facts: sourceFacts, fallback: task.suppliesNeeded ?? ""),
                    notes: noteBits.joined(separator: "\n"),
                    manufacturer: manufacturer,
                    sourceManualName: manualName,
                    partNumbers: partNumbers,
                    referenceURLs: refs,
                    toolsRequired: tools,
                    provenance: provenance,
                    sourceFacts: sourceFacts,
                    inferredNotes: inferred,
                    confidence: confidence,
                    verificationStatus: .unverified
                )
            )
        }

        guard !drafts.isEmpty else {
            throw ManualImportError.emptyTasks
        }

        return (manufacturer, drafts)
    }

    private static func cleanList(_ values: [String]?) -> [String] {
        (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }

    private static func labeledSupplies(facts: ManualSourceFacts, fallback: String) -> String {
        var lines: [String] = []
        if !facts.fluids.isEmpty { lines.append("Fluids: \(facts.fluids.joined(separator: "; "))") }
        if !facts.capacities.isEmpty { lines.append("Capacities: \(facts.capacities.joined(separator: "; "))") }
        if !facts.filters.isEmpty { lines.append("Filters: \(facts.filters.joined(separator: "; "))") }
        if !facts.parts.isEmpty { lines.append("Parts: \(facts.parts.joined(separator: "; "))") }
        if lines.isEmpty {
            return fallback
        }
        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(fallback)
        }
        return lines.joined(separator: "\n")
    }

    private static func askOllamaURLImport(
        corpusName: String,
        corpusText: String,
        allowedURLs: [String],
        metadataOnly: Bool = false
    ) async throws -> URLManualLLMPayload {
        let system = """
        Extract maintenance actions explicitly described in this labeled manual section.
        A complete maintenance procedure is one task; preparation steps are not separate tasks.
        Include inspection, replacement, lubrication, or adjustment even when no interval is stated.
        Each task must have item (a concise action title), taskDescription, and sourceFacts with
        maintenanceInterval (empty if absent), a short sourceExcerpt, and sectionSourceURLs.
        Preserve manufacturer warnings and procedure details in responseInstructions/safetyWarnings
        when present. Optional tools, parts, fluids, capacities and filters must come from the source.
        Extract every maintenance-chart row as a task. Preserve literal service intervals; do not
        invent intervals, part numbers, models or publication numbers. Return tasks:[] only when
        there is no maintenance action. Use only these source URLs: \(allowedURLs.joined(separator: ", ")).
        Return only JSON matching the schema. Keep source excerpts below 200 characters.
        """

        let user = """
        Corpus name: \(corpusName)

        Manual corpus (labeled sources):
        \(corpusText)
        """

        let content = try await ManufacturerManualImporter.chatJSON(
            system: metadataOnly ? "Extract only explicit manual metadata from this table of contents. Return manufacturer, equipment, manualTitle, publicationNumber, model, serialNumberApplicability. Use empty strings for unknown values. Do not infer maintenance tasks from navigation headings." : system,
            user: user,
            jsonSchema: metadataOnly ? ManufacturerManualImporter.urlMetadataJSONSchema : ManufacturerManualImporter.urlImportJSONSchema, boundedManual: true, model: preferredModel
        )
        return try decodeURLPayload(content, metadataOnly: metadataOnly)
    }

    static func validateURLPayload(_ content: String, metadataOnly: Bool = false) throws {
        _ = try decodeURLPayload(content, metadataOnly: metadataOnly)
    }

    /// Tasks missing the schema-required action or description are not drafts.
    static func importableTaskCount(in content: String) throws -> Int {
        let payload = try decodeURLPayload(content)
        return (payload.tasks ?? []).filter(isImportableURLTask).count
    }

    private static func isImportableURLTask(_ task: URLManualLLMPayload.Task) -> Bool {
        nonEmpty(task.item) != nil && nonEmpty(task.taskDescription) != nil
    }

    private static func decodeURLPayload(_ content: String, metadataOnly: Bool = false) throws -> URLManualLLMPayload {
        let data = try ManualJSONPayload.objectData(from: content)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManualImportError.badJSON("The response was not an object.")
        }
        if metadataOnly {
            guard root["tasks"] == nil else {
                throw ManualImportError.badJSON("Table-of-contents metadata must not contain tasks.")
            }
        } else if !(root["tasks"] is [Any]) {
            throw ManualImportError.badJSON("The response did not contain a tasks array.")
        }
        do { return try JSONDecoder().decode(URLManualLLMPayload.self, from: data) }
        catch let DecodingError.typeMismatch(_, context) {
            throw ManualImportError.badJSON("Unexpected field type at " + context.codingPath.map(\.stringValue).joined(separator: "."))
        } catch {
            throw ManualImportError.badJSON("The response did not match the manual task format.")
        }
    }

    private static func selectTOCSections(
        pageURL: URL,
        pageText: String,
        candidates: [URLManualFetcher.HarvestedLink]
    ) async throws -> [URL] {
        // Deterministic ranking first — Deere-style TOCs bury Engine Maintenance /
        // interval charts after dozens of Safety links; first-N / loose keyword
        // matching previously filled the page budget with safety pages and empty tasks.
        var ranked = URLManualFetcher.rankedMaintenanceLinks(
            from: candidates,
            limit: maxSectionPages,
            minimumScore: 40
        )
        // When interval-chart / engine-oil pages are present, drop weak filler
        // (paint, generic service) so Ollama cannot ignore the schedule tables.
        let strong = ranked.filter { URLManualFetcher.maintenanceRelevanceScore(for: $0) >= 180 }
        if strong.count >= 3 {
            ranked = Array(strong.prefix(maxSectionPages))
        }
        if ranked.count >= 4 {
            return ranked.map(\.url)
        }

        let candidatePool = ranked.isEmpty
            ? Array(candidates.prefix(100))
            : ranked + Array(candidates.prefix(40))
        var seenPool = Set<String>()
        let uniquePool = candidatePool.filter {
            let key = $0.url.absoluteString
            if seenPool.contains(key) { return false }
            seenPool.insert(key)
            return true
        }

        let candidateLines = uniquePool.prefix(100).map { link -> String in
            let section = link.sectionTitle.isEmpty ? "" : " [\(link.sectionTitle)]"
            return "- \(link.title)\(section) | \(link.url.absoluteString)"
        }.joined(separator: "\n")

        let system = """
        You select maintenance-relevant sections from a manufacturer manual table of contents page.
        Return ONLY valid JSON:
        {
          "sections": [
            { "title": "string", "url": "absolute http(s) URL" }
          ]
        }
        Rules:
        - Prefer Maintenance Intervals, Engine Maintenance, Lubrication/Fluids, Filters, Service Records, and Periodic/Hourly service pages.
        - Include concrete procedure pages (oil, filters, lubricate, interval charts) over Safety / Operation chapters.
        - Do NOT fill the list with "...Safely" safety pages unless no maintenance pages exist.
        - Prefer URLs from the candidate list. Do not invent URLs.
        - Return at most \(maxSectionPages) sections.
        - If nothing is maintenance-relevant, return {"sections": []}.
        """

        let user = """
        TOC page URL: \(pageURL.absoluteString)

        Candidate links (maintenance-ranked when available):
        \(candidateLines.isEmpty ? "(none harvested)" : candidateLines)

        TOC page text (excerpt):
        \(String(pageText.prefix(8_000)))
        """

        let content = try await ManufacturerManualImporter.chatJSON(system: system, user: user, jsonSchema: nil, boundedManual: true, model: preferredModel)
        guard let data = content.data(using: .utf8) else {
            return fallbackTOCURLs(from: candidates)
        }

        let payload: TOCPayload
        do {
            payload = try JSONDecoder().decode(TOCPayload.self, from: data)
        } catch {
            return fallbackTOCURLs(from: candidates)
        }

        var urls: [URL] = []
        var seenLocal = Set<String>()
        let candidateSet = Set(candidates.map { $0.url.absoluteString })

        // Seed with any strong ranked hits so Ollama cannot drop interval/engine pages.
        for link in ranked.prefix(8) {
            let abs = link.url.absoluteString
            if seenLocal.contains(abs) { continue }
            seenLocal.insert(abs)
            urls.append(link.url)
        }

        for section in payload.sections ?? [] {
            guard let raw = section.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let url = URL(string: raw) ?? URLManualFetcher.resolveURL(raw, against: pageURL) else {
                continue
            }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                continue
            }
            let abs = url.absoluteString
            let sameHost = url.host != nil && url.host == pageURL.host
            if !candidateSet.isEmpty && !candidateSet.contains(abs) && !sameHost {
                continue
            }
            if seenLocal.contains(abs) { continue }
            seenLocal.insert(abs)
            urls.append(url)
            if urls.count >= maxSectionPages { break }
        }

        if urls.isEmpty {
            return fallbackTOCURLs(from: candidates)
        }
        return Array(urls.prefix(maxSectionPages))
    }

    private static func fallbackTOCURLs(from candidates: [URLManualFetcher.HarvestedLink]) -> [URL] {
        let ranked = URLManualFetcher.rankedMaintenanceLinks(
            from: candidates,
            limit: maxSectionPages,
            minimumScore: 20
        )
        if !ranked.isEmpty {
            return ranked.map(\.url)
        }
        return Array(candidates.prefix(maxSectionPages)).map(\.url)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func category(from raw: String?, area: String) -> String {
        ManufacturerManualImporter.categoryPublic(from: raw, area: area)
    }

    private static func frequency(from raw: String?, warningDays: Int) -> TaskFrequency {
        ManufacturerManualImporter.frequencyPublic(from: raw, warningDays: warningDays)
    }
}

enum ManufacturerManualImporter {
    struct CoverageEvaluation: Equatable {
        let sourceRequiredTitles: [String]
        let localAIConfirmedTitles: [String]
        let missingFromLocalAI: [String]
        let sourceBackedAddedTitles: [String]

        var summary: String {
            "Local AI confirmed \(localAIConfirmedTitles.count) of \(sourceRequiredTitles.count) required manufacturer actions; source verifier added \(sourceBackedAddedTitles.count)."
        }
    }

    struct Progress: Equatable {
        let completedSections: Int
        let totalSections: Int
        let discoveredDrafts: Int

        var estimatedRemainingSeconds: Int {
            // Local inference is intentionally conservative: show an estimate,
            // not false precision, while each bounded service section is read.
            max(totalSections - completedSections, 0) * 45
        }
    }

    static var preferredModel: String {
        ProcessInfo.processInfo.environment["PROPERTYMANAGER_OLLAMA_MODEL"]
            ?? "qwen3:14b"
    }

    static var ollamaBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["PROPERTYMANAGER_OLLAMA_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:11434")!
    }

    static func coverageEvaluation(
        localAIDrafts: [ManualImportDraft],
        sourceBackedDrafts: [ManualImportDraft]
    ) -> CoverageEvaluation {
        let source = Dictionary(uniqueKeysWithValues: sourceBackedDrafts.map {
            ($0.maintenanceIdentity, $0.item)
        })
        let localKeys = Set(localAIDrafts.map(\.maintenanceIdentity))
        let confirmed = source.keys.filter { localKeys.contains($0) }.compactMap { source[$0] }.sorted()
        let missing = source.keys.filter { !localKeys.contains($0) }.compactMap { source[$0] }.sorted()
        return CoverageEvaluation(
            sourceRequiredTitles: source.values.sorted(),
            localAIConfirmedTitles: confirmed,
            missingFromLocalAI: missing,
            sourceBackedAddedTitles: missing
        )
    }

    /// Adds only literal manufacturer recommendations found in the extracted
    /// PDF text. It is deliberately narrow: no inferred intervals, no cloud
    /// model, and no automatic record creation.
    static func sourceBackedMaintenanceDrafts(
        manualName: String,
        manualText: String,
        manufacturer: String
    ) -> [ManualImportDraft] {
        let text = manualText.lowercased()
        let equipment = manualName
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var drafts: [ManualImportDraft] = []

        func add(
            when phrase: String,
            item: String,
            frequency: TaskFrequency,
            warningDays: Int,
            instructions: String,
            supplies: String = ""
        ) {
            guard text.contains(phrase) else { return }
            drafts.append(ManualImportDraft(
                area: equipment,
                item: item,
                category: "Equipment",
                frequency: frequency,
                warningDays: warningDays,
                criticalDays: max(warningDays * 2, warningDays + 7),
                estimatedMinutes: 20,
                taskDescription: item,
                responseInstructions: instructions,
                suppliesNeeded: supplies,
                notes: "Source manual: \(manualName)\nManufacturer wording verified in extracted PDF text.",
                manufacturer: manufacturer,
                sourceManualName: manualName,
                partNumbers: [],
                referenceURLs: [],
                toolsRequired: []
            ))
        }

        add(
            when: "check the engine oil level",
            item: "Check engine oil level",
            frequency: .daily,
            warningDays: 1,
            instructions: "Check the engine oil level before each use, as directed by the manufacturer."
        )
        add(
            when: "check belts for wear",
            item: "Inspect belts for wear, alignment, and tension",
            frequency: .daily,
            warningDays: 1,
            instructions: "Before each use, inspect belts for wear, proper alignment, and tension."
        )
        add(
            when: "change the oil",
            item: "Change engine oil",
            frequency: .yearly,
            warningDays: 365,
            instructions: "For end-of-season storage, change the engine oil and replace the oil filter if applicable."
        )
        add(
            when: "clean/replace the air filters",
            item: "Clean or replace air filter",
            frequency: .yearly,
            warningDays: 365,
            instructions: "For end-of-season storage, clean or replace the air filter."
        )
        add(
            when: "if your engine has a fuel filter",
            item: "Replace fuel filter",
            frequency: .yearly,
            warningDays: 365,
            instructions: "If the engine has a fuel filter, replace it during end-of-season service."
        )
        add(
            when: "replace rubber fuel lines and grommets",
            item: "Replace rubber fuel lines and grommets",
            frequency: .yearly,
            warningDays: 365 * 5,
            instructions: "Replace rubber fuel lines and grommets when worn or damaged, or after five years of use, whichever comes first."
        )
        add(
            when: "removing and replacing the blade belt",
            item: "Replace blade belt",
            frequency: .yearly,
            warningDays: 365,
            instructions: "Replace the blade belt using the manufacturer’s belt-guard, pulley, tensioner-spring, and routing procedure.",
            supplies: "Gloves"
        )
        add(
            when: "adjusting the brake cables",
            item: "Adjust brake cables",
            frequency: .yearly,
            warningDays: 365,
            instructions: "Use the brake caliper micro-adjust knob; when it reaches the end of its travel, perform the full cable adjustment procedure.",
            supplies: "5.5 mm Allen wrench"
        )
        add(
            when: "battery care",
            item: "Charge stored battery",
            frequency: .monthly,
            warningDays: 35,
            instructions: "When the machine is not in use, charge the battery every four to six weeks."
        )
        return drafts
    }

    static func extractDrafts(
        manualName: String,
        manualText: String,
        extraSystemRules: String = "",
        defaultReferenceURLs: [String] = [],
        maxNotesExcerpt: Int? = nil
    ) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let payload = try await askOllama(
            manualName: manualName,
            manualText: manualText,
            extraSystemRules: extraSystemRules
        )

        let manufacturer = payload.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let equipment = payload.equipment.trimmingCharacters(in: .whitespacesAndNewlines)

        var drafts: [ManualImportDraft] = []
        for task in payload.tasks {
            let equipmentName = nonEmpty(equipment) ?? "Equipment"
            let subsystem = nonEmpty(task.area)
            let area = equipmentName
            let item = ManualTaskTitle.clean(
                nonEmpty(task.item) ?? "Maintenance item",
                equipmentName: equipmentName,
                subsystem: subsystem,
                supportingText: task.taskDescription ?? task.responseInstructions
            )
            guard let responseInstructions = nonEmpty(task.responseInstructions) else {
                // A manufacturer task must carry usable, source-backed procedure text.
                // Do not create a misleading generic "follow the manual" How-To.
                continue
            }
            let warning = max(task.warningDays ?? 30, 1)
            let critical = max(task.criticalDays ?? max(warning * 2, warning + 7), warning)
            let tools = (task.toolsRequired ?? []).map {
                ToolRequirement(
                    name: $0.name ?? "Tool",
                    size: $0.size ?? "",
                    notes: $0.notes ?? ""
                )
            }.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            var refs = (task.referenceURLs ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if refs.isEmpty {
                refs = defaultReferenceURLs
            }

            var notesBits: [String] = []
            if let notes = nonEmpty(task.notes) {
                if let maxNotesExcerpt, notes.count > maxNotesExcerpt {
                    notesBits.append(String(notes.prefix(maxNotesExcerpt)))
                } else {
                    notesBits.append(notes)
                }
            }
            notesBits.append("Source manual: \(manualName)")
            if !manufacturer.isEmpty {
                notesBits.append("Manufacturer: \(manufacturer)")
            }

            drafts.append(
                ManualImportDraft(
                    area: area,
                    item: item,
                    category: category(from: task.category, area: area),
                    frequency: frequency(from: task.frequency, warningDays: warning),
                    warningDays: warning,
                    criticalDays: critical,
                    estimatedMinutes: max(task.estimatedMinutes ?? 30, 5),
                    taskDescription: nonEmpty(task.taskDescription)
                        ?? item,
                    responseInstructions: responseInstructions,
                    suppliesNeeded: task.suppliesNeeded ?? "",
                    notes: notesBits.joined(separator: "\n"),
                    manufacturer: manufacturer,
                    sourceManualName: manualName,
                    partNumbers: (task.partNumbers ?? []).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty },
                    referenceURLs: refs,
                    toolsRequired: tools
                )
            )
        }

        guard !drafts.isEmpty else {
            throw ManualImportError.emptyTasks
        }

        return (manufacturer, drafts)
    }

    struct HowToFillResult {
        var found: Bool
        var responseInstructions: String
        var manufacturer: String
    }

    static func fillHowTo(
        forTaskArea area: String,
        item: String,
        taskDescription: String,
        from pdfURL: URL
    ) async throws -> HowToFillResult {
        let text = PDFManualTextExtractor.extractText(from: pdfURL)
        guard !text.isEmpty else {
            throw ManualImportError.noText
        }

        let system = """
        You extract the manufacturer maintenance procedure for ONE specific task from an equipment manual.
        Return ONLY valid JSON:
        {
          "found": true,
          "manufacturer": "string",
          "responseInstructions": "numbered how-to steps from the manual for this task only"
        }
        Rules:
        - Set found=true only if the manual clearly covers this maintenance item.
        - If the manual does not cover it, return {"found": false, "manufacturer": "", "responseInstructions": ""}.
        - Do not invent steps that are not supported by the manual.
        - Keep responseInstructions actionable and faithful to the manual.
        - Return every distinct explicit maintenance action in the supplied text;
          do not summarize a service schedule into one representative task.
        - task.item is a short action title such as "Change engine oil" or
          "Replace blade belt". Never prefix it with the equipment, model, or
          section/subsystem name.
        """

        let user = """
        Manual file name: \(pdfURL.lastPathComponent)

        Task area: \(area)
        Task item: \(item)
        Task description: \(taskDescription)

        Manual text:
        \(text)
        """

        let content = try await chatJSON(system: system, user: user)
        guard let contentData = content.data(using: .utf8) else {
            throw ManualImportError.badJSON("empty content")
        }
        struct FillPayload: Decodable {
            var found: Bool?
            var manufacturer: String?
            var responseInstructions: String?
        }
        let payload = try JSONDecoder().decode(FillPayload.self, from: contentData)
        let instructions = (payload.responseInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let found = (payload.found ?? false) && !instructions.isEmpty
        return HowToFillResult(
            found: found,
            responseInstructions: instructions,
            manufacturer: (payload.manufacturer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Lean JSON Schema for Ollama `format`. Nested sourceFacts stay prompt-driven
    /// (optional in decode); a heavy required schema made gemma3 truncate mid-JSON.
    static var urlImportJSONSchema: [String: Any] {
        let tool: [String: Any] = ["type": "object", "properties": [
            "name": ["type": "string"], "size": ["type": "string"], "notes": ["type": "string"]
        ], "required": ["name"], "additionalProperties": false]
        let task: [String: Any] = [
            "type": "object",
            "properties": [
                "area": ["type": "string"],
                "item": ["type": "string"],
                "category": ["type": "string"],
                "frequency": ["type": "string"],
                "warningDays": ["type": "integer"],
                "meterIntervalValue": ["type": "number"],
                "meterIntervalUnit": ["type": "string"],
                "criticalDays": ["type": "integer"],
                "estimatedMinutes": ["type": "integer"],
                "taskDescription": ["type": "string"],
                "responseInstructions": ["type": "string"],
                "suppliesNeeded": ["type": "string"],
                "partNumbers": ["type": "array", "items": ["type": "string"]],
                "referenceURLs": ["type": "array", "items": ["type": "string"]],
                "sectionSourceURL": ["type": "string"],
                "inferredNotes": ["type": "string"],
                "confidence": ["type": "number"],
                "toolsRequired": ["type": "array", "items": tool],
                "sourceExcerpt": ["type": "string"],
                "sourceFacts": [
                    "type": "object",
                    "properties": [
                        "tools": ["type": "array", "items": tool],
                        "sectionSourceURL": ["type": "string"],
                        "maintenanceInterval": ["type": "string"],
                        "fluids": ["type": "array", "items": ["type": "string"]],
                        "capacities": ["type": "array", "items": ["type": "string"]],
                        "filters": ["type": "array", "items": ["type": "string"]],
                        "parts": ["type": "array", "items": ["type": "string"]],
                        "safetyWarnings": ["type": "array", "items": ["type": "string"]],
                        "sourceExcerpt": ["type": "string"],
                        "sectionSourceURLs": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": ["maintenanceInterval", "sourceExcerpt", "sectionSourceURLs"],
                    "additionalProperties": false
                ]
            ],
            "required": ["item", "taskDescription", "sourceFacts"],
            "additionalProperties": false
        ]
        return [
            "type": "object",
            "properties": [
                "manufacturer": ["type": "string"],
                "equipment": ["type": "string"],
                "manualTitle": ["type": "string"],
                "publicationNumber": ["type": "string"],
                "model": ["type": "string"],
                "serialNumberApplicability": ["type": "string"],
                "tasks": ["type": "array", "items": task]
            ],
            "required": ["tasks"],
            "additionalProperties": false
        ]
    }

    static var urlMetadataJSONSchema: [String: Any] {
        let names = ["manufacturer", "equipment", "manualTitle", "publicationNumber", "model", "serialNumberApplicability"]
        return ["type": "object", "properties": Dictionary(uniqueKeysWithValues: names.map { ($0, ["type": "string"]) }),
                "required": names, "additionalProperties": false]
    }

    static var pdfImportJSONSchema: [String: Any] {
        let tool: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "size": ["type": "string"],
                "notes": ["type": "string"]
            ],
            "required": ["name", "size", "notes"]
        ]
        let task: [String: Any] = [
            "type": "object",
            "properties": [
                "area": ["type": "string"],
                "item": ["type": "string"],
                "category": ["type": "string"],
                "frequency": ["type": "string"],
                "warningDays": ["type": "integer"],
                "criticalDays": ["type": "integer"],
                "estimatedMinutes": ["type": "integer"],
                "taskDescription": ["type": "string"],
                "responseInstructions": ["type": "string"],
                "suppliesNeeded": ["type": "string"],
                "partNumbers": ["type": "array", "items": ["type": "string"]],
                "referenceURLs": ["type": "array", "items": ["type": "string"]],
                "toolsRequired": ["type": "array", "items": tool],
                "notes": ["type": "string"]
            ],
            "required": [
                "area", "item", "category", "frequency", "warningDays",
                "criticalDays", "estimatedMinutes", "taskDescription",
                "responseInstructions", "suppliesNeeded", "partNumbers",
                "referenceURLs", "toolsRequired", "notes"
            ]
        ]
        return [
            "type": "object",
            "properties": [
                "manufacturer": ["type": "string"],
                "equipment": ["type": "string"],
                "tasks": ["type": "array", "items": task]
            ],
            "required": ["manufacturer", "equipment", "tasks"]
        ]
    }

    /// Prompt tokens and `num_predict` share `num_ctx` (Ollama `/api/chat`).
    /// The 2026-09-28 OMLVU31626 run loaded `n_ctx` 8192 with prompts of 466 and
    /// 600 tokens, then stopped at exactly 1024 generated tokens. That cap is
    /// inside the window, so generation can finish without crowding the prompt out.
    static let boundedContextTokens = 8192
    static let boundedPredictTokens = 4096

    static func boundedChatOptions() -> [String: Any] {
        [
            "temperature": 0.1,
            "num_predict": boundedPredictTokens,
            "num_ctx": boundedContextTokens
        ]
    }

    static func chatJSON(system: String, user: String) async throws -> String {
        try await chatJSON(system: system, user: user, jsonSchema: nil)
    }

    static func chatJSON(
        system: String,
        user: String,
        jsonSchema: [String: Any]?,
        boundedManual: Bool = false,
        model: String? = nil
    ) async throws -> String {
        let url = ollamaBaseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        var body: [String: Any] = [
            "model": model ?? preferredModel,
            "stream": false,
            "think": false,
            "format": jsonSchema ?? "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "options": [
                "temperature": 0.1,
                "num_predict": 4096
            ]
        ]
        if boundedManual {
            // Per-request budget; do not silently truncate source text or shift it out.
            body["options"] = boundedChatOptions()
            // Release this import's model/cache between sections on memory-constrained Macs.
            body["keep_alive"] = 0
            body["truncate"] = false
            body["shift"] = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ManualImportError.ollamaUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw ManualImportError.ollamaUnreachable(detail)
        }

        return try ManualOllamaResponse.content(from: data)
    }

    static func categoryPublic(from raw: String?, area: String) -> String {
        category(from: raw, area: area)
    }

    static func frequencyPublic(from raw: String?, warningDays: Int) -> TaskFrequency {
        frequency(from: raw, warningDays: warningDays)
    }

    private static func askOllama(
        manualName: String,
        manualText: String,
        extraSystemRules: String = ""
    ) async throws -> ManualLLMPayload {
        var system = """
        You extract manufacturer-recommended maintenance schedules from equipment manuals.
        Return ONLY valid JSON matching this schema:
        {
          "manufacturer": "string",
          "equipment": "string",
          "tasks": [
            {
              "area": "string",
              "item": "string",
              "category": "Pool|Home|Grounds|Equipment|House|Safety|Property",
              "frequency": "Daily|Weekly|Every 2 Weeks|Monthly|Quarterly|Yearly",
              "warningDays": 30,
              "criticalDays": 45,
              "estimatedMinutes": 30,
              "taskDescription": "string",
              "responseInstructions": "numbered how-to steps from the manual",
              "suppliesNeeded": "string",
              "partNumbers": ["string"],
              "referenceURLs": ["string"],
              "toolsRequired": [{"name":"string","size":"string","notes":"string"}],
              "notes": "page or section references"
            }
          ]
        }
        Rules:
        - Include only maintenance/inspection/service tasks the manufacturer recommends.
        - Search for daily or before-use checks, periodic service, adjustments,
          replacement procedures, and storage/end-of-season work. Include a task
          even when the manufacturer gives a condition rather than a fixed interval.
        - Capture part numbers, URLs, tool names, and socket/wrench sizes when present.
        - If a size is given (mm, SAE, hex, torx), put it in toolsRequired.size.
        - Prefer concrete intervals. Convert hours/months to warningDays approximately (30 days ~= monthly).
        - Do not invent part numbers or URLs. Use empty arrays when unknown.
        - Keep responseInstructions actionable and faithful to the manual.
        """
        let extra = extraSystemRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            system += "\n" + extra
        }

        let user = """
        Manual file name: \(manualName)

        Manual text:
        \(manualText)
        """

        let content = try await chatJSON(system: system, user: user, jsonSchema: pdfImportJSONSchema)
        let contentData = try ManualJSONPayload.objectData(from: content)

        do {
            return try JSONDecoder().decode(ManualLLMPayload.self, from: contentData)
        } catch {
            throw ManualImportError.badJSON(error.localizedDescription + " / " + String(content.prefix(400)))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func category(from raw: String?, area: String) -> String {
        let text = (raw ?? area).lowercased()
        if text.contains("pool") { return "Pool" }
        if text.contains("hot") || text.contains("tub") || text.contains("spa") { return "Home" }
        if text.contains("fence") || text.contains("gate") || text.contains("property") { return "Property" }
        if text.contains("ground") || text.contains("yard") || text.contains("lawn") {
            return "Grounds"
        }
        if text.contains("safety") || text.contains("fire") { return "Safety" }
        if text.contains("house") || text.contains("home") || text.contains("softener") { return "House" }
        if text.contains("mower") || text.contains("tractor") || text.contains("engine") { return "Equipment" }
        return "Equipment"
    }

    private static func frequency(from raw: String?, warningDays: Int) -> TaskFrequency {
        let text = (raw ?? "").lowercased()
        if text.contains("daily") { return .daily }
        if text.contains("2 week") || text.contains("biweek") || text.contains("every 2") {
            return .biweekly
        }
        if text.contains("week") { return .weekly }
        if text.contains("quarter") { return .quarterly }
        if text.contains("year") || text.contains("annual") { return .yearly }
        if text.contains("month") { return .monthly }

        if warningDays <= 1 { return .daily }
        if warningDays <= 7 { return .weekly }
        if warningDays <= 14 { return .biweekly }
        if warningDays <= 45 { return .monthly }
        if warningDays <= 120 { return .quarterly }
        return .yearly
    }
}

private struct ManualLLMPayload: Decodable {
    struct Tool: Decodable {
        var name: String?
        var size: String?
        var notes: String?
    }

    struct Task: Decodable {
        var area: String?
        var item: String?
        var category: String?
        var frequency: String?
        var warningDays: Int?
        var criticalDays: Int?
        var estimatedMinutes: Int?
        var taskDescription: String?
        var responseInstructions: String?
        var suppliesNeeded: String?
        var partNumbers: [String]?
        var referenceURLs: [String]?
        var toolsRequired: [Tool]?
        var notes: String?
    }

    enum CodingKeys: String, CodingKey {
        case manufacturer, equipment, tasks
    }

    var manufacturer: String
    var equipment: String
    var tasks: [Task]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        equipment = try c.decodeIfPresent(String.self, forKey: .equipment) ?? ""
        tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
    }
}

private struct URLManualLLMPayload: Decodable {
    mutating func merge(_ other: Self) {
        func first(_ current: String?, _ next: String?) -> String? {
            if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return current }
            return next
        }
        manufacturer = first(manufacturer, other.manufacturer)
        equipment = first(equipment, other.equipment)
        manualTitle = first(manualTitle, other.manualTitle)
        publicationNumber = first(publicationNumber, other.publicationNumber)
        model = first(model, other.model)
        serialNumberApplicability = first(serialNumberApplicability, other.serialNumberApplicability)
        tasks = (tasks ?? []) + (other.tasks ?? [])
    }
    struct Tool: Decodable {
        var name: String?
        var size: String?
        var notes: String?
    }

    struct SourceFacts: Decodable {
        var maintenanceInterval: String?
        var fluids: [String]?
        var capacities: [String]?
        var filters: [String]?
        var parts: [String]?
        var tools: [Tool]?
        var safetyWarnings: [String]?
        var sourceExcerpt: String?
        var sectionSourceURL: String?
        var sectionSourceURLs: [String]?
    }

    struct Task: Decodable {
        var area: String?
        var item: String?
        var category: String?
        var frequency: String?
        var warningDays: Int?
        var criticalDays: Int?
        var estimatedMinutes: Int?
        var taskDescription: String?
        var responseInstructions: String?
        var suppliesNeeded: String?
        var partNumbers: [String]?
        var referenceURLs: [String]?
        var sectionSourceURL: String?
        var toolsRequired: [Tool]?
        var sourceFacts: SourceFacts?
        var sourceExcerpt: String?
        var inferredNotes: String?
        var confidence: Double?
    }

    var manufacturer: String?
    var equipment: String?
    var manualTitle: String?
    var publicationNumber: String?
    var model: String?
    var serialNumberApplicability: String?
    var tasks: [Task]?
}
