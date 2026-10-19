import CryptoKit
import XCTest

final class RanchOSFinanceImportResultTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_759_536_000)

    private func sampleData() throws -> Data {
        let bundle = Bundle(for: RanchOSFinanceImportResultTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "FinanceImportResultSample", withExtension: "csv"))
        return try Data(contentsOf: url)
    }

    func testSampleCSVShowsFileDigestRowCountAndError() throws {
        let data = try sampleData()
        let result = try FinanceImportResultLoader.parse(data, fileName: "FinanceImportResultSample.csv", now: now)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(result.fileName, "FinanceImportResultSample.csv")
        XCTAssertEqual(result.sha256, digest)
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertEqual(result.rowCount, 3)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.errors[0].row, 4)
        XCTAssertEqual(result.errors[0].code, "finance_csv_amount_zero")
        XCTAssertEqual(result.errors[0].message, "Row 4: amount is zero")
    }

    func testWrongHeadersAreNotThisCSV() {
        let csv = Data("Date,Amount\n01/01/2024,1.00\n".utf8)
        XCTAssertThrowsError(try FinanceImportResultLoader.parse(csv, fileName: "notes.csv", now: now)) { error in
            XCTAssertEqual(error as? FinanceImportParseError, .notThisCSV)
        }
    }

    func testFutureDateAndDuplicateUseApprovedCodes() throws {
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        01/15/2024,01/16/2024,Feed purchase,North Gate,Other,purchase,-10.00,Alex Sample
        01/15/2024,01/16/2024,Feed purchase,North Gate,Other,purchase,-10.00,Alex Sample
        12/01/2099,12/02/2099,Later,North Gate,Other,purchase,-3.00,Alex Sample
        """
        let result = try FinanceImportResultLoader.parse(Data(csv.utf8), fileName: "dup.csv", now: now)
        XCTAssertEqual(result.rowCount, 3)
        XCTAssertEqual(result.errors.map(\.code), ["finance_csv_duplicate_row", "finance_csv_future_date"])
    }

    func testWrappedDescriptionStaysOnePurchase() throws {
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        01/15/2024,01/16/2024,Feed
        purchase,North Gate,Other,Purchase,-42.50,Alex Sample
        01/20/2024,01/20/2024,Statement credit,Apple Card,Payment,Credit,12.00,Alex Sample
        """
        let result = try FinanceImportResultLoader.parse(Data(csv.utf8), fileName: "wrapped.csv", now: now)
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.errors, [])
    }

    func testMissingColumnCodeIsFileLevel() {
        let csv = Data("Transaction Date,Clearing Date,Description,Merchant,Category,Type,Purchased By\n".utf8)
        XCTAssertThrowsError(try FinanceImportResultLoader.parse(csv, fileName: "short.csv", now: now)) { error in
            XCTAssertEqual(error as? FinanceImportParseError, .notThisCSV)
        }
    }

    func testExactStringsOmitWithdrawnSampleLanguage() {
        XCTAssertEqual(FinanceImportResultStrings.banner, "DEV · Finance import result · read only")
        XCTAssertFalse(FinanceImportResultStrings.walletInstructions.isEmpty)
        let joined = [
            FinanceImportResultStrings.banner,
            FinanceImportResultStrings.walletInstructions,
            FinanceImportResultStrings.unreadable,
            FinanceImportResultStrings.notThisCSV,
        ].joined(separator: "\n")
        XCTAssertNil(joined.range(of: "recorded", options: .caseInsensitive))
        XCTAssertNil(joined.range(of: "saved", options: .caseInsensitive))
        XCTAssertNil(joined.range(of: "stored", options: .caseInsensitive))
        XCTAssertNil(joined.range(of: "synthetic sample", options: .caseInsensitive))
    }
}
