import Foundation
import Observation

/// Finance ledger: ingested statement files, their charges, vendors, and
/// categories. Persisted as one JSON document in the app container on this
/// Mac — relaunch restores files, vendors, and assignments. No network, no
/// keychain, no database. A suggestion is never an accounting entry.
struct RanchOSFinanceFile: Codable, Identifiable, Sendable {
    var id: UUID
    var fileName: String
    var sha256Hex: String
    var kind: String
    var rowCount: Int
    var ingestedAt: Date
    var errors: [RanchOSFinanceFileError]

    var errorCount: Int { errors.count }
}

struct RanchOSFinanceFileError: Codable, Sendable {
    var row: Int
    var code: String
    var message: String
}

struct RanchOSFinanceCharge: Codable, Identifiable, Sendable {
    var id: UUID
    var fileID: UUID
    var dateText: String
    var merchantText: String
    var amountText: String
    var vendorID: UUID?
    var isDuplicate: Bool
    /// Apple's Category cell for this row, kept from ingest. Nil for bank
    /// rows, blank cells, and ledgers written before this field existed.
    var appleCategoryText: String? = nil
    /// This charge only. Nil means it follows the vendor rule. A missing key
    /// in an older ledger decodes as nil, so those charges keep following
    /// their vendor.
    var categoryOverrideID: UUID? = nil
}

struct RanchOSFinanceVendor: Codable, Identifiable, Sendable {
    enum Suggestion: String, Codable, Sendable {
        case suggested
        case unavailable
        case notObvious
    }

    var id: UUID
    var name: String
    var key: String
    var categoryID: UUID
    /// How the current category came to be suggested, if at all. A manual
    /// assignment clears it; a category delete that moves the vendor clears it.
    var suggestion: Suggestion?
}

struct RanchOSFinanceCategory: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var isUncategorized: Bool
}

struct RanchOSFinanceLedger: Codable, Sendable {
    var version: Int
    var files: [RanchOSFinanceFile]
    var charges: [RanchOSFinanceCharge]
    var vendors: [RanchOSFinanceVendor]
    var categories: [RanchOSFinanceCategory]
    var uses: [RanchOSFinanceUse]
    var operations: [RanchOSFinanceOperation]
}

extension RanchOSFinanceLedger {
    /// Added late: uses and operations default to empty so ledgers written
    /// before cost-by-thing still open with files, vendors, and assignments.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        files = try container.decode([RanchOSFinanceFile].self, forKey: .files)
        charges = try container.decode([RanchOSFinanceCharge].self, forKey: .charges)
        vendors = try container.decode([RanchOSFinanceVendor].self, forKey: .vendors)
        categories = try container.decode([RanchOSFinanceCategory].self, forKey: .categories)
        uses = try container.decodeIfPresent([RanchOSFinanceUse].self, forKey: .uses) ?? []
        operations = try container.decodeIfPresent([RanchOSFinanceOperation].self, forKey: .operations) ?? []
    }
}

/// Suggestion labels. The unavailable label is the honest fallback when
/// Foundation Models cannot run on this device.
enum RanchOSFinanceSuggestionLabels {
    static let suggested = "Suggested on this device"
    static let unavailable = "On-device suggestions unavailable"
    static let notObvious = "Not obvious from the name — left Uncategorized"
    static let uncategorized = "Uncategorized"
}

@MainActor
@Observable
final class RanchOSFinanceStore {
    static let ledgerVersion = 1
    static let ledgerFileName = "RanchOSFinanceLedger.json"

    private(set) var ledger: RanchOSFinanceLedger
    private let persistenceURL: URL?
    private let suggester: any RanchOSFinanceCategorySuggesting

    init(
        persistenceURL: URL? = RanchOSFinanceStore.defaultPersistenceURL(),
        suggester: any RanchOSFinanceCategorySuggesting = RanchOSFinanceLiveSuggester()
    ) {
        self.persistenceURL = persistenceURL
        self.suggester = suggester
        if let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let decoded = try? JSONDecoder().decode(RanchOSFinanceLedger.self, from: data),
            decoded.version == Self.ledgerVersion
        {
            self.ledger = decoded
        } else {
            self.ledger = Self.freshLedger()
        }
    }

    static func defaultPersistenceURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.openclaw.ranchos.dev"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(ledgerFileName)
    }

    static func freshLedger() -> RanchOSFinanceLedger {
        RanchOSFinanceLedger(
            version: ledgerVersion, files: [], charges: [], vendors: [],
            categories: [RanchOSFinanceCategory(
                id: UUID(), name: RanchOSFinanceSuggestionLabels.uncategorized, isUncategorized: true)],
            uses: [], operations: [])
    }

    /// Applies a ledger change from cost allocation (same module, separate
    /// file) and persists. The ledger setter stays private.
    func mutateLedger(_ transform: (inout RanchOSFinanceLedger) -> Void) {
        transform(&ledger)
        persist()
    }

    var uncategorizedID: UUID? {
        ledger.categories.first(where: \.isUncategorized)?.id
    }

    func category(id: UUID) -> RanchOSFinanceCategory? {
        ledger.categories.first(where: { $0.id == id })
    }

    func vendor(id: UUID) -> RanchOSFinanceVendor? {
        ledger.vendors.first(where: { $0.id == id })
    }

    func charges(vendorID: UUID) -> [RanchOSFinanceCharge] {
        ledger.charges.filter { $0.vendorID == vendorID }
    }

    func charges(fileID: UUID) -> [RanchOSFinanceCharge] {
        ledger.charges.filter { $0.fileID == fileID }
    }

    func vendors(categoryID: UUID) -> [RanchOSFinanceVendor] {
        ledger.vendors.filter { $0.categoryID == categoryID }
    }

    /// Ingests one CSV. Re-ingesting identical bytes is a no-op returning the
    /// existing file. Every distinct non-empty Category value on accepted
    /// Apple rows becomes a Finance category. Each new vendor lands in that
    /// category only when every accepted charge for it shows the same
    /// non-empty value; blank cells and mixed values leave it Uncategorized.
    /// Vendors placed before this file are never moved. Returns the file plus
    /// vendors seen for the first time (the caller asks for suggestions for
    /// those left Uncategorized).
    @discardableResult
    func ingest(fileName: String, bytes: Data, now: Date = Date()) -> (
        file: RanchOSFinanceFile, newVendors: [RanchOSFinanceVendor]
    ) {
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes, now: now)
        if let existing = ledger.files.first(where: { $0.sha256Hex == parsed.sha256Hex }) {
            return (existing, [])
        }
        let file = RanchOSFinanceFile(
            id: UUID(), fileName: fileName, sha256Hex: parsed.sha256Hex,
            kind: parsed.kind.rawValue, rowCount: parsed.rowCount, ingestedAt: now,
            errors: parsed.errors.map {
                RanchOSFinanceFileError(row: $0.row, code: $0.code, message: $0.message)
            })
        ledger.files.append(file)
        for value in appleCategoryValues(from: parsed.charges) {
            _ = categoryIDForAppleValue(value)
        }
        var newVendors: [RanchOSFinanceVendor] = []
        for parsedCharge in parsed.charges {
            let vendorID = vendorIDForMerchant(parsedCharge.merchantText, newVendors: &newVendors)
            ledger.charges.append(RanchOSFinanceCharge(
                id: UUID(), fileID: file.id, dateText: parsedCharge.dateText,
                merchantText: parsedCharge.merchantText, amountText: parsedCharge.amountText,
                vendorID: vendorID, isDuplicate: parsedCharge.isDuplicate,
                appleCategoryText: parsedCharge.categoryText.isEmpty ? nil : parsedCharge.categoryText,
                categoryOverrideID: nil))
        }
        for vendor in newVendors {
            placeNewVendorIfUnanimous(vendorID: vendor.id, fileID: file.id)
        }
        persist()
        newVendors = newVendors.compactMap { placed in vendor(id: placed.id) }
        return (file, newVendors)
    }

    /// Distinct trimmed non-empty Category values on these parsed charges.
    private func appleCategoryValues(from charges: [RanchOSFinanceCSV.Charge]) -> [String] {
        var seen: [String] = []
        for charge in charges {
            let trimmed = charge.categoryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !seen.contains(trimmed) {
                seen.append(trimmed)
            }
        }
        return seen
    }

    /// Category id for one Apple value. Names match case-insensitively and a
    /// match reuses the existing id. A value naming Uncategorized resolves to
    /// the flagged row, so a second Uncategorized is never created. Nil when
    /// the name cannot become a category.
    private func categoryIDForAppleValue(_ value: String) -> UUID? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == RanchOSFinanceSuggestionLabels.uncategorized.lowercased() {
            return uncategorizedID
        }
        if let existing = ledger.categories.first(where: {
            $0.name.lowercased() == trimmed.lowercased()
        }) {
            return existing.id
        }
        return createCategory(name: trimmed)?.id
    }

    /// Places a vendor created by this ingest when every accepted charge for
    /// it in this file shows the same non-empty Category value. Blank cells
    /// and mixed values leave it Uncategorized. This is file data, not a
    /// guess, so no suggestion mark is set.
    private func placeNewVendorIfUnanimous(vendorID: UUID, fileID: UUID) {
        let charges = ledger.charges.filter { $0.vendorID == vendorID && $0.fileID == fileID }
        guard !charges.isEmpty else { return }
        let values = charges.compactMap { $0.appleCategoryText }
        guard values.count == charges.count else { return }
        let distinct = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard distinct.count == 1, let value = distinct.first,
            let categoryID = categoryIDForAppleValue(value),
            let index = ledger.vendors.firstIndex(where: { $0.id == vendorID })
        else {
            return
        }
        ledger.vendors[index].categoryID = categoryID
    }

    /// Creates a category. Blank and duplicate (case-insensitive) names fail.
    @discardableResult
    func createCategory(name: String) -> RanchOSFinanceCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        if ledger.categories.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return nil
        }
        let category = RanchOSFinanceCategory(id: UUID(), name: trimmed, isUncategorized: false)
        ledger.categories.append(category)
        persist()
        return category
    }

    /// Renames a category in place. Identity stays: the id is unchanged and
    /// vendor assignments stay on it. A blank name or a duplicate of another
    /// category fails and the previous name stands. No replacement category
    /// is created.
    @discardableResult
    func renameCategory(id: UUID, newName: String) -> Bool {
        guard let index = ledger.categories.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        if trimmed == ledger.categories[index].name { return true }
        if ledger.categories.contains(where: {
            $0.id != id && $0.name.lowercased() == trimmed.lowercased()
        }) {
            return false
        }
        ledger.categories[index].name = trimmed
        persist()
        return true
    }

    /// Deletes a category. Uncategorized cannot be deleted. Vendors move to
    /// Uncategorized with their suggestion cleared. A charge that named this
    /// category for itself moves to Uncategorized and stays an individual
    /// assignment. Files are untouched.
    @discardableResult
    func deleteCategory(id: UUID) -> Bool {
        guard let category = category(id: id), !category.isUncategorized,
            let uncategorizedID
        else {
            return false
        }
        ledger.categories.removeAll(where: { $0.id == id })
        for index in ledger.vendors.indices where ledger.vendors[index].categoryID == id {
            ledger.vendors[index].categoryID = uncategorizedID
            ledger.vendors[index].suggestion = nil
        }
        for index in ledger.charges.indices where ledger.charges[index].categoryOverrideID == id {
            ledger.charges[index].categoryOverrideID = uncategorizedID
        }
        persist()
        return true
    }

    /// Category shown for one charge. An individual assignment wins. Otherwise
    /// the charge follows its vendor. A dangling id falls through to the vendor.
    func categoryID(for charge: RanchOSFinanceCharge) -> UUID? {
        if let override = charge.categoryOverrideID, category(id: override) != nil {
            return override
        }
        if let vendorID = charge.vendorID, let vendor = vendor(id: vendorID) {
            return vendor.categoryID
        }
        return uncategorizedID
    }

    /// Charges whose vendor name or merchant text contains the filter.
    /// A blank filter returns every charge. Matching is case-insensitive.
    func charges(matchingVendorFilter filter: String) -> [RanchOSFinanceCharge] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return ledger.charges }
        return ledger.charges.filter { charge in
            if charge.merchantText.lowercased().contains(needle) { return true }
            if let vendorID = charge.vendorID, let vendor = vendor(id: vendorID) {
                return vendor.name.lowercased().contains(needle)
            }
            return false
        }
    }

    /// Assigns a category to these charges only. The vendor rule is not
    /// changed, and the model is not asked. Choosing the vendor's own
    /// category clears the individual assignment so the charge follows the
    /// rule again.
    func assign(chargeIDs: Set<UUID>, categoryID: UUID) {
        guard category(id: categoryID) != nil else { return }
        var changed = false
        for index in ledger.charges.indices where chargeIDs.contains(ledger.charges[index].id) {
            let charge = ledger.charges[index]
            let vendorCategory = charge.vendorID.flatMap { vendor(id: $0)?.categoryID }
            let override: UUID? = vendorCategory == categoryID ? nil : categoryID
            if ledger.charges[index].categoryOverrideID != override {
                ledger.charges[index].categoryOverrideID = override
                changed = true
            }
        }
        if changed { persist() }
    }

    func assign(chargeID: UUID, categoryID: UUID) {
        assign(chargeIDs: [chargeID], categoryID: categoryID)
    }

    /// Assigns a vendor. Charges with no individual category follow this rule.
    /// Charges he set one by one keep their category. Clears any suggestion
    /// mark: the current category is now the user's choice.
    func assign(vendorID: UUID, categoryID: UUID) {
        guard category(id: categoryID) != nil,
            let index = ledger.vendors.firstIndex(where: { $0.id == vendorID })
        else {
            return
        }
        ledger.vendors[index].categoryID = categoryID
        ledger.vendors[index].suggestion = nil
        persist()
    }

    /// Proposes the first category for a new vendor. His assignment is the
    /// rule: a vendor he already placed is never sent to the model, so later
    /// charges from that vendor keep his rule untouched. The model may only
    /// pick from the existing categories; an invented name, an Uncategorized
    /// answer, or an unavailable model leaves the vendor Uncategorized with
    /// the honest label. Nothing is created from a suggestion.
    func requestSuggestion(vendorID: UUID) async {
        guard let index = ledger.vendors.firstIndex(where: { $0.id == vendorID }),
            let uncategorizedID,
            ledger.vendors[index].categoryID == uncategorizedID
        else {
            return
        }
        let vendor = ledger.vendors[index]
        let names = ledger.categories.map(\.name)
        guard let suggested = await suggester.suggestCategory(
            vendorName: vendor.name, categories: names)
        else {
            ledger.vendors[index].suggestion = .unavailable
            persist()
            return
        }
        if let match = ledger.categories.first(where: {
            !$0.isUncategorized && $0.name.lowercased() == suggested.lowercased()
        }) {
            ledger.vendors[index].categoryID = match.id
            ledger.vendors[index].suggestion = .suggested
        } else {
            ledger.vendors[index].suggestion = .notObvious
        }
        persist()
    }

    // MARK: - Vendors

    static func vendorKey(_ merchant: String) -> String {
        merchant.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func vendorIDForMerchant(
        _ merchant: String, newVendors: inout [RanchOSFinanceVendor]
    ) -> UUID? {
        let key = Self.vendorKey(merchant)
        if key.isEmpty { return nil }
        if let existing = ledger.vendors.first(where: { $0.key == key }) {
            return existing.id
        }
        guard let uncategorizedID else { return nil }
        let display = String(merchant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let vendor = RanchOSFinanceVendor(
            id: UUID(), name: display.isEmpty ? merchant : display, key: key,
            categoryID: uncategorizedID, suggestion: nil)
        ledger.vendors.append(vendor)
        newVendors.append(vendor)
        return vendor.id
    }

    // MARK: - Persistence (this Mac only)

    /// Module-visible so cost allocation (same module, separate file) persists.
    func persist() {
        guard let persistenceURL else { return }
        do {
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // In-memory truth survives; the next mutation retries.
        }
    }
}
