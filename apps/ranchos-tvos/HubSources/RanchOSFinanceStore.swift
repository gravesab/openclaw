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
    /// Account the charges came from: Apple, Chase, Capital One, or a name he
    /// typed. Nil on ledgers written before sources existed.
    var source: String? = nil
    /// The account he pulled this statement for. Nil when the file was chosen
    /// without an account. Older ledgers decode this as nil.
    var accountID: UUID? = nil

    var errorCount: Int { errors.count }
}

struct RanchOSFinanceFileError: Codable, Sendable {
    var row: Int
    var code: String
    var message: String
}

/// An account he added: a credit card, a bank, or another name. The institution
/// list is a menu, not a set of connections. Sign-in is not kept.
struct RanchOSFinanceAccount: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: RanchOSFinanceAccountKind?
    /// What a loan is for. Other account types leave this empty. Older ledgers
    /// decode a missing key as empty.
    var purpose: String? = nil
    /// The web page where he downloads this account's statements. Opened in
    /// the browser only; RanchOS never signs in there. Older ledgers decode
    /// a missing key as empty.
    var downloadURL: String? = nil
    /// Dated principal snapshots on a loan, as read or typed, never derived.
    /// The newest is the balance. Older ledgers decode a missing key as empty.
    var principalSnapshots: [RanchOSFinancePrincipalSnapshot] = []

    init(
        id: UUID, name: String, kind: RanchOSFinanceAccountKind?, purpose: String? = nil,
        downloadURL: String? = nil, principalSnapshots: [RanchOSFinancePrincipalSnapshot] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.purpose = purpose
        self.downloadURL = downloadURL
        self.principalSnapshots = principalSnapshots
    }

    /// A ledger written before principal snapshots has no such key. Decoding
    /// must still open the account, with an empty balance list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(RanchOSFinanceAccountKind.self, forKey: .kind)
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        principalSnapshots = try container.decodeIfPresent(
            [RanchOSFinancePrincipalSnapshot].self, forKey: .principalSnapshots) ?? []
    }
}

/// One dated principal balance on a loan. The date is a UTC day; the amount
/// is kept exactly as the statement or the person gave it.
struct RanchOSFinancePrincipalSnapshot: Codable, Sendable, Equatable {
    var date: Date
    var amount: Decimal
}

/// What ingesting a loan statement kept. Nil for cards, banks, and files
/// that kept nothing new.
enum RanchOSFinancePrincipalOutcome: Sendable, Equatable {
    case recorded(date: Date, amount: Decimal)
    case missing
}

enum RanchOSFinanceAccountKind: String, Codable, CaseIterable, Sendable {
    case creditCard
    case bank
    case loan
    case other

    var label: String {
        switch self {
        case .creditCard: "Credit card"
        case .bank: "Bank"
        case .loan: "Loan"
        case .other: "Other"
        }
    }
}

/// Whether this Mac can pull the institution without a statement file.
struct RanchOSFinanceAccountCheck: Equatable, Sendable {
    var automated: Bool
    var detail: String
}

/// Recent charges that belong to one account, or to a statement that has no
/// account yet.
struct RanchOSFinanceAccountGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var charges: [RanchOSFinanceCharge]
}

/// Institution names for the account menu, and the automation check for the
/// name he selects. None of these are connected. Apple Card is the one Apple
/// API, FinanceKit, and it is not available to this app on this Mac.
enum RanchOSFinanceAccountCatalog {
    static let otherName = "Other name"

    static func names(for kind: RanchOSFinanceAccountKind) -> [String] {
        let names: [String]
        switch kind {
        case .creditCard:
            names = [
                "American Express", "Apple Card", "Bank of America", "Barclays",
                "Capital One", "Chase", "Citi", "Credit One", "Discover",
                "Navy Federal", "PNC", "Synchrony", "TD Bank", "U.S. Bank",
                "USAA", "Wells Fargo",
            ]
        case .bank:
            names = [
                "Ally", "Bank of America", "BMO", "Capital One", "Chase", "Citi",
                "Citizens", "Fifth Third", "First Citizens", "HSBC", "KeyBank",
                "M&T Bank", "Navy Federal", "PNC", "Regions", "Santander",
                "TD Bank", "Truist", "U.S. Bank", "USAA", "Wells Fargo",
            ]
        case .loan:
            names = [
                "Aidvantage", "Ally", "Bank of America", "Capital One", "Chase",
                "First United Bank", "Freedom Mortgage", "LoanCare", "MOHELA",
                "Mr. Cooper", "Nelnet", "Newrez", "Pennymac", "Rocket Mortgage",
                "Sallie Mae", "SoFi", "TFCU", "U.S. Bank", "Wells Fargo",
            ]
        case .other:
            names = []
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Sign-in and transaction APIs RanchOS can use for this institution.
    /// Apple Card is FinanceKit on iPhone, which this Mac app cannot use.
    /// No other institution has a connected sign-in or download API.
    static func automation(kind: RanchOSFinanceAccountKind, name: String) -> RanchOSFinanceAccountCheck {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        let shown = trimmed.isEmpty ? "this account" : trimmed
        if key == "apple card" || (kind == .creditCard && key == "apple") {
            return RanchOSFinanceAccountCheck(
                automated: false,
                detail: "RanchOS cannot sign in to Apple Card from this Mac. Apple can share Apple Card from Wallet on iPhone through FinanceKit, and this app does not have that permission yet. Download the transactions from Apple, then import the file.")
        }
        return RanchOSFinanceAccountCheck(
            automated: false,
            detail: "RanchOS cannot sign in to \(shown) or download transactions from an API. Download the transactions from \(shown), then import the file.")
    }
}

/// Statement files live off the M4’s internal disk. T2 WD X has the free
/// space, and each account gets a folder under RanchOS Account Transactions.
enum RanchOSFinanceAccountFolders {
    static let volumePath = "/Volumes/T2 WD X"
    static let root = URL(
        fileURLWithPath: "/Volumes/T2 WD X/Downloads/RanchOS Account Transactions",
        isDirectory: true)

    static var volumeIsMounted: Bool {
        FileManager.default.fileExists(atPath: volumePath)
    }

    /// A second loan from the same lender adds its purpose. The first one keeps
    /// the folder it already has.
    static func folderName(for account: RanchOSFinanceAccount, among accounts: [RanchOSFinanceAccount]) -> String {
        let sameName = accounts.filter { $0.name.lowercased() == account.name.lowercased() }
        let sameKind = sameName.filter { $0.kind == account.kind }
        var raw = account.name
        if sameName.count > sameKind.count {
            raw += " - \(account.kind?.label ?? "Account")"
        }
        if let position = sameKind.firstIndex(where: { $0.id == account.id }), position > 0 {
            raw += " - \(account.purpose ?? String(position + 1))"
        }
        return sanitize(raw)
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Account" : cleaned
    }

    @discardableResult
    static func ensure(_ account: RanchOSFinanceAccount, among accounts: [RanchOSFinanceAccount]) -> URL? {
        guard volumeIsMounted else { return nil }
        let url = root.appendingPathComponent(folderName(for: account, among: accounts), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Puts a chosen statement in the account folder. A file already in the
    /// folder stays put. Otherwise it is copied in; the original stays where
    /// the browser left it. The same file again is not copied twice, and a
    /// different file with the same name gets " 2", " 3", and so on.
    static func file(_ statement: URL, into folder: URL) throws -> URL {
        let manager = FileManager.default
        let parent = statement.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        if parent.path == folder.resolvingSymlinksInPath().standardizedFileURL.path {
            return statement
        }
        let bytes = try Data(contentsOf: statement)
        let stem = statement.deletingPathExtension().lastPathComponent
        let ext = statement.pathExtension
        var attempt = 1
        while true {
            let name = attempt == 1 ? stem : "\(stem) \(attempt)"
            let destination = folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !manager.fileExists(atPath: destination.path) {
                try manager.copyItem(at: statement, to: destination)
                return destination
            }
            if (try? Data(contentsOf: destination)) == bytes {
                return destination
            }
            attempt += 1
        }
    }
}

/// One charge as it stood when a statement was archived. Deleting that
/// category, or folding Other into Uncategorized, rewrites the stored name.
struct RanchOSFinanceArchiveCharge: Codable, Identifiable, Sendable {
    var id: UUID
    var dateText: String
    var merchantText: String
    var amountText: String
    var categoryName: String
    /// The split as it stood when archived. Nil when the charge was not split.
    var splitParts: [RanchOSFinanceArchiveSplitPart]? = nil
}

struct RanchOSFinanceArchiveSplitPart: Codable, Sendable {
    var categoryName: String
    var amount: Decimal
}

/// One piece of a split transaction. He types every piece; the pieces add up
/// to the size of the transaction amount.
struct RanchOSFinanceSplitPart: Codable, Identifiable, Sendable {
    var id: UUID
    var categoryID: UUID
    var amount: Decimal
}

/// A finished statement: the account, the transaction date range, and the
/// categories assigned at the time it was archived.
struct RanchOSFinanceArchive: Codable, Identifiable, Sendable {
    var id: UUID
    var fileID: UUID
    var fileName: String
    var source: String
    var rangeLabel: String
    var archivedAt: Date
    var charges: [RanchOSFinanceArchiveCharge]
    /// Set when this History record is one closed month from an import that
    /// crossed into a later month. Nil on a whole-statement archive.
    var year: Int? = nil
    var month: Int? = nil
}

/// A month before an account's newest transactions. A July charge means
/// June and every earlier month can move to History. The newest month stays.
struct RanchOSFinanceArchiveOffer: Identifiable, Equatable, Sendable {
    var accountID: UUID
    var accountName: String
    var fileIDs: [UUID]
    var month: RanchOSFinanceReadyMonth
    var openMonthLabel: String
    var earliest: Date
    var latest: Date
    var id: String { "\(accountID.uuidString)-\(month.id)" }
}

/// A calendar month that is finished because the import continues into a
/// later month. June is ready when the same import also has July.
struct RanchOSFinanceReadyMonth: Identifiable, Equatable, Sendable {
    var year: Int
    var month: Int
    var id: String { "\(year)-\(month)" }
    var label: String { RanchOSFinanceDates.monthLabel(year: year, month: month) }
}

/// History rows for one account, such as Apple’s June. An account with no
/// archives is still a group.
struct RanchOSFinanceHistoryGroup: Identifiable, Sendable {
    var account: String
    var archives: [RanchOSFinanceArchive]
    var id: String
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
    /// Two or more categories sharing this charge. Wins over the override and
    /// the vendor rule. Older ledgers decode this as nil.
    var splitParts: [RanchOSFinanceSplitPart]? = nil
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

/// One category and the vendors assigned to it, for the Categories page.
struct RanchOSFinanceCategoryVendors: Identifiable, Sendable {
    var category: RanchOSFinanceCategory
    var vendors: [RanchOSFinanceVendor]
    var id: UUID { category.id }
}

/// A named set of categories for the Charts show menu, such as Day-to-day
/// living or Health. An empty set charts nothing until categories are turned on.
struct RanchOSFinanceChartProfile: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var categoryIDs: [UUID]
}

struct RanchOSFinanceLedger: Codable, Sendable {
    var version: Int
    var files: [RanchOSFinanceFile]
    var charges: [RanchOSFinanceCharge]
    var vendors: [RanchOSFinanceVendor]
    var categories: [RanchOSFinanceCategory]
    var uses: [RanchOSFinanceUse]
    var operations: [RanchOSFinanceOperation]
    var archives: [RanchOSFinanceArchive]
    /// Accounts he set up so a click can bring that account's statement into
    /// recent transactions. No passwords. Older ledgers decode this as empty.
    var accounts: [RanchOSFinanceAccount]
    /// Saved chart shows the user created. Older ledgers decode this as empty.
    var chartProfiles: [RanchOSFinanceChartProfile]
    /// Names he typed under Other name, offered again in that type's Name
    /// picker. They stay after the account is removed. Older ledgers decode
    /// this as empty.
    var addedNames: [RanchOSFinanceAddedName] = []
}

/// One typed institution name for one account type.
struct RanchOSFinanceAddedName: Codable, Equatable, Sendable {
    var kind: RanchOSFinanceAccountKind
    var name: String
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
        archives = try container.decodeIfPresent([RanchOSFinanceArchive].self, forKey: .archives) ?? []
        accounts = try container.decodeIfPresent([RanchOSFinanceAccount].self, forKey: .accounts) ?? []
        chartProfiles = try container.decodeIfPresent([RanchOSFinanceChartProfile].self, forKey: .chartProfiles) ?? []
        addedNames = try container.decodeIfPresent([RanchOSFinanceAddedName].self, forKey: .addedNames) ?? []
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
    /// Chart results for the current ledger. Not observed, so filling it does
    /// not redraw Finance. Cleared on every save.
    let chartCache = ChartCache()

    final class ChartCache {
        var categoryTotals: (RanchOSFinanceChartQuery, [RanchOSFinanceCategoryBar])?
        var windowTotals: (RanchOSFinanceChartQuery, [RanchOSFinanceChartWindow], [RanchOSFinanceCategoryBar])?
        var periodBars: (
            RanchOSFinanceChartTime, Int, Int, Int, RanchOSFinanceChartQuery, [RanchOSFinancePeriodBar]
        )?
        var samePeriod: (RanchOSFinanceChartQuery, RanchOSFinancePeriodCompare)?

        func clear() {
            categoryTotals = nil
            windowTotals = nil
            periodBars = nil
            samePeriod = nil
        }
    }

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
        foldOtherIntoUncategorized()
        rememberTypedAccountNames()
    }

    /// Reads the ledger file again. The report then matches what is kept on
    /// this device, including a transaction added after the screen opened.
    func reloadFromDisk() {
        guard let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let decoded = try? JSONDecoder().decode(RanchOSFinanceLedger.self, from: data),
            decoded.version == Self.ledgerVersion
        else { return }
        ledger = decoded
        chartCache.clear()
        foldOtherIntoUncategorized()
        rememberTypedAccountNames()
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
            uses: [], operations: [], archives: [], accounts: [],
            chartProfiles: [])
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

    /// Assignment menus show categories A–Z. Ledger order stays the order
    /// they were added.
    var categoriesByName: [RanchOSFinanceCategory] {
        ledger.categories.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var accountsByName: [RanchOSFinanceAccount] {
        ledger.accounts.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var chartProfilesByName: [RanchOSFinanceChartProfile] {
        ledger.chartProfiles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Adds a show profile. Blank names and a name already used fail. Categories
    /// that are not turned on are left out, so a new filter does not show every expense.
    @discardableResult
    func createChartProfile(name: String, categoryIDs: Set<UUID> = []) -> RanchOSFinanceChartProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        if ledger.chartProfiles.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return nil
        }
        let known = categoryIDs.filter { category(id: $0) != nil }
        let profile = RanchOSFinanceChartProfile(
            id: UUID(), name: trimmed,
            categoryIDs: known.sorted { $0.uuidString < $1.uuidString })
        ledger.chartProfiles.append(profile)
        persist()
        return profile
    }

    func deleteChartProfile(id: UUID) {
        let before = ledger.chartProfiles.count
        ledger.chartProfiles.removeAll { $0.id == id }
        if ledger.chartProfiles.count != before { persist() }
    }

    /// Remembers which categories belong to this show. Unknown ids are dropped.
    func setChartProfileCategories(id: UUID, categoryIDs: Set<UUID>) {
        guard let index = ledger.chartProfiles.firstIndex(where: { $0.id == id }) else { return }
        let known = categoryIDs.filter { category(id: $0) != nil }
        ledger.chartProfiles[index].categoryIDs = known.sorted { $0.uuidString < $1.uuidString }
        persist()
    }

    /// Adds an account of one type. Blank names fail. The same name may be a
    /// credit card and a bank. The same name and type twice fails, except two
    /// loans from one lender for different purposes, such as House and 20 Acres.
    @discardableResult
    func createAccount(
        name: String, kind: RanchOSFinanceAccountKind, purpose: String? = nil
    ) -> RanchOSFinanceAccount? {
        guard let name = RanchOSFinanceDates.normalizedSource(name) else { return nil }
        guard accountAddProblem(name: name, kind: kind, purpose: purpose) == nil else { return nil }
        let account = RanchOSFinanceAccount(
            id: UUID(), name: name, kind: kind, purpose: kind == .loan ? trimmedPurpose(purpose) : nil)
        ledger.accounts.append(account)
        addPickerName(name, kind: kind)
        persist()
        return account
    }

    /// The Name picker for one type: the built-in list plus every name he
    /// typed for that type, A–Z. "Other name" is added by the sheet.
    func pickerNames(for kind: RanchOSFinanceAccountKind) -> [String] {
        var names = RanchOSFinanceAccountCatalog.names(for: kind)
        for added in ledger.addedNames where added.kind == kind && !Self.containsName(names, added.name) {
            names.append(added.name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func containsName(_ names: [String], _ name: String) -> Bool {
        names.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds a typed name to its type's picker. Built-in and known names are skipped.
    private func addPickerName(_ name: String, kind: RanchOSFinanceAccountKind) {
        guard !Self.containsName(pickerNames(for: kind), name) else { return }
        ledger.addedNames.append(RanchOSFinanceAddedName(kind: kind, name: name))
    }

    /// Accounts typed before the picker kept names still get their name offered.
    private func rememberTypedAccountNames() {
        let before = ledger.addedNames.count
        for account in ledger.accounts {
            addPickerName(account.name, kind: account.kind ?? .other)
        }
        if ledger.addedNames.count != before { persist() }
    }

    /// Remembers what a loan is for. A blank value clears it. Other account
    /// types are left alone.
    func setLoanPurpose(accountID: UUID, purpose: String) {
        guard let index = ledger.accounts.firstIndex(where: { $0.id == accountID }),
            ledger.accounts[index].kind == .loan
        else { return }
        let next = trimmedPurpose(purpose)
        if ledger.accounts[index].purpose == next { return }
        ledger.accounts[index].purpose = next
        persist()
    }

    /// The current principal balance: the newest dated snapshot. Nil when
    /// the loan has none. Other account types have none.
    func principalBalance(accountID: UUID) -> RanchOSFinancePrincipalSnapshot? {
        principalHistory(accountID: accountID).last
    }

    /// The declining balance: snapshots oldest first. Empty for cards,
    /// banks, and loans with none.
    func principalHistory(accountID: UUID) -> [RanchOSFinancePrincipalSnapshot] {
        guard let account = ledger.accounts.first(where: { $0.id == accountID }),
            account.kind == .loan
        else { return [] }
        return account.principalSnapshots.sorted { $0.date < $1.date }
    }

    /// Keeps one dated principal snapshot, as read or typed. A newer date is
    /// added; the same date replaces that date; an older date joins the
    /// history without changing the current balance. Other account types
    /// are left alone. Nothing here subtracts payments, interest, or escrow.
    func recordPrincipalSnapshot(accountID: UUID, date: Date, amount: Decimal) {
        guard let index = ledger.accounts.firstIndex(where: { $0.id == accountID }),
            ledger.accounts[index].kind == .loan
        else { return }
        let day = RanchOSFinanceDates.startOfUTCDay(date)
        if let same = ledger.accounts[index].principalSnapshots.firstIndex(where: { $0.date == day }) {
            if ledger.accounts[index].principalSnapshots[same].amount == amount { return }
            ledger.accounts[index].principalSnapshots[same].amount = amount
        } else {
            ledger.accounts[index].principalSnapshots.append(
                RanchOSFinancePrincipalSnapshot(date: day, amount: amount))
        }
        persist()
    }

    /// Sets the statement download page. A blank value clears it. A bare
    /// address such as bank.example/statements gets https://. Returns the
    /// problem and keeps the old link when the address is not a web page.
    @discardableResult
    func setDownloadLink(accountID: UUID, text: String) -> String? {
        guard let index = ledger.accounts.firstIndex(where: { $0.id == accountID }) else {
            return "That account is gone."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String?
        if trimmed.isEmpty {
            next = nil
        } else {
            guard let url = Self.downloadPage(trimmed) else {
                return "Use a web address, such as https://bank.example/statements."
            }
            next = url.absoluteString
        }
        if ledger.accounts[index].downloadURL == next { return nil }
        ledger.accounts[index].downloadURL = next
        persist()
        return nil
    }

    /// A web page address, or nil. Only http and https open; anything else
    /// could launch another app.
    static func downloadPage(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = url.host, host.contains("."),
            url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// Renames a loan whose name was typed, not chosen from the institution list.
    /// A blank name fails. Another loan with that name fails. A listed
    /// institution stays as chosen.
    @discardableResult
    func renameTypedLoan(accountID: UUID, name: String) -> Bool {
        guard let index = ledger.accounts.firstIndex(where: { $0.id == accountID }) else { return false }
        let account = ledger.accounts[index]
        guard account.kind == .loan, !loanNameIsListed(account.name) else { return false }
        guard let next = RanchOSFinanceDates.normalizedSource(name) else { return false }
        if next.localizedCaseInsensitiveCompare(account.name) == .orderedSame {
            return true
        }
        let taken = ledger.accounts.contains { other in
            other.id != accountID && other.kind == .loan
                && other.name.localizedCaseInsensitiveCompare(next) == .orderedSame
                && samePurpose(other.purpose, account.purpose)
        }
        guard !taken else { return false }
        ledger.accounts[index].name = next
        // A rename usually fixes a typo, so the old spelling leaves the picker
        // unless another loan still uses it.
        let oldStillUsed = ledger.accounts.contains {
            $0.kind == .loan && $0.name.localizedCaseInsensitiveCompare(account.name) == .orderedSame
        }
        if !oldStillUsed {
            ledger.addedNames.removeAll {
                $0.kind == .loan && $0.name.localizedCaseInsensitiveCompare(account.name) == .orderedSame
            }
        }
        addPickerName(next, kind: .loan)
        for fileIndex in ledger.files.indices
        where ledger.files[fileIndex].accountID == accountID
            && ledger.files[fileIndex].source?.localizedCaseInsensitiveCompare(account.name) == .orderedSame
        {
            ledger.files[fileIndex].source = next
        }
        persist()
        return true
    }

    func loanNameWasTyped(_ account: RanchOSFinanceAccount) -> Bool {
        account.kind == .loan && !loanNameIsListed(account.name)
    }

    private func loanNameIsListed(_ name: String) -> Bool {
        RanchOSFinanceAccountCatalog.names(for: .loan).contains {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Why Add account cannot add this account, or nil when it can.
    func accountAddProblem(name: String, kind: RanchOSFinanceAccountKind, purpose: String?) -> String? {
        guard let name = RanchOSFinanceDates.normalizedSource(name) else { return nil }
        let sameName = ledger.accounts.filter {
            $0.kind == kind && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !sameName.isEmpty else { return nil }
        guard kind == .loan else {
            return "\(name) is already an account of type \(kind.label)."
        }
        let next = trimmedPurpose(purpose)
        if sameName.contains(where: { samePurpose($0.purpose, next) }) {
            if let next {
                return "\(name) already has a loan for \(next)."
            }
            return "\(name) already has a loan. Say what this loan is for."
        }
        return nil
    }

    private func samePurpose(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.localizedCaseInsensitiveCompare(right) == .orderedSame
        default:
            return false
        }
    }

    /// Another loan from the same lender, so the purpose tells them apart.
    func sharesLoanName(_ account: RanchOSFinanceAccount) -> Bool {
        account.kind == .loan && ledger.accounts.contains { other in
            other.id != account.id && other.kind == .loan
                && other.name.localizedCaseInsensitiveCompare(account.name) == .orderedSame
        }
    }

    /// The account name, with the purpose when two loans share a lender.
    func accountDisplayName(_ account: RanchOSFinanceAccount) -> String {
        guard sharesLoanName(account), let purpose = account.purpose else { return account.name }
        return "\(account.name) · \(purpose)"
    }

    private func trimmedPurpose(_ purpose: String?) -> String? {
        let trimmed = purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func charges(forAccount id: UUID) -> [RanchOSFinanceCharge] {
        let fileIDs = Set(ledger.files.filter { $0.accountID == id }.map(\.id))
        return ledger.charges.filter { fileIDs.contains($0.fileID) }
    }

    /// True when History already has this charge for its month, or a
    /// whole-statement History record includes this charge. Recent leaves
    /// those out. The charge stays in the ledger for charts.
    func isMovedToHistory(_ charge: RanchOSFinanceCharge) -> Bool {
        ledger.archives.contains { archive in
            guard archive.fileID == charge.fileID else { return false }
            if archive.year == nil && archive.month == nil {
                return archive.charges.contains { $0.id == charge.id }
            }
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
            let parts = RanchOSFinanceDates.yearMonth(date)
            return archive.year == parts.year && archive.month == parts.month
        }
    }

    /// Groups recent charges by the account they were pulled for. Accounts
    /// from the Accounts tab come first. A statement with no account is its
    /// own group. Charges already moved to History are left out.
    func recentAccountGroups() -> [RanchOSFinanceAccountGroup] {
        var buckets: [String: [RanchOSFinanceCharge]] = [:]
        var titles: [String: String] = [:]
        for charge in ledger.charges where !isMovedToHistory(charge) {
            let file = file(id: charge.fileID)
            let key: String
            let title: String
            if let accountID = file?.accountID,
                let account = ledger.accounts.first(where: { $0.id == accountID })
            {
                key = account.id.uuidString
                title = accountLabel(account)
            } else if let source = file?.source, !source.isEmpty {
                key = "source:\(source.lowercased())"
                title = source
            } else {
                key = "none"
                title = "No account"
            }
            if buckets[key] == nil { titles[key] = title }
            buckets[key, default: []].append(charge)
        }
        let accountKeys = accountsByName.map(\.id.uuidString)
        let keys = buckets.keys.sorted { lhs, rhs in
            switch (accountKeys.firstIndex(of: lhs), accountKeys.firstIndex(of: rhs)) {
            case let (left?, right?):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return (titles[lhs] ?? "").localizedStandardCompare(titles[rhs] ?? "") == .orderedAscending
            }
        }
        return keys.map { key in
            let charges = (buckets[key] ?? []).sorted { lhs, rhs in
                let left = RanchOSFinanceDates.parse(lhs.dateText) ?? .distantPast
                let right = RanchOSFinanceDates.parse(rhs.dateText) ?? .distantPast
                if left != right { return left > right }
                return lhs.merchantText.localizedStandardCompare(rhs.merchantText) == .orderedAscending
            }
            return RanchOSFinanceAccountGroup(id: key, title: titles[key] ?? key, charges: charges)
        }
    }

    func accountLabel(_ account: RanchOSFinanceAccount) -> String {
        guard let kind = account.kind else { return account.name }
        return "\(accountDisplayName(account)) · \(kind.label)"
    }

    /// Removes the account from the setup list. Charges already brought in
    /// stay in recent transactions, and History is left alone.
    func deleteAccount(id: UUID) {
        let before = ledger.accounts.count
        ledger.accounts.removeAll { $0.id == id }
        if ledger.accounts.count != before { persist() }
    }

    /// What removing this account changes, one plain sentence each, for the
    /// confirmation before `deleteAccount`. Empty when the account is gone.
    func accountRemovalConsequences(id: UUID) -> [String] {
        guard let account = ledger.accounts.first(where: { $0.id == id }) else { return [] }
        var lines = ["\(accountDisplayName(account)) leaves the Accounts list, with its type"]
        if account.purpose != nil { lines[0] += ", what the loan is for" }
        if account.downloadURL != nil { lines[0] += ", and its download page link" }
        lines[0] += "."
        let count = charges(forAccount: id).count
        guard count > 0 else {
            lines.append("No transactions are tied to it, so nothing else changes.")
            return lines
        }
        let noun = count == 1 ? "transaction stays" : "transactions stay"
        let belongs = count == 1 ? "belongs" : "belong"
        lines.append("Its \(count) \(noun) in Recent transactions, History, Charts, and Reports, but no longer \(belongs) to any account.")
        lines.append("Charts and Reports can no longer show this account by itself. Its transactions count only under All accounts.")
        lines.append("Recent transactions stops offering to move its earlier months to History.")
        let files = ledger.files.filter { $0.accountID == id }
        if account.kind != .bank, files.contains(where: { $0.source != RanchOSFinanceDates.apple }) {
            lines.append("Charts read its statements the bank way afterward, so purchases would count as income.")
        }
        lines.append("Adding the account again makes a new account. These transactions do not reconnect to it.")
        lines.append("Statement files in its folder on T2 WD X are not deleted.")
        return lines
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

    func file(id: UUID) -> RanchOSFinanceFile? {
        ledger.files.first(where: { $0.id == id })
    }

    /// Names the account a file came from. Blank names are refused. Later
    /// charges in that file keep the new source.
    @discardableResult
    func setSource(fileID: UUID, source: String) -> Bool {
        guard let name = RanchOSFinanceDates.normalizedSource(source),
            let index = ledger.files.firstIndex(where: { $0.id == fileID })
        else {
            return false
        }
        ledger.files[index].source = name
        persist()
        return true
    }

    func dateRangeLabel(fileID: UUID) -> String {
        let dates = charges(fileID: fileID).compactMap { RanchOSFinanceDates.parse($0.dateText) }
        return RanchOSFinanceDates.rangeLabel(dates)
    }

    /// One row per account and calendar month that already has charges.
    /// Months sort oldest first inside each account.
    func monthsAlreadyIn() -> [RanchOSFinanceMonth] {
        var counts: [RanchOSFinanceMonth.Key: Int] = [:]
        for charge in ledger.charges {
            guard let date = RanchOSFinanceDates.parse(charge.dateText),
                let file = file(id: charge.fileID)
            else {
                continue
            }
            let parts = RanchOSFinanceDates.yearMonth(date)
            let key = RanchOSFinanceMonth.Key(
                source: file.source ?? RanchOSFinanceDates.missingSource,
                year: parts.year, month: parts.month)
            counts[key, default: 0] += 1
        }
        return counts.map { key, count in
            RanchOSFinanceMonth(
                source: key.source, year: key.year, month: key.month, chargeCount: count)
        }.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.year != $1.year { return $0.year < $1.year }
            return $0.month < $1.month
        }
    }

    func vendors(categoryID: UUID) -> [RanchOSFinanceVendor] {
        ledger.vendors.filter { $0.categoryID == categoryID }
    }

    /// Categories with the vendors assigned to each one. Uncategorized is
    /// first, then the rest by name. Vendors are by name. A blank query
    /// includes categories that have no vendors. A query keeps a category
    /// when its name matches, with every vendor, or when a vendor name
    /// matches, with only those vendors.
    func categoryVendorGroups(matching rawQuery: String) -> [RanchOSFinanceCategoryVendors] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let categories = ledger.categories.sorted { lhs, rhs in
            if lhs.isUncategorized != rhs.isUncategorized { return lhs.isUncategorized }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return categories.compactMap { category in
            let assigned = ledger.vendors
                .filter { $0.categoryID == category.id }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if query.isEmpty || category.name.localizedStandardContains(query) {
                return RanchOSFinanceCategoryVendors(category: category, vendors: assigned)
            }
            let matched = assigned.filter { $0.name.localizedStandardContains(query) }
            guard !matched.isEmpty else { return nil }
            return RanchOSFinanceCategoryVendors(category: category, vendors: matched)
        }
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
    func ingest(
        fileName: String, bytes: Data, now: Date = Date(), source: String? = nil, accountID: UUID? = nil
    ) -> (
        file: RanchOSFinanceFile, newVendors: [RanchOSFinanceVendor],
        principal: RanchOSFinancePrincipalOutcome?
    ) {
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes, now: now)
        if let existingIndex = ledger.files.firstIndex(where: { $0.sha256Hex == parsed.sha256Hex }) {
            var principal: RanchOSFinancePrincipalOutcome?
            if let accountID, ledger.files[existingIndex].accountID == nil {
                ledger.files[existingIndex].accountID = accountID
                if let name = RanchOSFinanceDates.normalizedSource(source) {
                    ledger.files[existingIndex].source = name
                }
                principal = principalOutcome(parsed: parsed, accountID: accountID)
                persist()
            }
            return (ledger.files[existingIndex], [], principal)
        }
        let file = RanchOSFinanceFile(
            id: UUID(), fileName: fileName, sha256Hex: parsed.sha256Hex,
            kind: parsed.kind.rawValue, rowCount: parsed.rowCount, ingestedAt: now,
            errors: parsed.errors.map {
                RanchOSFinanceFileError(row: $0.row, code: $0.code, message: $0.message)
            },
            source: RanchOSFinanceDates.normalizedSource(source),
            accountID: accountID)
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
        return (file, newVendors, principalOutcome(parsed: parsed, accountID: accountID))
    }

    /// A loan statement keeps its principal snapshot. Cards, banks, and
    /// unassigned files keep nothing. A loan file with no usable principal
    /// leaves the snapshots alone and reports missing.
    private func principalOutcome(
        parsed: RanchOSFinanceCSV.ParsedFile, accountID: UUID?
    ) -> RanchOSFinancePrincipalOutcome? {
        guard let accountID,
            ledger.accounts.first(where: { $0.id == accountID })?.kind == .loan
        else { return nil }
        guard let found = parsed.principal,
            let date = RanchOSFinanceCSV.parseDate(found.dateText),
            let amount = RanchOSFinanceCSV.parseAmount(found.amountText)
        else { return .missing }
        recordPrincipalSnapshot(accountID: accountID, date: date, amount: amount)
        return .recorded(date: RanchOSFinanceDates.startOfUTCDay(date), amount: amount)
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
        if namesUncategorized(trimmed) {
            return uncategorizedID
        }
        if let existing = ledger.categories.first(where: {
            $0.name.lowercased() == trimmed.lowercased()
        }) {
            return existing.id
        }
        return createCategory(name: trimmed)?.id
    }

    /// A blank category and the Apple value Other are Uncategorized. Other Loans
    /// stays its own category.
    private func isOtherCategoryName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "other"
    }

    private func namesUncategorized(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == RanchOSFinanceSuggestionLabels.uncategorized.lowercased() || isOtherCategoryName(name)
    }

    /// Categories already named Other become Uncategorized: vendors, individual
    /// assignments, saved chart filters, and History copies. Runs when a ledger opens.
    private func foldOtherIntoUncategorized() {
        guard let uncategorizedID else { return }
        let otherIDs = Set(ledger.categories.filter {
            !$0.isUncategorized && isOtherCategoryName($0.name)
        }.map(\.id))
        let historyNamesOther = ledger.archives.contains { archive in
            archive.charges.contains { charge in
                isOtherCategoryName(charge.categoryName)
                    || (charge.splitParts ?? []).contains { isOtherCategoryName($0.categoryName) }
            }
        }
        guard !otherIDs.isEmpty || historyNamesOther else { return }
        if !otherIDs.isEmpty {
            for index in ledger.vendors.indices where otherIDs.contains(ledger.vendors[index].categoryID) {
                ledger.vendors[index].categoryID = uncategorizedID
                ledger.vendors[index].suggestion = nil
            }
            for index in ledger.charges.indices {
                if let override = ledger.charges[index].categoryOverrideID, otherIDs.contains(override) {
                    ledger.charges[index].categoryOverrideID = uncategorizedID
                }
            }
            retargetSplitParts(from: otherIDs, to: uncategorizedID)
            for index in ledger.chartProfiles.indices {
                guard ledger.chartProfiles[index].categoryIDs.contains(where: { otherIDs.contains($0) }) else { continue }
                var ids = ledger.chartProfiles[index].categoryIDs.filter { !otherIDs.contains($0) }
                if !ids.contains(uncategorizedID) {
                    ids.append(uncategorizedID)
                }
                ledger.chartProfiles[index].categoryIDs = ids.sorted { $0.uuidString < $1.uuidString }
            }
            ledger.categories.removeAll { otherIDs.contains($0.id) }
        }
        rewriteHistoryCategory(named: "Other", to: RanchOSFinanceSuggestionLabels.uncategorized)
        persist()
    }

    /// Renames a category in History, split pieces included. Split pieces that
    /// land on the same name merge.
    private func rewriteHistoryCategory(named name: String, to replacement: String) {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ value: String) -> Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
        for archiveIndex in ledger.archives.indices {
            for chargeIndex in ledger.archives[archiveIndex].charges.indices {
                var charge = ledger.archives[archiveIndex].charges[chargeIndex]
                if matches(charge.categoryName) {
                    charge.categoryName = replacement
                }
                if let parts = charge.splitParts, parts.contains(where: { matches($0.categoryName) }) {
                    var merged: [RanchOSFinanceArchiveSplitPart] = []
                    for part in parts {
                        let partName = matches(part.categoryName) ? replacement : part.categoryName
                        if let existing = merged.firstIndex(where: { $0.categoryName == partName }) {
                            merged[existing].amount += part.amount
                        } else {
                            merged.append(RanchOSFinanceArchiveSplitPart(categoryName: partName, amount: part.amount))
                        }
                    }
                    if merged.count > 1 {
                        charge.splitParts = merged
                    } else {
                        charge.splitParts = nil
                        charge.categoryName = merged.first?.categoryName ?? replacement
                    }
                }
                ledger.archives[archiveIndex].charges[chargeIndex] = charge
            }
        }
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
        if trimmed.lowercased() == "other", let uncategorizedID {
            return category(id: uncategorizedID)
        }
        if ledger.categories.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return nil
        }
        let category = RanchOSFinanceCategory(id: UUID(), name: trimmed, isUncategorized: false)
        ledger.categories.append(category)
        persist()
        return category
    }

    /// Adds a category from one vendor and moves that vendor into it. A name
    /// already on the list is reused, so the vendor moves there and no second
    /// category is made. A refused name changes nothing.
    func addCategory(name: String, forVendor vendorID: UUID) -> (categoryID: UUID?, problem: String?) {
        guard vendor(id: vendorID) != nil else { return (nil, "That vendor is gone.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, "Type a name.") }
        if trimmed.count > 64 { return (nil, "Use 64 characters or fewer.") }
        if trimmed.lowercased() == "other" { return (nil, "Other is Uncategorized. Choose another name.") }
        let categoryID: UUID
        if let existing = ledger.categories.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            categoryID = existing.id
        } else if let created = createCategory(name: trimmed) {
            categoryID = created.id
        } else {
            return (nil, "Type a name.")
        }
        assign(vendorID: vendorID, categoryID: categoryID)
        return (categoryID, nil)
    }

    /// Renames a category in place. Identity stays: the id is unchanged and
    /// vendor assignments stay on it. History rows under the old name take the
    /// new name. A refused name leaves the previous name standing. No
    /// replacement category is created.
    @discardableResult
    func renameCategory(id: UUID, newName: String) -> Bool {
        guard let index = ledger.categories.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == ledger.categories[index].name { return true }
        guard categoryRenameProblem(id: id, newName: newName) == nil else { return false }
        let oldName = ledger.categories[index].name
        ledger.categories[index].name = trimmed
        rewriteHistoryCategory(named: oldName, to: trimmed)
        persist()
        return true
    }

    /// Why a rename is refused, or nil when it can go ahead.
    func categoryRenameProblem(id: UUID, newName: String) -> String? {
        guard let category = category(id: id) else { return "That category is gone." }
        if category.isUncategorized { return "Uncategorized keeps its name." }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Type a name." }
        if trimmed.count > 64 { return "Use 64 characters or fewer." }
        if trimmed == category.name { return nil }
        if isOtherCategoryName(trimmed) { return "Other is Uncategorized. Choose another name." }
        if ledger.categories.contains(where: {
            $0.id != id && $0.name.lowercased() == trimmed.lowercased()
        }) {
            return "\(trimmed) is already a category."
        }
        return nil
    }

    /// Deletes a category. Uncategorized cannot be deleted. Vendors, individual
    /// charge assignments, and History copies of this category move to
    /// Uncategorized. Nothing asks where they should go. Files are untouched.
    @discardableResult
    func deleteCategory(id: UUID) -> Bool {
        guard let category = category(id: id), !category.isUncategorized,
            let uncategorizedID
        else {
            return false
        }
        let removedName = category.name
        ledger.categories.removeAll(where: { $0.id == id })
        for index in ledger.vendors.indices where ledger.vendors[index].categoryID == id {
            ledger.vendors[index].categoryID = uncategorizedID
            ledger.vendors[index].suggestion = nil
        }
        for index in ledger.charges.indices where ledger.charges[index].categoryOverrideID == id {
            ledger.charges[index].categoryOverrideID = uncategorizedID
        }
        retargetSplitParts(from: [id], to: uncategorizedID)
        rewriteHistoryCategory(named: removedName, to: RanchOSFinanceSuggestionLabels.uncategorized)
        for index in ledger.chartProfiles.indices {
            ledger.chartProfiles[index].categoryIDs.removeAll { $0 == id }
        }
        persist()
        return true
    }

    /// Vendors with a transaction still on Recent, A to Z. Vendors seen only in
    /// History stay in the ledger with their category for the next import.
    func recentVendors() -> [RanchOSFinanceVendor] {
        let recentVendorIDs = Set(
            ledger.charges.filter { !isMovedToHistory($0) }.compactMap(\.vendorID))
        return ledger.vendors
            .filter { recentVendorIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Category shown for one charge. A split charge has none; use
    /// `splitParts(for:)`. An individual assignment wins next. Otherwise the
    /// charge follows its vendor. A dangling id falls through to the vendor.
    func categoryID(for charge: RanchOSFinanceCharge) -> UUID? {
        if isSplit(charge) { return nil }
        if let override = charge.categoryOverrideID, category(id: override) != nil {
            return override
        }
        if let vendorID = charge.vendorID, let vendor = vendor(id: vendorID) {
            return vendor.categoryID
        }
        return uncategorizedID
    }

    func categoryName(for charge: RanchOSFinanceCharge) -> String {
        if isSplit(charge) { return Self.splitLabel }
        guard let categoryID = categoryID(for: charge),
            let category = category(id: categoryID)
        else {
            return RanchOSFinanceSuggestionLabels.uncategorized
        }
        return category.name
    }

    func archive(fileID: UUID) -> RanchOSFinanceArchive? {
        ledger.archives.first { $0.fileID == fileID && $0.year == nil && $0.month == nil }
    }

    func importSpan(fileID: UUID) -> (earliest: Date, latest: Date)? {
        let dates = charges(fileID: fileID).compactMap { RanchOSFinanceDates.parse($0.dateText) }
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }
        return (earliest, latest)
    }

    /// Every month before an account's newest month, when that month still has
    /// charges and is not in History. A July 1 charge means June and earlier
    /// are ready. The newest month stays in Recent.
    func accountsReadyToArchive() -> [RanchOSFinanceArchiveOffer] {
        accountsByName.flatMap { account in
            let accountCharges = charges(forAccount: account.id)
            let dates = accountCharges.compactMap { RanchOSFinanceDates.parse($0.dateText) }
            let newest = dates.max().map { RanchOSFinanceDates.yearMonth($0) }
            let openLabel = newest.map { RanchOSFinanceDates.monthLabel(year: $0.year, month: $0.month) } ?? ""
            return RanchOSFinanceDates.closedMonths(from: dates).compactMap { previous in
                offer(
                    account: account, charges: accountCharges, year: previous.year, month: previous.month,
                    openLabel: openLabel)
            }
        }
    }

    private func offer(
        account: RanchOSFinanceAccount, charges: [RanchOSFinanceCharge], year: Int, month: Int, openLabel: String
    ) -> RanchOSFinanceArchiveOffer? {
        let monthCharges = charges.filter { charge in
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
            let parts = RanchOSFinanceDates.yearMonth(date)
            return parts.year == year && parts.month == month
        }
        let fileIDs = Set(monthCharges.map(\.fileID))
        let pendingFileIDs = fileIDs.filter { fileID in
            !ledger.archives.contains { archive in
                archive.fileID == fileID && archive.year == year && archive.month == month
            }
        }.sorted { $0.uuidString < $1.uuidString }
        guard !pendingFileIDs.isEmpty else { return nil }
        let monthDates = monthCharges.compactMap { RanchOSFinanceDates.parse($0.dateText) }
        guard let earliest = monthDates.min(), let latest = monthDates.max() else { return nil }
        return RanchOSFinanceArchiveOffer(
            accountID: account.id, accountName: accountDisplayName(account), fileIDs: pendingFileIDs,
            month: RanchOSFinanceReadyMonth(year: year, month: month),
            openMonthLabel: openLabel, earliest: earliest, latest: latest)
    }

    func archiveDaySpan(_ archive: RanchOSFinanceArchive) -> String {
        RanchOSFinanceDates.daySpan(archive.charges.compactMap { RanchOSFinanceDates.parse($0.dateText) })
    }

    /// Puts each closed month into History with the category each charge has
    /// now. Recent then omits that month. Later months stay in Recent. A
    /// whole-statement archive is left alone. The charges stay in the ledger
    /// so charts can still use them.
    func archiveMonths(
        fileID: UUID, months: [RanchOSFinanceReadyMonth], now: Date = Date()
    ) -> [RanchOSFinanceArchive] {
        guard let file = file(id: fileID) else { return [] }
        var records: [RanchOSFinanceArchive] = []
        for month in months {
            let snapshots = charges(fileID: fileID, year: month.year, month: month.month).map(archiveSnapshot)
            guard !snapshots.isEmpty else { continue }
            let span = RanchOSFinanceDates.daySpan(snapshots.compactMap { RanchOSFinanceDates.parse($0.dateText) })
            var record = ledger.archives.first {
                $0.fileID == fileID && $0.year == month.year && $0.month == month.month
            } ?? RanchOSFinanceArchive(
                id: UUID(), fileID: fileID, fileName: file.fileName,
                source: file.source ?? RanchOSFinanceDates.missingSource,
                rangeLabel: span, archivedAt: now, charges: snapshots,
                year: month.year, month: month.month)
            record.fileName = file.fileName
            record.source = file.source ?? RanchOSFinanceDates.missingSource
            record.rangeLabel = span
            record.archivedAt = now
            record.charges = snapshots
            record.year = month.year
            record.month = month.month
            ledger.archives.removeAll { $0.fileID == fileID && $0.year == month.year && $0.month == month.month }
            ledger.archives.insert(record, at: 0)
            records.append(record)
        }
        if !records.isEmpty { persist() }
        return records
    }

    private func charges(fileID: UUID, year: Int, month: Int) -> [RanchOSFinanceCharge] {
        charges(fileID: fileID).filter { charge in
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
            let parts = RanchOSFinanceDates.yearMonth(date)
            return parts.year == year && parts.month == month
        }
    }

    /// History, grouped by account. Every account is listed, including one
    /// that has nothing archived yet. Apple’s June archive is the June row
    /// under Apple.
    func historyGroups() -> [RanchOSFinanceHistoryGroup] {
        var byAccount: [UUID: [RanchOSFinanceArchive]] = [:]
        var loose: [String: [RanchOSFinanceArchive]] = [:]
        for archive in ledger.archives {
            if let file = file(id: archive.fileID),
                let accountID = file.accountID,
                ledger.accounts.contains(where: { $0.id == accountID })
            {
                byAccount[accountID, default: []].append(archive)
            } else {
                loose[archive.source, default: []].append(archive)
            }
        }
        let accounts = accountsByName.map { account in
            RanchOSFinanceHistoryGroup(
                account: historyTitle(account),
                archives: sortedHistory(byAccount[account.id] ?? []),
                id: account.id.uuidString)
        }
        let sources = loose.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { source in
            RanchOSFinanceHistoryGroup(
                account: source,
                archives: sortedHistory(loose[source] ?? []),
                id: "source:\(source)")
        }
        return accounts + sources
    }

    private func historyTitle(_ account: RanchOSFinanceAccount) -> String {
        let sharesName = ledger.accounts.contains { other in
            other.id != account.id
                && other.name.localizedCaseInsensitiveCompare(account.name) == .orderedSame
        }
        return sharesName ? accountLabel(account) : account.name
    }

    private func sortedHistory(_ archives: [RanchOSFinanceArchive]) -> [RanchOSFinanceArchive] {
        archives.sorted { lhs, rhs in
            let left = (lhs.year ?? 0, lhs.month ?? 0)
            let right = (rhs.year ?? 0, rhs.month ?? 0)
            if left != right { return left > right }
            return lhs.rangeLabel.localizedStandardCompare(rhs.rangeLabel) == .orderedAscending
        }
    }

    /// Freezes this statement into history: source, date range, and the
    /// category on each charge right now. A later assignment does not change
    /// the history until he archives the statement again.
    @discardableResult
    func archiveStatement(fileID: UUID, now: Date = Date()) -> RanchOSFinanceArchive? {
        guard let file = file(id: fileID) else { return nil }
        let snapshots = charges(fileID: fileID).map(archiveSnapshot)
        var record = archive(fileID: fileID) ?? RanchOSFinanceArchive(
            id: UUID(), fileID: fileID, fileName: file.fileName,
            source: file.source ?? RanchOSFinanceDates.missingSource,
            rangeLabel: dateRangeLabel(fileID: fileID), archivedAt: now, charges: snapshots)
        record.fileName = file.fileName
        record.source = file.source ?? RanchOSFinanceDates.missingSource
        record.rangeLabel = dateRangeLabel(fileID: fileID)
        record.archivedAt = now
        record.charges = snapshots
        ledger.archives.removeAll { $0.fileID == fileID && $0.year == nil && $0.month == nil }
        ledger.archives.insert(record, at: 0)
        persist()
        return record
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
    /// rule again. A split on one of these charges ends.
    func assign(chargeIDs: Set<UUID>, categoryID: UUID) {
        guard category(id: categoryID) != nil else { return }
        var changed = false
        for index in ledger.charges.indices where chargeIDs.contains(ledger.charges[index].id) {
            if ledger.charges[index].splitParts != nil {
                ledger.charges[index].splitParts = nil
                changed = true
            }
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

    /// Applies a category to one charge. `currentImport` also updates every
    /// imported charge from the same supplier. `history` updates History lines
    /// for that supplier. The answers are independent, and a later import is
    /// left on the supplier's existing category. Other split transactions
    /// from the supplier keep their split, now and in History.
    func applyAssignment(
        chargeID: UUID, categoryID: UUID, currentImport: Bool, history: Bool
    ) {
        guard let charge = ledger.charges.first(where: { $0.id == chargeID }),
            let category = category(id: categoryID)
        else { return }
        var ids: Set<UUID> = [chargeID]
        if currentImport {
            let splitIDs = Set(ledger.charges.filter(isSplit).map(\.id))
            ids.formUnion(importedChargeIDs(matching: charge).subtracting(splitIDs))
        }
        assign(chargeIDs: ids, categoryID: categoryID)
        guard history else { return }
        let key = Self.vendorKey(charge.merchantText)
        guard !key.isEmpty else { return }
        var changed = false
        for archiveIndex in ledger.archives.indices {
            for chargeIndex in ledger.archives[archiveIndex].charges.indices
                where Self.vendorKey(ledger.archives[archiveIndex].charges[chargeIndex].merchantText) == key
                    && ledger.archives[archiveIndex].charges[chargeIndex].splitParts == nil
            {
                if ledger.archives[archiveIndex].charges[chargeIndex].categoryName != category.name {
                    ledger.archives[archiveIndex].charges[chargeIndex].categoryName = category.name
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    private func importedChargeIDs(matching charge: RanchOSFinanceCharge) -> Set<UUID> {
        if let vendorID = charge.vendorID {
            return Set(ledger.charges.filter { $0.vendorID == vendorID }.map(\.id))
        }
        let key = Self.vendorKey(charge.merchantText)
        guard !key.isEmpty else { return [charge.id] }
        return Set(ledger.charges.filter { Self.vendorKey($0.merchantText) == key }.map(\.id))
    }

    /// Applies a category to every charge from this supplier, now and later.
    /// Individual charge assignments for the supplier are cleared so they
    /// follow it. A later file from the same supplier keeps this category.
    func assignEveryCharge(vendorID: UUID, categoryID: UUID) {
        guard category(id: categoryID) != nil,
            ledger.vendors.contains(where: { $0.id == vendorID })
        else {
            return
        }
        assign(vendorID: vendorID, categoryID: categoryID)
        var cleared = false
        for index in ledger.charges.indices where ledger.charges[index].vendorID == vendorID {
            if ledger.charges[index].categoryOverrideID != nil {
                ledger.charges[index].categoryOverrideID = nil
                cleared = true
            }
        }
        if cleared { persist() }
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
        chartCache.clear()
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

// MARK: - Split transactions

extension RanchOSFinanceStore {
    static let splitLabel = "Split"

    func isSplit(_ charge: RanchOSFinanceCharge) -> Bool {
        (charge.splitParts?.count ?? 0) > 1
    }

    /// The pieces of a split charge. A piece whose category is gone counts as
    /// Uncategorized. Empty when the charge is not split.
    func splitParts(for charge: RanchOSFinanceCharge) -> [RanchOSFinanceSplitPart] {
        guard isSplit(charge), let parts = charge.splitParts else { return [] }
        return parts.map { part in
            guard category(id: part.categoryID) == nil, let uncategorizedID else { return part }
            var moved = part
            moved.categoryID = uncategorizedID
            return moved
        }
    }

    /// Why these pieces cannot be the split, or nil when they can. Two or more
    /// pieces, each category once, each above zero, adding up to the amount.
    func splitProblem(chargeID: UUID, parts: [(categoryID: UUID, amount: Decimal)]) -> String? {
        guard let charge = ledger.charges.first(where: { $0.id == chargeID }) else {
            return "That transaction is no longer listed."
        }
        if parts.count < 2 { return "A split needs at least two categories." }
        if parts.contains(where: { category(id: $0.categoryID) == nil }) {
            return "Choose a category for every piece."
        }
        if Set(parts.map(\.categoryID)).count != parts.count {
            return "Use each category once."
        }
        if parts.contains(where: { RanchOSFinanceMoney.roundedCents($0.amount) <= 0 }) {
            return "Every piece needs an amount above zero."
        }
        let total = allocatableAmount(charge: charge)
        let entered = parts.reduce(Decimal(0)) { $0 + RanchOSFinanceMoney.roundedCents($1.amount) }
        if entered != total {
            let gap = total - entered
            return gap > 0
                ? "\(RanchOSFinanceMoney.format(gap)) is still unassigned."
                : "The pieces are \(RanchOSFinanceMoney.format(-gap)) over the transaction."
        }
        return nil
    }

    /// Splits one charge across categories. The vendor rule is not changed.
    /// A refused split leaves the charge as it was.
    @discardableResult
    func splitCharge(chargeID: UUID, parts: [(categoryID: UUID, amount: Decimal)]) -> Bool {
        guard splitProblem(chargeID: chargeID, parts: parts) == nil,
            let index = ledger.charges.firstIndex(where: { $0.id == chargeID })
        else { return false }
        ledger.charges[index].splitParts = parts.map {
            RanchOSFinanceSplitPart(
                id: UUID(), categoryID: $0.categoryID, amount: RanchOSFinanceMoney.roundedCents($0.amount))
        }
        ledger.charges[index].categoryOverrideID = nil
        persist()
        return true
    }

    /// Ends a split. The charge follows its vendor's category again.
    func removeSplit(chargeID: UUID) {
        guard let index = ledger.charges.firstIndex(where: { $0.id == chargeID }),
            ledger.charges[index].splitParts != nil
        else { return }
        ledger.charges[index].splitParts = nil
        persist()
    }

    /// The History copy of one charge, split pieces included.
    func archiveSnapshot(_ charge: RanchOSFinanceCharge) -> RanchOSFinanceArchiveCharge {
        let parts = splitParts(for: charge).map { part in
            RanchOSFinanceArchiveSplitPart(
                categoryName: category(id: part.categoryID)?.name ?? RanchOSFinanceSuggestionLabels.uncategorized,
                amount: part.amount)
        }
        return RanchOSFinanceArchiveCharge(
            id: charge.id,
            dateText: charge.dateText,
            merchantText: charge.merchantText,
            amountText: charge.amountText,
            categoryName: categoryName(for: charge),
            splitParts: parts.isEmpty ? nil : parts)
    }

    /// Points split pieces in the removed categories at another one. Pieces
    /// that land in the same category merge; one piece left ends the split and
    /// keeps that category on the charge alone.
    func retargetSplitParts(from removed: Set<UUID>, to replacement: UUID) {
        for index in ledger.charges.indices {
            guard let parts = ledger.charges[index].splitParts,
                parts.contains(where: { removed.contains($0.categoryID) })
            else { continue }
            var merged: [RanchOSFinanceSplitPart] = []
            for part in parts {
                let target = removed.contains(part.categoryID) ? replacement : part.categoryID
                if let existing = merged.firstIndex(where: { $0.categoryID == target }) {
                    merged[existing].amount += part.amount
                } else {
                    merged.append(RanchOSFinanceSplitPart(id: part.id, categoryID: target, amount: part.amount))
                }
            }
            if merged.count > 1 {
                ledger.charges[index].splitParts = merged
            } else {
                ledger.charges[index].splitParts = nil
                ledger.charges[index].categoryOverrideID = merged.first?.categoryID
            }
        }
    }
}
