import XCTest

final class RanchOSFinanceImportResultTests: XCTestCase {
    private func sampleData() throws -> Data {
        let bundle = Bundle(for: RanchOSFinanceImportResultTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "FinanceImportResultSample", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testValidSampleDecodesVerbatim() throws {
        let result = try FinanceImportResultLoader.decode(sampleData())

        XCTAssertEqual(result.schema, "ranch-finance-import-result/v1")
        XCTAssertEqual(result.producedAt, "2026-10-03T12:00:00Z")
        XCTAssertEqual(result.producedBy, "synthetic-sample-v1")
        XCTAssertEqual(result.tenantLabel, "DEV sample")
        XCTAssertEqual(result.artifact.fileName, "apple-card-2026-09.csv")
        XCTAssertEqual(
            result.artifact.sha256,
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertEqual(result.artifact.rowCount, 10)
    }

    func testErrorEntriesCarryRowCodeMessage() throws {
        let result = try FinanceImportResultLoader.decode(sampleData())

        XCTAssertEqual(result.errors.count, 2)
        XCTAssertEqual(result.errors[0].row, 4)
        XCTAssertEqual(result.errors[0].code, "finance_csv_amount_zero")
        XCTAssertEqual(result.errors[0].message, "Row 4: amount is zero")
        XCTAssertEqual(result.errors[1].row, 9)
        XCTAssertEqual(result.errors[1].code, "finance_csv_future_date")
    }

    func testUnknownSchemaThrows() {
        let json = """
        {"schema":"ranch-finance-import-result/v9","produced_at":"t","produced_by":"x",\
        "tenant_label":"y","artifact":{"file_name":"f","sha256":"s","row_count":1},"errors":[]}
        """

        XCTAssertThrowsError(try FinanceImportResultLoader.decode(Data(json.utf8))) { error in
            guard case FinanceImportResultLoadError.unknownSchema(let schema) = error else {
                return XCTFail("expected unknownSchema, got \(error)")
            }
            XCTAssertEqual(schema, "ranch-finance-import-result/v9")
        }
    }

    func testGarbageBytesThrow() {
        XCTAssertThrowsError(try FinanceImportResultLoader.decode(Data("not json".utf8)))
    }

    func testMissingKeyThrows() {
        let json = """
        {"schema":"ranch-finance-import-result/v1","produced_at":"t","produced_by":"x",\
        "tenant_label":"y","artifact":{"file_name":"f","row_count":1},"errors":[]}
        """

        XCTAssertThrowsError(try FinanceImportResultLoader.decode(Data(json.utf8)))
    }

    func testNegativeRowCountThrows() {
        let json = """
        {"schema":"ranch-finance-import-result/v1","produced_at":"t","produced_by":"x",\
        "tenant_label":"y","artifact":{"file_name":"f","sha256":"s","row_count":-1},"errors":[]}
        """

        XCTAssertThrowsError(try FinanceImportResultLoader.decode(Data(json.utf8)))
    }

    func testExactStrings() {
        XCTAssertEqual(FinanceImportResultStrings.schema, "ranch-finance-import-result/v1")
        XCTAssertEqual(FinanceImportResultStrings.banner, "DEV · Finance import result · read only")
        XCTAssertEqual(FinanceImportResultStrings.syntheticMarker, "synthetic sample")
        XCTAssertEqual(
            FinanceImportResultStrings.emptySentence,
            "Synthetic sample only — a real exporter is a later spec")
    }
}
