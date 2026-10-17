import Foundation

/// Cost by thing: a charge connects to equipment, a property asset, a ranch
/// operation, or the household through one or more uses. Finance stores a
/// typed link and the allocated amount — it does not own the records.
/// Property Manager owns assets and equipment, Livestock owns herds and
/// animals. Operations are Finance-local names; household is one bucket.
/// He enters every fact (target, gallons, price, amount); nothing here is
/// guessed, and a suggestion is never an accounting entry.
enum RanchOSFinanceTargetKind: String, Codable, Sendable, CaseIterable {
    case equipment
    case propertyAsset
    case operation
    case household

    var label: String {
        switch self {
        case .equipment: "Equipment"
        case .propertyAsset: "Property asset"
        case .operation: "Operation"
        case .household: "Household"
        }
    }
}

/// One allocation of charge money to a target. Fuel uses carry the entered
/// gallons and price per gallon; amount is gallons times price, rounded to
/// cents. Exact uses carry the entered dollar amount.
struct RanchOSFinanceUse: Codable, Identifiable, Sendable {
    var id: UUID
    var chargeID: UUID
    var kind: RanchOSFinanceTargetKind
    /// Owning system's key: equipment or asset id, operation UUID string,
    /// or "household".
    var recordID: String
    /// Display snapshot taken when the use is added.
    var name: String
    var amount: Decimal
    var gallons: Decimal?
    var pricePerGallon: Decimal?

    var isFuel: Bool { gallons != nil && pricePerGallon != nil }
}

/// Finance-local operation names (mowing, fence repair). The id is the
/// link key; the name is snapshotted onto each use.
struct RanchOSFinanceOperation: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
}

struct RanchOSFinanceTargetTotal: Sendable, Identifiable {
    var kind: RanchOSFinanceTargetKind
    var recordID: String
    var name: String
    var total: Decimal

    var id: String { kind.rawValue + ":" + recordID }
}

enum RanchOSFinanceMoney {
    static let householdRecordID = "household"
    static let householdName = "Household"

    static func roundedCents(_ value: Decimal) -> Decimal {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        return rounded
    }

    /// "$12.34" for display. Amounts are non-negative by construction.
    static func format(_ amount: Decimal) -> String {
        let cents = NSDecimalNumber(decimal: roundedCents(amount)).multiplying(byPowerOf10: 2).intValue
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return sign + "$\(absolute / 100).\(String(format: "%02d", absolute % 100))"
    }
}

extension RanchOSFinanceStore {
    // MARK: - Allocation math

    /// What a charge can allocate: the magnitude of its amount, rounded to
    /// cents. Direction (in or out) is the statement's business; allocation
    /// splits the size. Unparseable amounts allocate nothing.
    func allocatableAmount(charge: RanchOSFinanceCharge) -> Decimal {
        guard let amount = RanchOSFinanceCSV.parseAmount(charge.amountText) else { return 0 }
        return RanchOSFinanceMoney.roundedCents(amount < 0 ? -amount : amount)
    }

    func uses(chargeID: UUID) -> [RanchOSFinanceUse] {
        ledger.uses.filter { $0.chargeID == chargeID }
    }

    func allocatedAmount(chargeID: UUID) -> Decimal {
        uses(chargeID: chargeID).reduce(0) { $0 + $1.amount }
    }

    /// Money on the charge with no use yet. The remainder stays unallocated;
    /// it is never treated as household.
    func unallocatedAmount(chargeID: UUID) -> Decimal {
        guard let charge = ledger.charges.first(where: { $0.id == chargeID }) else { return 0 }
        return allocatableAmount(charge: charge) - allocatedAmount(chargeID: chargeID)
    }

    func chargesWithUnallocated() -> [RanchOSFinanceCharge] {
        ledger.charges.filter { unallocatedAmount(chargeID: $0.id) > 0 }
    }

    // MARK: - Adding and removing uses

    /// Adds an exact-dollar use. Fails when the charge or target is unknown,
    /// the amount is not positive, or the uses would exceed the charge.
    @discardableResult
    func addExactUse(
        chargeID: UUID, kind: RanchOSFinanceTargetKind, recordID: String, amount: Decimal
    ) -> RanchOSFinanceUse? {
        guard ledger.charges.contains(where: { $0.id == chargeID }) else { return nil }
        let rounded = RanchOSFinanceMoney.roundedCents(amount)
        guard rounded > 0 else { return nil }
        guard let name = targetName(kind: kind, recordID: recordID) else { return nil }
        guard let charge = ledger.charges.first(where: { $0.id == chargeID }),
            allocatedAmount(chargeID: chargeID) + rounded <= allocatableAmount(charge: charge)
        else {
            return nil
        }
        let use = RanchOSFinanceUse(
            id: UUID(), chargeID: chargeID, kind: kind, recordID: recordID, name: name,
            amount: rounded, gallons: nil, pricePerGallon: nil)
        mutateLedger { $0.uses.append(use) }
        return use
    }

    /// Adds a fuel use: the equipment, the entered gallons and price per
    /// gallon. Allocated cost is gallons times price, rounded to cents.
    /// Fails on unknown equipment, non-positive facts, or over the charge.
    @discardableResult
    func addFuelUse(
        chargeID: UUID, equipmentRecordID: String, gallons: Decimal, pricePerGallon: Decimal
    ) -> RanchOSFinanceUse? {
        guard gallons > 0, pricePerGallon > 0 else { return nil }
        let amount = RanchOSFinanceMoney.roundedCents(gallons * pricePerGallon)
        guard amount > 0 else { return nil }
        guard let charge = ledger.charges.first(where: { $0.id == chargeID }),
            let name = targetName(kind: .equipment, recordID: equipmentRecordID),
            allocatedAmount(chargeID: chargeID) + amount <= allocatableAmount(charge: charge)
        else {
            return nil
        }
        let use = RanchOSFinanceUse(
            id: UUID(), chargeID: chargeID, kind: .equipment, recordID: equipmentRecordID,
            name: name, amount: amount, gallons: gallons, pricePerGallon: pricePerGallon)
        mutateLedger { $0.uses.append(use) }
        return use
    }

    func removeUse(id: UUID) {
        mutateLedger { $0.uses.removeAll(where: { $0.id == id }) }
    }

    // MARK: - Operations (Finance-local names)

    @discardableResult
    func createOperation(name: String) -> RanchOSFinanceOperation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        if ledger.operations.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return nil
        }
        let operation = RanchOSFinanceOperation(id: UUID(), name: trimmed)
        mutateLedger { $0.operations.append(operation) }
        return operation
    }

    func operation(id: UUID) -> RanchOSFinanceOperation? {
        ledger.operations.first(where: { $0.id == id })
    }

    // MARK: - Cost screen

    /// Each target with the sum of amounts linked to it, by name.
    func costByTarget() -> [RanchOSFinanceTargetTotal] {
        var totals: [String: RanchOSFinanceTargetTotal] = [:]
        for use in ledger.uses {
            let key = use.kind.rawValue + ":" + use.recordID
            if var existing = totals[key] {
                existing.total += use.amount
                totals[key] = existing
            } else {
                totals[key] = RanchOSFinanceTargetTotal(
                    kind: use.kind, recordID: use.recordID, name: use.name, total: use.amount)
            }
        }
        return totals.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Target resolution (fail closed)

    /// Display name for a link target, or nil when the target is unknown.
    /// Equipment and assets resolve against the property registries; the
    /// store never invents those records.
    func targetName(kind: RanchOSFinanceTargetKind, recordID: String) -> String? {
        switch kind {
        case .equipment:
            return RanchOSPropertyEquipment(rawValue: recordID)?.title
        case .propertyAsset:
            return RanchOSPropertyAsset(rawValue: recordID)?.title
        case .operation:
            guard let id = UUID(uuidString: recordID) else { return nil }
            return operation(id: id)?.name
        case .household:
            return recordID == RanchOSFinanceMoney.householdRecordID
                ? RanchOSFinanceMoney.householdName : nil
        }
    }
}

enum RanchOSFinanceChartAccountFilter: Hashable, Sendable {
    case all
    case account(UUID)
    case unassigned
}

enum RanchOSFinanceChartTime: String, CaseIterable, Hashable, Sendable {
    case allDates
    case daily
    case week
    case month
    case semiannual
    case annual
    case samePeriodLastYear

    var label: String {
        switch self {
        case .allDates: "All dates"
        case .daily: "Daily"
        case .week: "By week"
        case .month: "By month"
        case .semiannual: "Semi-annual"
        case .annual: "Annual"
        case .samePeriodLastYear: "Same period last year"
        }
    }
}

/// One day, week, month, or year on a time chart. The total is the selected categories.
struct RanchOSFinancePeriodBar: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var shortLabel: String
    var total: Decimal
    var start: Date
    var end: Date
}

/// One period in value order. `inEighty` stays true through the period that
/// carries the running total to 80 percent.
struct RanchOSFinanceTrendBar: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var total: Decimal
    var cumulative: Decimal
    var inEighty: Bool
}

/// One vendor inside a drilled category. A charge with no vendor is
/// "No vendor" with a nil id.
struct RanchOSFinanceVendorBar: Identifiable, Equatable, Sendable {
    var vendorID: UUID?
    var name: String
    var total: Decimal
    var id: String { vendorID?.uuidString ?? "none" }
}

enum RanchOSFinanceChartMoney: String, CaseIterable, Sendable {
    case expenses
    case income

    var label: String {
        switch self {
        case .expenses: "Expenses"
        case .income: "Income"
        }
    }
}

struct RanchOSFinanceChartWindow: Equatable, Sendable {
    var start: Date
    var end: Date
}

struct RanchOSFinanceChartQuery: Equatable, Sendable {
    var account: RanchOSFinanceChartAccountFilter
    var categoryIDs: Set<UUID>
    var year: Int?
    var month: Int?
    var money: RanchOSFinanceChartMoney
    /// Inclusive day window. When both are set, they take the place of year and month.
    var start: Date? = nil
    var end: Date? = nil
    /// When true, an empty category set charts nothing. When false, an empty set means every category.
    var limitsCategories: Bool = false

    static let allExpenses = RanchOSFinanceChartQuery(
        account: .all, categoryIDs: [], year: nil, month: nil, money: .expenses)
}

struct RanchOSFinanceCategoryCompare: Identifiable, Equatable, Sendable {
    var categoryID: UUID
    var name: String
    var total: Decimal
    var priorTotal: Decimal
    var id: UUID { categoryID }
}

struct RanchOSFinanceWeekCompare: Identifiable, Equatable, Sendable {
    var week: Int
    var title: String
    var total: Decimal
    var priorTotal: Decimal
    var id: Int { week }
}

/// This period beside the same dates one year earlier.
struct RanchOSFinancePeriodCompare: Equatable, Sendable {
    var currentLabel: String
    var priorLabel: String
    var categories: [RanchOSFinanceCategoryCompare]
    var weeks: [RanchOSFinanceWeekCompare]
}

struct RanchOSFinanceCategoryBar: Identifiable, Equatable, Sendable {
    var categoryID: UUID
    var name: String
    var total: Decimal
    var id: UUID { categoryID }
}

struct RanchOSFinanceWeekBar: Identifiable, Equatable, Sendable {
    var week: Int
    var title: String
    var total: Decimal
    var id: Int { week }
}

/// One category in value order. `inEighty` is true through the category that
/// carries the running total to 80 percent.
struct RanchOSFinanceParetoBar: Identifiable, Equatable, Sendable {
    var categoryID: UUID
    var name: String
    var total: Decimal
    var cumulative: Decimal
    var inEighty: Bool
    var id: UUID { categoryID }
}

enum RanchOSFinancePareto {
    static func bars(from totals: [RanchOSFinanceCategoryBar]) -> [RanchOSFinanceParetoBar] {
        let ranked = totals.filter { $0.total > 0 }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return zip(ranked, flagEighty(ranked.map(\.total))).map { bar, mark in
            RanchOSFinanceParetoBar(
                categoryID: bar.categoryID, name: bar.name, total: bar.total,
                cumulative: mark.cumulative, inEighty: mark.inEighty)
        }
    }

    /// Periods in value order. A tie keeps the earlier period first.
    static func trend(from bars: [RanchOSFinancePeriodBar]) -> [RanchOSFinanceTrendBar] {
        let ranked = bars.filter { $0.total > 0 }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.start < rhs.start
        }
        return zip(ranked, flagEighty(ranked.map(\.total))).map { bar, mark in
            RanchOSFinanceTrendBar(
                id: bar.id, name: bar.label, total: bar.total,
                cumulative: mark.cumulative, inEighty: mark.inEighty)
        }
    }

    /// Vendors in value order. A tie goes A to Z.
    static func vendors(from bars: [RanchOSFinanceVendorBar]) -> [RanchOSFinanceTrendBar] {
        let ranked = bars.filter { $0.total > 0 }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return zip(ranked, flagEighty(ranked.map(\.total))).map { bar, mark in
            RanchOSFinanceTrendBar(
                id: bar.id, name: bar.name, total: bar.total,
                cumulative: mark.cumulative, inEighty: mark.inEighty)
        }
    }

    private static func flagEighty(_ totals: [Decimal]) -> [(cumulative: Decimal, inEighty: Bool)] {
        let sum = totals.reduce(Decimal(0)) { $0 + $1 }
        guard sum > 0 else { return [] }
        var running = Decimal(0)
        var reached = false
        return totals.map { total in
            let include = !reached
            running += total
            if include && running * 5 >= sum * 4 {
                reached = true
            }
            return (running, include)
        }
    }

    static func percentText(_ part: Decimal, of whole: Decimal) -> String {
        guard whole > 0 else { return "0%" }
        var percent = (part / whole) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &percent, 0, .plain)
        return "\(NSDecimalNumber(decimal: rounded).intValue)%"
    }
}

extension RanchOSFinanceStore {
    /// Months that have charges for this account filter, oldest first.
    func chartMonths(account: RanchOSFinanceChartAccountFilter) -> [RanchOSFinanceReadyMonth] {
        var seen: [String: RanchOSFinanceReadyMonth] = [:]
        for charge in ledger.charges where chargeMatches(charge, account: account) {
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { continue }
            let parts = RanchOSFinanceDates.yearMonth(date)
            let month = RanchOSFinanceReadyMonth(year: parts.year, month: parts.month)
            seen[month.id] = month
        }
        return seen.values.sorted { lhs, rhs in
            (lhs.year, lhs.month) < (rhs.year, rhs.month)
        }
    }

    /// Years that have charges for this account filter, newest first.
    func chartYears(account: RanchOSFinanceChartAccountFilter) -> [Int] {
        var years = Set<Int>()
        for charge in ledger.charges where chargeMatches(charge, account: account) {
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { continue }
            years.insert(RanchOSFinanceDates.yearMonth(date).year)
        }
        return years.sorted(by: >)
    }

    /// The full set of periods for a time choice. By week is 52 weeks of the
    /// year. By month is 12 months. Semi-annual is the six months of that half.
    /// Daily is every day of the month. Annual is each year from the earliest
    /// charge through the latest. Totals use the query's categories.
    func periodBars(
        time: RanchOSFinanceChartTime,
        year: Int,
        month: Int,
        half: Int,
        query: RanchOSFinanceChartQuery
    ) -> [RanchOSFinancePeriodBar] {
        if let cached = chartCache.periodBars,
            cached.0 == time, cached.1 == year, cached.2 == month, cached.3 == half, cached.4 == query
        {
            return cached.5
        }
        let bars = makePeriodBars(time: time, year: year, month: month, half: half, query: query)
        chartCache.periodBars = (time, year, month, half, query, bars)
        return bars
    }

    private func makePeriodBars(
        time: RanchOSFinanceChartTime,
        year: Int,
        month: Int,
        half: Int,
        query: RanchOSFinanceChartQuery
    ) -> [RanchOSFinancePeriodBar] {
        let templates: [RanchOSFinancePeriodBar]
        switch time {
        case .daily:
            templates = dayTemplates(year: year, month: month)
        case .week:
            templates = weekTemplates(year: year)
        case .month:
            templates = monthTemplates(year: year, months: Array(1...12))
        case .semiannual:
            let months = half == 2 ? Array(7...12) : Array(1...6)
            templates = monthTemplates(year: year, months: months)
        case .annual:
            templates = yearTemplates(account: query.account)
        case .allDates, .samePeriodLastYear:
            return []
        }
        return fill(templates, query: query)
    }

    private func dayTemplates(year: Int, month: Int) -> [RanchOSFinancePeriodBar] {
        let last = RanchOSFinanceDates.lastDay(year: year, month: month)
        return (1...last).compactMap { day in
            guard let date = RanchOSFinanceDates.utcDate(year: year, month: month, day: day) else { return nil }
            return RanchOSFinancePeriodBar(
                id: String(format: "%04d-%02d-%02d", year, month, day),
                label: RanchOSFinanceDates.display(date),
                shortLabel: "\(day)",
                total: 0, start: date, end: date)
        }
    }

    private func weekTemplates(year: Int) -> [RanchOSFinancePeriodBar] {
        (1...52).compactMap { week in
            guard let bounds = RanchOSFinanceDates.weekOfYearBounds(year: year, week: week) else { return nil }
            return RanchOSFinancePeriodBar(
                id: String(format: "%04d-W%02d", year, week),
                label: RanchOSFinanceDates.weekOfYearLabel(year: year, week: week),
                shortLabel: "W\(week)",
                total: 0, start: bounds.start, end: bounds.end)
        }
    }

    private func monthTemplates(year: Int, months: [Int]) -> [RanchOSFinancePeriodBar] {
        months.compactMap { month in
            guard
                let start = RanchOSFinanceDates.utcDate(year: year, month: month, day: 1),
                let end = RanchOSFinanceDates.utcDate(
                    year: year, month: month, day: RanchOSFinanceDates.lastDay(year: year, month: month))
            else { return nil }
            return RanchOSFinancePeriodBar(
                id: String(format: "%04d-%02d", year, month),
                label: RanchOSFinanceDates.monthLabel(year: year, month: month),
                shortLabel: RanchOSFinanceDates.shortMonth(month),
                total: 0, start: start, end: end)
        }
    }

    private func yearTemplates(account: RanchOSFinanceChartAccountFilter) -> [RanchOSFinancePeriodBar] {
        let years = chartYears(account: account)
        guard let newest = years.first, let oldest = years.last else { return [] }
        return (oldest...newest).compactMap { year in
            guard
                let start = RanchOSFinanceDates.utcDate(year: year, month: 1, day: 1),
                let end = RanchOSFinanceDates.utcDate(year: year, month: 12, day: 31)
            else { return nil }
            return RanchOSFinancePeriodBar(
                id: "\(year)", label: "\(year)", shortLabel: "\(year)",
                total: 0, start: start, end: end)
        }
    }

    private func fill(
        _ templates: [RanchOSFinancePeriodBar], query: RanchOSFinanceChartQuery
    ) -> [RanchOSFinancePeriodBar] {
        guard let first = templates.first, let last = templates.last else { return [] }
        var scoped = query
        scoped.year = nil
        scoped.month = nil
        scoped.start = first.start
        scoped.end = last.end
        var totals: [String: Decimal] = [:]
        for charge in chartCharges(scoped) {
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { continue }
            guard let match = templates.first(where: { date >= $0.start && date <= $0.end }) else { continue }
            let value = chartTotal(charge, query: query)
            guard value > 0 else { continue }
            totals[match.id, default: 0] += value
        }
        return templates.map { bar in
            var copy = bar
            copy.total = RanchOSFinanceMoney.roundedCents(totals[bar.id] ?? 0)
            return copy
        }
    }

    /// Earliest and latest charge included by this query. An empty window list
    /// covers no charges. Windows replace the query's own date limits.
    func chartDateSpan(
        _ query: RanchOSFinanceChartQuery,
        windows: [(start: Date, end: Date)]? = nil
    ) -> (start: Date, end: Date)? {
        if let windows, windows.isEmpty { return nil }
        var open = query
        if windows != nil {
            open.start = nil
            open.end = nil
            open.year = nil
            open.month = nil
        }
        var earliest: Date?
        var latest: Date?
        for charge in chartCharges(open) {
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { continue }
            if let windows, !windows.contains(where: { date >= $0.start && date <= $0.end }) {
                continue
            }
            if earliest == nil || date < earliest! {
                earliest = date
            }
            if latest == nil || date > latest! {
                latest = date
            }
        }
        guard let earliest, let latest else { return nil }
        return (earliest, latest)
    }

    /// Charge dates inside this period and inside the same dates last year.
    func chartComparisonSpans(
        _ query: RanchOSFinanceChartQuery
    ) -> (current: (start: Date, end: Date)?, prior: (start: Date, end: Date)?) {
        let windows = comparisonWindows(for: query)
        return (chartDateSpan(windows.current), chartDateSpan(windows.prior))
    }

    /// One column per category. An empty category filter means every category,
    /// unless the query limits categories, in which case an empty set charts
    /// nothing. A category with no matching transactions is zero. Duplicate
    /// rows are left out so the same charge is not counted twice.
    func categoryTotals(_ query: RanchOSFinanceChartQuery) -> [RanchOSFinanceCategoryBar] {
        if let cached = chartCache.categoryTotals, cached.0 == query { return cached.1 }
        let bars = makeCategoryTotals(query)
        chartCache.categoryTotals = (query, bars)
        return bars
    }

    private func makeCategoryTotals(_ query: RanchOSFinanceChartQuery) -> [RanchOSFinanceCategoryBar] {
        let categories = query.limitsCategories || !query.categoryIDs.isEmpty
            ? ledger.categories.filter { query.categoryIDs.contains($0.id) }
            : ledger.categories
        var totals: [UUID: Decimal] = [:]
        for charge in chartCharges(query) {
            for amount in chartAmounts(charge, query: query) {
                totals[amount.categoryID, default: 0] += amount.value
            }
        }
        return categories.map { category in
            RanchOSFinanceCategoryBar(
                categoryID: category.id, name: category.name,
                total: RanchOSFinanceMoney.roundedCents(totals[category.id] ?? 0))
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Category totals limited to the given day windows. An empty window list
    /// is zero for every category in the query. Windows do not overlap.
    func categoryTotals(
        _ query: RanchOSFinanceChartQuery, windows: [(start: Date, end: Date)]
    ) -> [RanchOSFinanceCategoryBar] {
        let windowKey = windows.map { RanchOSFinanceChartWindow(start: $0.start, end: $0.end) }
        if let cached = chartCache.windowTotals, cached.0 == query, cached.1 == windowKey {
            return cached.2
        }
        let bars = makeWindowTotals(query, windows: windows)
        chartCache.windowTotals = (query, windowKey, bars)
        return bars
    }

    /// One pass over the charges. An empty window list is zero for every
    /// category in the query. Windows do not overlap.
    private func makeWindowTotals(
        _ query: RanchOSFinanceChartQuery, windows: [(start: Date, end: Date)]
    ) -> [RanchOSFinanceCategoryBar] {
        let categories = query.limitsCategories || !query.categoryIDs.isEmpty
            ? ledger.categories.filter { query.categoryIDs.contains($0.id) }
            : ledger.categories
        var totals: [UUID: Decimal] = [:]
        if !windows.isEmpty {
            var open = query
            open.year = nil
            open.month = nil
            open.start = nil
            open.end = nil
            for charge in chartCharges(open) {
                guard let date = RanchOSFinanceDates.parse(charge.dateText) else { continue }
                guard windows.contains(where: { date >= $0.start && date <= $0.end }) else { continue }
                for amount in chartAmounts(charge, query: open) {
                    totals[amount.categoryID, default: 0] += amount.value
                }
            }
        }
        return categories.map { category in
            RanchOSFinanceCategoryBar(
                categoryID: category.id, name: category.name,
                total: RanchOSFinanceMoney.roundedCents(totals[category.id] ?? 0))
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Money in and money out for the chart's account and dates, across every
    /// category. Windows replace the query's dates; an empty list is zero.
    /// `currentPeriodOnly` uses this period of Same period last year.
    func incomeAndExpenses(
        _ query: RanchOSFinanceChartQuery,
        windows: [(start: Date, end: Date)]? = nil,
        currentPeriodOnly: Bool = false
    ) -> (income: Decimal, expenses: Decimal) {
        var scoped = currentPeriodOnly ? comparisonWindows(for: query).current : query
        scoped.categoryIDs = []
        scoped.limitsCategories = false
        if let windows {
            if windows.isEmpty { return (0, 0) }
            scoped.start = nil
            scoped.end = nil
            scoped.year = nil
            scoped.month = nil
        }
        var income = Decimal(0)
        var expenses = Decimal(0)
        for charge in ledger.charges where !charge.isDuplicate && chargeMatches(charge, account: scoped.account) {
            if let windows {
                guard let date = RanchOSFinanceDates.parse(charge.dateText),
                    windows.contains(where: { date >= $0.start && date <= $0.end })
                else { continue }
            } else if let start = scoped.start, let end = scoped.end {
                guard let date = RanchOSFinanceDates.parse(charge.dateText), date >= start && date <= end
                else { continue }
            }
            income += chartValue(charge, money: .income)
            expenses += chartValue(charge, money: .expenses)
        }
        return (RanchOSFinanceMoney.roundedCents(income), RanchOSFinanceMoney.roundedCents(expenses))
    }

    /// Vendor totals inside one category for the chart filters, largest first.
    /// The category filter is ignored so the drilled category always shows.
    /// `currentPeriodOnly` uses this period of Same period last year.
    func vendorTotals(
        categoryID: UUID, query: RanchOSFinanceChartQuery, currentPeriodOnly: Bool = false
    ) -> [RanchOSFinanceVendorBar] {
        var scoped = currentPeriodOnly ? comparisonWindows(for: query).current : query
        scoped.categoryIDs = [categoryID]
        scoped.limitsCategories = true
        var totals: [UUID?: Decimal] = [:]
        for charge in chartCharges(scoped) {
            totals[charge.vendorID.flatMap { vendor(id: $0)?.id }, default: 0] += chartTotal(charge, query: scoped)
        }
        return totals.map { vendorID, total in
            RanchOSFinanceVendorBar(
                vendorID: vendorID,
                name: vendorID.flatMap { vendor(id: $0)?.name } ?? "No vendor",
                total: RanchOSFinanceMoney.roundedCents(total))
        }.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The current filters beside the same dates one year earlier.
    /// A selected month compares that month. All dates compares the newest
    /// year through its latest transaction day with those same dates last year.
    func samePeriodLastYear(_ query: RanchOSFinanceChartQuery) -> RanchOSFinancePeriodCompare {
        if let cached = chartCache.samePeriod, cached.0 == query { return cached.1 }
        let compared = makeSamePeriodLastYear(query)
        chartCache.samePeriod = (query, compared)
        return compared
    }

    private func makeSamePeriodLastYear(_ query: RanchOSFinanceChartQuery) -> RanchOSFinancePeriodCompare {
        let windows = comparisonWindows(for: query)
        let current = categoryTotals(windows.current)
        let priorByID = Dictionary(
            uniqueKeysWithValues: categoryTotals(windows.prior).map { ($0.categoryID, $0.total) })
        let categories = current.map { bar in
            RanchOSFinanceCategoryCompare(
                categoryID: bar.categoryID, name: bar.name, total: bar.total,
                priorTotal: priorByID[bar.categoryID] ?? 0)
        }
        var weeks: [RanchOSFinanceWeekCompare] = []
        if let year = windows.current.year, let month = windows.current.month,
            let priorYear = windows.prior.year
        {
            let currentWeeks = weekTotals(year: year, month: month, query: windows.current)
            let priorWeeks = weekTotals(year: priorYear, month: month, query: windows.prior)
            weeks = zip(currentWeeks, priorWeeks).map { now, then in
                RanchOSFinanceWeekCompare(
                    week: now.week, title: now.title, total: now.total, priorTotal: then.total)
            }
        }
        return RanchOSFinancePeriodCompare(
            currentLabel: windows.currentLabel, priorLabel: windows.priorLabel,
            categories: categories, weeks: weeks)
    }

    /// Four week columns for one month. Weeks with no spending stay at zero.
    func weekTotals(year: Int, month: Int, query: RanchOSFinanceChartQuery) -> [RanchOSFinanceWeekBar] {
        var scoped = query
        scoped.year = year
        scoped.month = month
        scoped.start = nil
        scoped.end = nil
        var totals = [1: Decimal(0), 2: 0, 3: 0, 4: 0]
        for charge in chartCharges(scoped) {
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { continue }
            let value = chartTotal(charge, query: query)
            guard value > 0 else { continue }
            let week = RanchOSFinanceDates.weekOfMonth(date)
            totals[week, default: 0] += value
        }
        return (1...4).map { week in
            let bounds = RanchOSFinanceDates.weekBounds(year: year, month: month, week: week)
            return RanchOSFinanceWeekBar(
                week: week,
                title: "Week \(week) · \(bounds.start)–\(bounds.end)",
                total: RanchOSFinanceMoney.roundedCents(totals[week] ?? 0))
        }
    }

    /// What one charge adds to each category for this query. A split charge
    /// gives each piece to its own category; a limited query keeps only the
    /// pieces in its categories. Empty when the charge adds nothing.
    private func chartAmounts(
        _ charge: RanchOSFinanceCharge, query: RanchOSFinanceChartQuery
    ) -> [(categoryID: UUID, value: Decimal)] {
        let value = chartValue(charge, money: query.money)
        guard value > 0 else { return [] }
        let amounts: [(categoryID: UUID, value: Decimal)]
        let parts = splitParts(for: charge)
        if parts.isEmpty {
            guard let categoryID = categoryID(for: charge) else { return [] }
            amounts = [(categoryID, value)]
        } else {
            amounts = parts.map { ($0.categoryID, $0.amount) }
        }
        guard query.limitsCategories || !query.categoryIDs.isEmpty else { return amounts }
        return amounts.filter { query.categoryIDs.contains($0.categoryID) }
    }

    /// The part of one charge inside this query's categories.
    private func chartTotal(_ charge: RanchOSFinanceCharge, query: RanchOSFinanceChartQuery) -> Decimal {
        chartAmounts(charge, query: query).reduce(Decimal(0)) { $0 + $1.value }
    }

    private func chartCharges(_ query: RanchOSFinanceChartQuery) -> [RanchOSFinanceCharge] {
        ledger.charges.filter { charge in
            if charge.isDuplicate { return false }
            guard chargeMatches(charge, account: query.account) else { return false }
            if query.limitsCategories || !query.categoryIDs.isEmpty {
                guard !chartAmounts(charge, query: query).isEmpty else { return false }
            }
            if let start = query.start, let end = query.end {
                guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
                if date < start || date > end { return false }
            } else if let year = query.year, let month = query.month {
                guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
                let parts = RanchOSFinanceDates.yearMonth(date)
                if parts.year != year || parts.month != month { return false }
            }
            return chartValue(charge, money: query.money) > 0
        }
    }

    private func chargeMatches(
        _ charge: RanchOSFinanceCharge, account: RanchOSFinanceChartAccountFilter
    ) -> Bool {
        let accountID = file(id: charge.fileID)?.accountID
        switch account {
        case .all:
            return true
        case .account(let id):
            return accountID == id
        case .unassigned:
            return accountID == nil
        }
    }

    /// Card and loan statements treat a positive amount as money out. A bank
    /// statement treats a negative amount as money out. Income is the other direction.
    private func chartValue(_ charge: RanchOSFinanceCharge, money: RanchOSFinanceChartMoney) -> Decimal {
        guard let amount = RanchOSFinanceCSV.parseAmount(charge.amountText) else { return 0 }
        let spent = moneyOutIsPositive(fileID: charge.fileID) ? amount : -amount
        switch money {
        case .expenses:
            return spent > 0 ? spent : 0
        case .income:
            return spent < 0 ? -spent : 0
        }
    }

    private func comparisonWindows(
        for query: RanchOSFinanceChartQuery
    ) -> (current: RanchOSFinanceChartQuery, prior: RanchOSFinanceChartQuery, currentLabel: String, priorLabel: String) {
        if let year = query.year, let month = query.month {
            var prior = query
            prior.year = year - 1
            return (
                query, prior,
                RanchOSFinanceDates.monthLabel(year: year, month: month),
                RanchOSFinanceDates.monthLabel(year: year - 1, month: month))
        }
        var open = query
        open.year = nil
        open.month = nil
        open.start = nil
        open.end = nil
        let dates = chartCharges(open).compactMap { RanchOSFinanceDates.parse($0.dateText) }
        guard let latest = dates.max() else {
            return (query, query, "This period", "Last year")
        }
        let parts = RanchOSFinanceDates.yearMonth(latest)
        let day = RanchOSFinanceDates.dayOfMonth(latest)
        let priorDay = min(day, RanchOSFinanceDates.lastDay(year: parts.year - 1, month: parts.month))
        guard
            let currentStart = RanchOSFinanceDates.utcDate(year: parts.year, month: 1, day: 1),
            let currentEnd = RanchOSFinanceDates.utcDate(year: parts.year, month: parts.month, day: day),
            let priorStart = RanchOSFinanceDates.utcDate(year: parts.year - 1, month: 1, day: 1),
            let priorEnd = RanchOSFinanceDates.utcDate(year: parts.year - 1, month: parts.month, day: priorDay)
        else {
            return (query, query, "This period", "Last year")
        }
        var current = open
        current.start = currentStart
        current.end = currentEnd
        var prior = open
        prior.start = priorStart
        prior.end = priorEnd
        return (
            current, prior,
            RanchOSFinanceDates.daySpan([currentStart, currentEnd]),
            RanchOSFinanceDates.daySpan([priorStart, priorEnd]))
    }

    private func moneyOutIsPositive(fileID: UUID) -> Bool {
        guard let file = file(id: fileID) else { return true }
        if let accountID = file.accountID,
            let account = ledger.accounts.first(where: { $0.id == accountID })
        {
            return account.kind != .bank
        }
        return file.source == RanchOSFinanceDates.apple
    }
}
