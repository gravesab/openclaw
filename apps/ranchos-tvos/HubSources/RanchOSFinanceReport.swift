import Foundation

/// One category in a monthly report, with the vendors that make it up.
struct RanchOSFinanceReportCategory: Identifiable, Equatable, Sendable {
    var categoryID: UUID
    var name: String
    var total: Decimal
    var percent: String
    var vendors: [RanchOSFinanceVendorBar]
    var id: UUID { categoryID }
}

/// Expenses inside one chart filter, such as Ranch or Day-to-day living.
struct RanchOSFinanceReportGroup: Identifiable, Equatable, Sendable {
    var profileID: UUID
    var name: String
    var expenses: Decimal
    var id: UUID { profileID }
}

/// The same month one year earlier, beside this month.
struct RanchOSFinanceReportLastYear: Equatable, Sendable {
    var label: String
    var income: Decimal
    var expenses: Decimal
    /// Every category with money this month or that month, in this month's order.
    var categories: [RanchOSFinanceCategoryCompare]
}

/// Finance's summary of one month for one account filter. Version 1 is the
/// contract the Finance summary cards read. Amounts never leave Finance;
/// `statusLine` is words only.
struct RanchOSFinanceSummaryReport: Equatable, Sendable {
    static let version = 1
    static let treatment = "Totals count every category. Duplicates are left out. A card payment counts as income on the card and as an expense at the bank, so it raises both totals and cancels out of Remaining. A split counts each piece under its own category."

    var month: RanchOSFinanceReadyMonth
    var accountLabel: String
    var income: Decimal
    var expenses: Decimal
    var transactionCount: Int
    var duplicatesLeftOut: Int
    var uncategorizedExpenses: Decimal
    /// Largest first. Categories with no expenses are left out.
    var categories: [RanchOSFinanceReportCategory]
    /// Chart filters A–Z. A category in two filters counts in both.
    var groups: [RanchOSFinanceReportGroup]
    /// Expenses in categories that no chart filter includes.
    var expensesOutsideGroups: Decimal
    var groupsOverlap: Bool
    var lastYear: RanchOSFinanceReportLastYear
    /// The newest transaction kept for this month. Nil when the month has none.
    var throughDate: Date?

    var remaining: Decimal { income - expenses }

    var throughLabel: String {
        guard let throughDate else { return "No transactions in this month" }
        return "Through \(RanchOSFinanceDates.display(throughDate))"
    }

    var statusLine: String {
        let monthName = RanchOSFinanceDates.monthLabel(year: month.year, month: month.month)
        if transactionCount == 0 { return "No transactions for \(monthName)" }
        let ready = throughDate.map {
            "\(monthName) summary is ready through \(RanchOSFinanceDates.display($0))"
        } ?? "\(monthName) summary is ready"
        if uncategorizedExpenses > 0 { return "\(ready) · Some charges are Uncategorized" }
        return ready
    }
}

extension RanchOSFinanceStore {
    /// Months with transactions for this account, newest first. The report
    /// opens on the first one.
    func reportMonths(account: RanchOSFinanceChartAccountFilter) -> [RanchOSFinanceReadyMonth] {
        chartMonths(account: account).reversed()
    }

    func summaryReport(
        month: RanchOSFinanceReadyMonth, account: RanchOSFinanceChartAccountFilter
    ) -> RanchOSFinanceSummaryReport {
        let query = reportQuery(year: month.year, month: month.month, account: account)
        let money = incomeAndExpenses(query)
        let totals = categoryTotals(query)
        let expenses = money.expenses
        let ranked = RanchOSFinancePareto.bars(from: totals)
        let categories = ranked.map { bar in
            RanchOSFinanceReportCategory(
                categoryID: bar.categoryID, name: bar.name, total: bar.total,
                percent: RanchOSFinancePareto.percentText(bar.total, of: expenses),
                vendors: vendorTotals(categoryID: bar.categoryID, query: query).filter { $0.total > 0 })
        }
        let byCategory = Dictionary(uniqueKeysWithValues: totals.map { ($0.categoryID, $0.total) })

        let profiles = chartProfilesByName
        var grouped = Set<UUID>()
        var seenOnce = Set<UUID>()
        var overlap = false
        let groups = profiles.map { profile in
            for id in Set(profile.categoryIDs) {
                if !seenOnce.insert(id).inserted { overlap = true }
                grouped.insert(id)
            }
            let sum = Set(profile.categoryIDs).reduce(Decimal(0)) { $0 + (byCategory[$1] ?? 0) }
            return RanchOSFinanceReportGroup(
                profileID: profile.id, name: profile.name, expenses: RanchOSFinanceMoney.roundedCents(sum))
        }
        let outside = totals.filter { !grouped.contains($0.categoryID) }
            .reduce(Decimal(0)) { $0 + $1.total }

        var counted = 0
        var duplicates = 0
        var newest: Date?
        for charge in ledger.charges where reportIncludes(charge, month: month, account: account) {
            if charge.isDuplicate {
                duplicates += 1
            } else {
                counted += 1
                if let date = RanchOSFinanceDates.parse(charge.dateText) {
                    if let current = newest {
                        if date > current { newest = date }
                    } else {
                        newest = date
                    }
                }
            }
        }

        var compareQuery = query
        compareQuery.start = nil
        compareQuery.end = nil
        compareQuery.year = month.year
        compareQuery.month = month.month
        let compared = samePeriodLastYear(compareQuery)
        let order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.categoryID, $0) })
        let compareRows = compared.categories
            .filter { $0.total > 0 || $0.priorTotal > 0 }
            .sorted { lhs, rhs in
                switch (order[lhs.categoryID], order[rhs.categoryID]) {
                case let (left?, right?): return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil):
                    if lhs.priorTotal != rhs.priorTotal { return lhs.priorTotal > rhs.priorTotal }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
        let prior = incomeAndExpenses(reportQuery(year: month.year - 1, month: month.month, account: account))

        return RanchOSFinanceSummaryReport(
            month: month,
            accountLabel: reportAccountLabel(account),
            income: money.income,
            expenses: expenses,
            transactionCount: counted,
            duplicatesLeftOut: duplicates,
            uncategorizedExpenses: uncategorizedID.flatMap { byCategory[$0] } ?? 0,
            categories: categories,
            groups: groups,
            expensesOutsideGroups: RanchOSFinanceMoney.roundedCents(outside),
            groupsOverlap: overlap,
            lastYear: RanchOSFinanceReportLastYear(
                label: compared.priorLabel, income: prior.income, expenses: prior.expenses,
                categories: compareRows),
            throughDate: newest)
    }

    func reportAccountLabel(_ account: RanchOSFinanceChartAccountFilter) -> String {
        switch account {
        case .all:
            return "All accounts"
        case .unassigned:
            return "No account"
        case .account(let id):
            return ledger.accounts.first(where: { $0.id == id }).map(accountLabel) ?? "Account removed"
        }
    }

    /// `incomeAndExpenses` reads only start and end, so the month becomes a day window.
    private func reportQuery(
        year: Int, month: Int, account: RanchOSFinanceChartAccountFilter
    ) -> RanchOSFinanceChartQuery {
        var query = RanchOSFinanceChartQuery.allExpenses
        query.account = account
        query.start = RanchOSFinanceDates.utcDate(year: year, month: month, day: 1)
        let last = RanchOSFinanceDates.lastDay(year: year, month: month)
        query.end = RanchOSFinanceDates.endOfUTCDay(year: year, month: month, day: last)
        return query
    }

    private func reportIncludes(
        _ charge: RanchOSFinanceCharge, month: RanchOSFinanceReadyMonth, account: RanchOSFinanceChartAccountFilter
    ) -> Bool {
        guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
        let parts = RanchOSFinanceDates.yearMonth(date)
        guard parts.year == month.year, parts.month == month.month else { return false }
        let accountID = file(id: charge.fileID)?.accountID
        switch account {
        case .all: return true
        case .account(let id): return accountID == id
        case .unassigned: return accountID == nil
        }
    }
}

/// The report as CSV. Same report, same bytes: fixed columns, fixed order,
/// plain amounts with two decimals.
enum RanchOSFinanceReportCSV {
    static func text(_ report: RanchOSFinanceSummaryReport) -> String {
        var rows: [[String]] = [
            ["RanchOS Finance summary", "version \(RanchOSFinanceSummaryReport.version)", "", ""],
            ["Month", report.month.label, "", ""],
            ["Through", report.throughLabel, "", ""],
            ["Account", report.accountLabel, "", ""],
            ["How totals count", RanchOSFinanceSummaryReport.treatment, "", ""],
            ["Section", "Name", "Amount", "Same month last year"],
            ["Summary", "Income", amount(report.income), amount(report.lastYear.income)],
            ["Summary", "Expenses", amount(report.expenses), amount(report.lastYear.expenses)],
            ["Summary", "Remaining", amount(report.remaining), amount(report.lastYear.income - report.lastYear.expenses)],
            ["Summary", "Transactions", "\(report.transactionCount)", ""],
            ["Summary", "Duplicates left out", "\(report.duplicatesLeftOut)", ""],
            ["Summary", RanchOSFinanceSuggestionLabels.uncategorized, amount(report.uncategorizedExpenses), ""],
        ]
        let prior = Dictionary(uniqueKeysWithValues: report.lastYear.categories.map { ($0.categoryID, $0.priorTotal) })
        for category in report.categories {
            rows.append(["Category", category.name, amount(category.total), amount(prior[category.categoryID] ?? 0)])
        }
        let current = Set(report.categories.map(\.categoryID))
        for compare in report.lastYear.categories where !current.contains(compare.categoryID) {
            rows.append(["Category", compare.name, amount(0), amount(compare.priorTotal)])
        }
        for category in report.categories {
            for vendor in category.vendors {
                rows.append(["Vendor in \(category.name)", vendor.name, amount(vendor.total), ""])
            }
        }
        for group in report.groups {
            rows.append(["Chart filter", group.name, amount(group.expenses), ""])
        }
        if !report.groups.isEmpty {
            rows.append(["Chart filter", "In no chart filter", amount(report.expensesOutsideGroups), ""])
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func fileName(_ report: RanchOSFinanceSummaryReport) -> String {
        String(format: "RanchOS Finance summary %04d-%02d.csv", report.month.year, report.month.month)
    }

    static func amount(_ value: Decimal) -> String {
        let cents = NSDecimalNumber(decimal: RanchOSFinanceMoney.roundedCents(value))
            .multiplying(byPowerOf10: 2).intValue
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return sign + "\(absolute / 100).\(String(format: "%02d", absolute % 100))"
    }

    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
