import Foundation
import XCTest

/// Dated principal balances on loans. All fixtures synthetic.
final class RanchOSFinanceLoanBalanceTests: XCTestCase {
    private let principalCSV = """
    Posted Date,Memo,Amount,Principal
    09/02/2026,PAYMENT,-500.00,12500.00
    09/30/2026,PAYMENT,-500.00,12000.00
    """

    private let balanceCSV = """
    Posted Date,Memo,Amount,Running Balance
    09/02/2026,PAYMENT,-500.00,12500.00
    09/30/2026,PAYMENT,-500.00,12000.00
    """

    private let plainCSV = """
    Posted Date,Memo,Amount
    09/02/2026,PAYMENT,-500.00
    09/30/2026,PAYMENT,-500.00
    """

    // MARK: - Parse

    func testPrincipalColumnNewestRowWins() {
        let parsed = RanchOSFinanceCSV.parse(bytes: Data(principalCSV.utf8))
        XCTAssertEqual(parsed.kind, .bank)
        XCTAssertEqual(parsed.principal?.dateText, "09/30/2026")
        XCTAssertEqual(parsed.principal?.amountText, "12000.00")
    }

    func testPrincipalHeaderVariants() {
        for header in [
            "Principal", "Outstanding Principal", "Current Principal",
            "Principal Balance", "Remaining Principal",
        ] {
            let csv = "Posted Date,Memo,Amount,\(header)\n09/30/2026,PAYMENT,-500.00,12000.00\n"
            let parsed = RanchOSFinanceCSV.parse(bytes: Data(csv.utf8))
            XCTAssertEqual(parsed.principal?.amountText, "12000.00", header)
        }
    }

    func testPrincipalPaymentHeadersAreNotTheBalance() {
        for header in ["Principal Payment", "Principal Paid"] {
            let csv = "Posted Date,Memo,Amount,\(header)\n09/30/2026,PAYMENT,-500.00,400.00\n"
            let parsed = RanchOSFinanceCSV.parse(bytes: Data(csv.utf8))
            XCTAssertNil(parsed.principal, header)
        }
    }

    func testBalanceColumnIsTheFallback() {
        let parsed = RanchOSFinanceCSV.parse(bytes: Data(balanceCSV.utf8))
        XCTAssertEqual(parsed.principal?.dateText, "09/30/2026")
        XCTAssertEqual(parsed.principal?.amountText, "12000.00")
    }

    func testBalanceHeaderVariants() {
        for header in ["Balance", "Running Balance", "Ending Balance", "Current Balance"] {
            let csv = "Posted Date,Memo,Amount,\(header)\n09/30/2026,PAYMENT,-500.00,12000.00\n"
            let parsed = RanchOSFinanceCSV.parse(bytes: Data(csv.utf8))
            XCTAssertEqual(parsed.principal?.amountText, "12000.00", header)
        }
    }

    func testPrincipalBeatsBalanceAndLaterRowWinsTies() {
        let csv = """
        Posted Date,Memo,Amount,Principal,Balance
        09/30/2026,FIRST,-100.00,12000.00,99999.00
        09/30/2026,SECOND,-100.00,11900.00,99999.00
        """
        let parsed = RanchOSFinanceCSV.parse(bytes: Data(csv.utf8))
        XCTAssertEqual(parsed.principal?.dateText, "09/30/2026")
        XCTAssertEqual(parsed.principal?.amountText, "11900.00")
    }

    func testNoPrincipalOrBalanceIsNil() {
        XCTAssertNil(RanchOSFinanceCSV.parse(bytes: Data(plainCSV.utf8)).principal)
        let card = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Sunny Acres Feed,Feed,purchase,100.00,Sam
        """
        XCTAssertNil(RanchOSFinanceCSV.parse(bytes: Data(card.utf8)).principal)
    }

    @MainActor
    func testLedgerWithoutPrincipalSnapshotsStillOpensAccounts() throws {
        let store = try tempStore()
        let loan = try XCTUnwrap(store.createAccount(name: "Freedom Mortgage", kind: .loan, purpose: "House"))
        let data = try JSONEncoder().encode(store.ledger)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var accounts = object["accounts"] as! [[String: Any]]
        accounts[0].removeValue(forKey: "principalSnapshots")
        object["accounts"] = accounts
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RanchOSFinanceLedger.self, from: legacy)
        XCTAssertEqual(decoded.accounts.count, 1)
        XCTAssertEqual(decoded.accounts[0].id, loan.id)
        XCTAssertTrue(decoded.accounts[0].principalSnapshots.isEmpty)
    }

    // MARK: - Snapshots

    @MainActor
    func testNewerAddsSameReplacesOlderKeepsBalance() throws {
        let store = try tempStore()
        let loan = try XCTUnwrap(store.createAccount(name: "Freedom Mortgage", kind: .loan, purpose: "House"))
        XCTAssertNil(store.principalBalance(accountID: loan.id))

        let first = try XCTUnwrap(RanchOSFinanceCSV.parseDate("09/30/2026"))
        store.recordPrincipalSnapshot(accountID: loan.id, date: first, amount: Decimal(string: "12000.00")!)
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "12000.00"))

        store.recordPrincipalSnapshot(accountID: loan.id, date: first, amount: Decimal(string: "11950.00")!)
        XCTAssertEqual(store.principalHistory(accountID: loan.id).count, 1)
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "11950.00"))

        let older = try XCTUnwrap(RanchOSFinanceCSV.parseDate("08/31/2026"))
        store.recordPrincipalSnapshot(accountID: loan.id, date: older, amount: Decimal(string: "12500.00")!)
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "11950.00"))
        let history = store.principalHistory(accountID: loan.id)
        XCTAssertEqual(history.map(\.amount), [Decimal(string: "12500.00")!, Decimal(string: "11950.00")!])

        let newer = try XCTUnwrap(RanchOSFinanceCSV.parseDate("10/31/2026"))
        store.recordPrincipalSnapshot(accountID: loan.id, date: newer, amount: Decimal(string: "11500.00")!)
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "11500.00"))
        XCTAssertEqual(store.principalHistory(accountID: loan.id).count, 3)
    }

    @MainActor
    func testCardsAndBanksKeepNoSnapshots() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let day = try XCTUnwrap(RanchOSFinanceCSV.parseDate("09/30/2026"))
        store.recordPrincipalSnapshot(accountID: card.id, date: day, amount: Decimal(string: "100.00")!)
        XCTAssertNil(store.principalBalance(accountID: card.id))
        XCTAssertTrue(store.principalHistory(accountID: card.id).isEmpty)
    }

    // MARK: - Ingest

    @MainActor
    func testLoanIngestRecordsPrincipal() throws {
        let store = try tempStore()
        let loan = try XCTUnwrap(store.createAccount(name: "Freedom Mortgage", kind: .loan, purpose: "House"))
        let outcome = store.ingest(
            fileName: "loan.csv", bytes: Data(principalCSV.utf8), source: loan.name, accountID: loan.id)
        let day = try XCTUnwrap(RanchOSFinanceCSV.parseDate("09/30/2026"))
        let expected = RanchOSFinanceDates.startOfUTCDay(day)
        XCTAssertEqual(outcome.principal, .recorded(date: expected, amount: Decimal(string: "12000.00")!))
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "12000.00"))

        let again = store.ingest(
            fileName: "loan.csv", bytes: Data(principalCSV.utf8), source: loan.name, accountID: loan.id)
        XCTAssertNil(again.principal, "re-ingest keeps nothing new")
        XCTAssertEqual(store.principalHistory(accountID: loan.id).count, 1)
    }

    @MainActor
    func testLoanIngestWithoutPrincipalLeavesSnapshotsAlone() throws {
        let store = try tempStore()
        let loan = try XCTUnwrap(store.createAccount(name: "Freedom Mortgage", kind: .loan, purpose: "House"))
        let day = try XCTUnwrap(RanchOSFinanceCSV.parseDate("08/31/2026"))
        store.recordPrincipalSnapshot(accountID: loan.id, date: day, amount: Decimal(string: "12500.00")!)
        let outcome = store.ingest(
            fileName: "plain.csv", bytes: Data(plainCSV.utf8), source: loan.name, accountID: loan.id)
        XCTAssertEqual(outcome.principal, .missing)
        XCTAssertEqual(store.principalHistory(accountID: loan.id).count, 1)
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "12500.00"))
    }

    @MainActor
    func testCardIngestWithBalanceColumnKeepsNothing() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let outcome = store.ingest(
            fileName: "card.csv", bytes: Data(balanceCSV.utf8), source: card.name, accountID: card.id)
        XCTAssertNil(outcome.principal)
        XCTAssertNil(store.principalBalance(accountID: card.id))
    }

    @MainActor
    func testAssigningLoanToExistingFileRecordsPrincipal() throws {
        let store = try tempStore()
        let first = store.ingest(fileName: "loan.csv", bytes: Data(principalCSV.utf8), source: "Freedom Mortgage")
        XCTAssertNil(first.principal)
        let loan = try XCTUnwrap(store.createAccount(name: "Freedom Mortgage", kind: .loan, purpose: "House"))
        let second = store.ingest(
            fileName: "loan.csv", bytes: Data(principalCSV.utf8), source: loan.name, accountID: loan.id)
        XCTAssertEqual(second.file.id, first.file.id)
        XCTAssertNotNil(second.principal)
        XCTAssertEqual(store.principalBalance(accountID: loan.id)?.amount, Decimal(string: "12000.00"))
    }

    // MARK: - Helpers

    @MainActor
    private func tempStore() throws -> RanchOSFinanceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return RanchOSFinanceStore(
            persistenceURL: directory.appendingPathComponent("ledger.json"),
            suggester: FakeBalanceSuggester())
    }
}

private final class FakeBalanceSuggester: RanchOSFinanceCategorySuggesting, @unchecked Sendable {
    func suggestCategory(vendorName: String, categories: [String]) async -> String? { nil }
}
