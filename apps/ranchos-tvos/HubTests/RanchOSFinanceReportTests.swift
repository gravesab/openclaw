import Foundation
import XCTest

/// Finance summary report v1. All fixtures synthetic.
final class RanchOSFinanceReportTests: XCTestCase {
    private let july = RanchOSFinanceReadyMonth(year: 2026, month: 7)

    func testDictationJoinsWordsOntoWhatWasTyped() {
        XCTAssertEqual(RanchOSEntryText.completed(prefix: "", utterance: "  Feed  "), "Feed")
        XCTAssertEqual(RanchOSEntryText.completed(prefix: "Prairie", utterance: "Bank"), "Prairie Bank")
        XCTAssertEqual(RanchOSEntryText.completed(prefix: "Prairie ", utterance: "Bank"), "Prairie Bank")
        XCTAssertEqual(RanchOSEntryText.completed(prefix: "Prairie", utterance: "   "), "Prairie")
    }

    @MainActor
    func testSplitCountsEachPieceUnderItsOwnCategory() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let hardware = try XCTUnwrap(store.createCategory(name: "Hardware"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Prairie Farm Store,Feed,purchase,100.00,Sam
        07/09/2026,07/09/2026,B,Hilltop Hardware,Hardware,purchase,25.00,Sam
        """
        let file = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id).file
        let farm = try XCTUnwrap(store.charges(fileID: file.id).first { $0.merchantText == "Prairie Farm Store" })
        XCTAssertTrue(store.splitCharge(chargeID: farm.id, parts: [(feed.id, 60), (hardware.id, 40)]))

        let report = store.summaryReport(month: july, account: .all)
        XCTAssertEqual(report.expenses, 125)
        XCTAssertEqual(report.categories.map(\.name), ["Hardware", "Feed"])
        XCTAssertEqual(report.categories.map(\.total), [65, 60])
        XCTAssertEqual(report.categories.map(\.percent), ["52%", "48%"])
        for category in report.categories {
            XCTAssertEqual(category.vendors.reduce(Decimal(0)) { $0 + $1.total }, category.total)
        }
        let hardwareVendors = try XCTUnwrap(report.categories.first { $0.categoryID == hardware.id }).vendors
        XCTAssertEqual(hardwareVendors.map(\.name), ["Prairie Farm Store", "Hilltop Hardware"])
        XCTAssertEqual(hardwareVendors.map(\.total), [40, 25])
    }

    @MainActor
    func testDuplicateChangesNoTotalAndUncategorizedHasItsOwnLine() throws {
        let store = try tempStore()
        let bank = try XCTUnwrap(store.createAccount(name: "Prairie Bank", kind: .bank))
        let csv = """
        Posted Date,Memo,Amount
        07/02/2026,CREEK SUPPLY,-30.00
        07/02/2026,CREEK SUPPLY,-30.00
        07/03/2026,PAYROLL DEPOSIT,500.00
        """
        _ = store.ingest(fileName: "bank.csv", bytes: Data(csv.utf8), source: bank.name, accountID: bank.id)

        let report = store.summaryReport(month: july, account: .account(bank.id))
        XCTAssertEqual(report.expenses, 30)
        XCTAssertEqual(report.income, 500)
        XCTAssertEqual(report.transactionCount, 2)
        XCTAssertEqual(report.duplicatesLeftOut, 1)
        XCTAssertEqual(report.uncategorizedExpenses, 30)
        XCTAssertEqual(report.accountLabel, "Prairie Bank · Bank")
        XCTAssertTrue(report.statusLine.hasSuffix("Some charges are Uncategorized"))
    }

    @MainActor
    func testCardPaymentRaisesBothTotalsAndCancelsOutOfRemaining() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let bank = try XCTUnwrap(store.createAccount(name: "Prairie Bank", kind: .bank))
        let cardCSV = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Prairie Farm Store,Feed,purchase,50.00,Sam
        07/20/2026,07/20/2026,B,Card payment,Payment,payment,-40.00,Sam
        """
        let bankCSV = """
        Posted Date,Memo,Amount
        07/03/2026,PAYROLL DEPOSIT,1000.00
        07/20/2026,CARD PAYMENT,-40.00
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(cardCSV.utf8), source: card.name, accountID: card.id)
        _ = store.ingest(fileName: "bank.csv", bytes: Data(bankCSV.utf8), source: bank.name, accountID: bank.id)

        let report = store.summaryReport(month: july, account: .all)
        XCTAssertEqual(report.income, 1040)
        XCTAssertEqual(report.expenses, 90)
        XCTAssertEqual(report.remaining, 950)
        XCTAssertTrue(RanchOSFinanceSummaryReport.treatment.contains("card payment counts as income on the card"))

        let chartBox = store.incomeAndExpenses(RanchOSFinanceChartQuery(
            account: .all, categoryIDs: [], year: nil, month: nil, money: .expenses,
            start: RanchOSFinanceDates.utcDate(year: 2026, month: 7, day: 1),
            end: RanchOSFinanceDates.utcDate(year: 2026, month: 7, day: 31)))
        XCTAssertEqual(chartBox.income, report.income)
        XCTAssertEqual(chartBox.expenses, report.expenses)
    }

    @MainActor
    func testEmptyLedgerHasNoMonthsAndTheLatestMonthComesFirst() throws {
        let store = try tempStore()
        XCTAssertTrue(store.reportMonths(account: .all).isEmpty)
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/10/2026,06/10/2026,A,Prairie Farm Store,Feed,purchase,10.00,Sam
        07/10/2026,07/10/2026,B,Prairie Farm Store,Feed,purchase,20.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)
        XCTAssertEqual(store.reportMonths(account: .all).map(\.id), ["2026-7", "2026-6"])
        XCTAssertTrue(store.reportMonths(account: .unassigned).isEmpty)

        let august = store.summaryReport(month: RanchOSFinanceReadyMonth(year: 2026, month: 8), account: .all)
        XCTAssertEqual(august.transactionCount, 0)
        XCTAssertTrue(august.categories.isEmpty)
        XCTAssertTrue(august.statusLine.hasPrefix("No transactions for"))
        XCTAssertEqual(store.summaryReport(month: july, account: .all).expenses, 20)
    }

    @MainActor
    func testLastYearMatchesSamePeriodLastYear() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let fuel = try XCTUnwrap(store.createCategory(name: "Fuel"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/05/2025,07/05/2025,A,Prairie Farm Store,Feed,purchase,80.00,Sam
        07/06/2025,07/06/2025,B,Alpha Fuel,Fuel,purchase,30.00,Sam
        07/05/2026,07/05/2026,C,Prairie Farm Store,Feed,purchase,100.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)

        let report = store.summaryReport(month: july, account: .all)
        let compared = store.samePeriodLastYear(RanchOSFinanceChartQuery(
            account: .all, categoryIDs: [], year: 2026, month: 7, money: .expenses))
        XCTAssertEqual(report.lastYear.label, compared.priorLabel)
        XCTAssertEqual(report.lastYear.expenses, 110)
        XCTAssertEqual(report.lastYear.categories.map(\.categoryID), [feed.id, fuel.id])
        for row in report.lastYear.categories {
            let match = try XCTUnwrap(compared.categories.first { $0.categoryID == row.categoryID })
            XCTAssertEqual(row.total, match.total)
            XCTAssertEqual(row.priorTotal, match.priorTotal)
        }
    }

    @MainActor
    func testChartFiltersBecomeReportGroups() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let groceries = try XCTUnwrap(store.createCategory(name: "Groceries"))
        _ = try XCTUnwrap(store.createCategory(name: "Hardware"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Prairie Farm Store,Feed,purchase,100.00,Sam
        07/02/2026,07/02/2026,B,Gamma Market,Groceries,purchase,70.00,Sam
        07/03/2026,07/03/2026,C,Hilltop Hardware,Hardware,purchase,30.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)
        XCTAssertTrue(store.summaryReport(month: july, account: .all).groups.isEmpty)

        _ = try XCTUnwrap(store.createChartProfile(name: "Ranch", categoryIDs: [feed.id]))
        _ = try XCTUnwrap(store.createChartProfile(name: "Household", categoryIDs: [groceries.id]))
        var report = store.summaryReport(month: july, account: .all)
        XCTAssertEqual(report.groups.map(\.name), ["Household", "Ranch"])
        XCTAssertEqual(report.groups.map(\.expenses), [70, 100])
        XCTAssertEqual(report.expensesOutsideGroups, 30)
        XCTAssertFalse(report.groupsOverlap)

        _ = try XCTUnwrap(store.createChartProfile(name: "Animals", categoryIDs: [feed.id]))
        report = store.summaryReport(month: july, account: .all)
        XCTAssertEqual(report.groups.map(\.name), ["Animals", "Household", "Ranch"])
        XCTAssertTrue(report.groupsOverlap)
        XCTAssertEqual(report.expensesOutsideGroups, 30)
    }

    @MainActor
    func testCSVIsStableAndPlain() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        _ = try XCTUnwrap(store.createCategory(name: "Feed, Seed"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Prairie Farm Store,"Feed, Seed",purchase,1234.50,Sam
        07/02/2026,07/02/2026,B,Card payment,Payment,payment,-40.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)

        let first = RanchOSFinanceReportCSV.text(store.summaryReport(month: july, account: .all))
        let second = RanchOSFinanceReportCSV.text(store.summaryReport(month: july, account: .all))
        XCTAssertEqual(Data(first.utf8), Data(second.utf8))
        let lines = first.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "RanchOS Finance summary,version 1,,")
        XCTAssertTrue(lines.contains("Through,\"Through Jul 2, 2026\",,"))
        XCTAssertTrue(lines.contains("Summary,Expenses,1234.50,0.00"))
        XCTAssertTrue(lines.contains("Summary,Remaining,-1194.50,0.00"))
        XCTAssertTrue(lines.contains("Category,\"Feed, Seed\",1234.50,0.00"))
        XCTAssertTrue(lines.contains("\"Vendor in Feed, Seed\",Prairie Farm Store,1234.50,"))
        for banned in ["recorded", "saved", "stored"] {
            XCTAssertFalse(first.lowercased().contains(banned), banned)
        }
        XCTAssertEqual(
            RanchOSFinanceReportCSV.fileName(store.summaryReport(month: july, account: .all)),
            "RanchOS Finance summary 2026-07.csv")
    }

    @MainActor
    func testReportIncludesTheNewestTransactionAndMatchesAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: ReportFakeSuggester())
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let julyCSV = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/31/2026,07/31/2026,A,Prairie Farm Store,Feed,purchase,10.00,Sam
        """
        _ = store.ingest(fileName: "july.csv", bytes: Data(julyCSV.utf8), source: card.name, accountID: card.id)
        let octoberCSV = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        10/02/2026,10/02/2026,B,Hilltop Hardware,Hardware,purchase,5.00,Sam
        """
        _ = store.ingest(fileName: "october.csv", bytes: Data(octoberCSV.utf8), source: card.name, accountID: card.id)

        let months = store.reportMonths(account: .all)
        XCTAssertEqual(months.first, RanchOSFinanceReadyMonth(year: 2026, month: 10))
        let october = store.summaryReport(month: try XCTUnwrap(months.first), account: .all)
        XCTAssertEqual(october.transactionCount, 1)
        XCTAssertEqual(october.expenses, 5)
        XCTAssertEqual(october.throughLabel, "Through Oct 2, 2026")
        XCTAssertEqual(october.categories.reduce(Decimal(0)) { $0 + $1.total }, october.expenses)

        let julyReport = store.summaryReport(month: july, account: .all)
        XCTAssertEqual(julyReport.transactionCount, 1)
        XCTAssertEqual(julyReport.expenses, 10)
        XCTAssertEqual(julyReport.throughLabel, "Through Jul 31, 2026")
        XCTAssertEqual(julyReport.categories.reduce(Decimal(0)) { $0 + $1.total }, julyReport.expenses)
        XCTAssertEqual(julyReport.categories.first?.categoryID, feed.id)

        let added = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        10/16/2026,10/16/2026,C,Creek Supply,Feed,purchase,7.00,Sam
        """
        let fresh = RanchOSFinanceStore(persistenceURL: url, suggester: ReportFakeSuggester())
        _ = fresh.ingest(fileName: "later.csv", bytes: Data(added.utf8), source: card.name, accountID: card.id)
        store.reloadFromDisk()
        let reloaded = store.summaryReport(
            month: RanchOSFinanceReadyMonth(year: 2026, month: 10), account: .all)
        XCTAssertEqual(reloaded.throughLabel, "Through Oct 16, 2026")
        XCTAssertEqual(reloaded.transactionCount, 2)
        XCTAssertEqual(reloaded.expenses, 12)
        XCTAssertEqual(reloaded.categories.reduce(Decimal(0)) { $0 + $1.total }, reloaded.expenses)
    }

    // MARK: - Helpers

    @MainActor
    private func tempStore() throws -> RanchOSFinanceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RanchOSFinanceStore(
            persistenceURL: directory.appendingPathComponent("ledger.json"), suggester: ReportFakeSuggester())
    }
}

@MainActor
private final class ReportFakeSuggester: RanchOSFinanceCategorySuggesting, @unchecked Sendable {
    func suggestCategory(vendorName: String, categories: [String]) async -> String? { nil }
}
