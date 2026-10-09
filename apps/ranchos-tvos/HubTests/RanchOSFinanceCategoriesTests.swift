import CryptoKit
import Foundation
import XCTest

/// Finance categories slice: multi-file CSV ingest, vendors, categories,
/// on-device suggestions, and container persistence. All fixtures synthetic.
final class RanchOSFinanceCategoriesTests: XCTestCase {
    // MARK: - Apple Card fixture

    func testAppleCardFixtureKindCountsAndSha() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        XCTAssertEqual(parsed.kind, .appleCard)
        XCTAssertEqual(parsed.rowCount, 10)
        XCTAssertEqual(parsed.charges.count, 7)
        XCTAssertEqual(parsed.errors.count, 4)

        let digest = SHA256.hash(data: bytes)
        let expected = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(parsed.sha256Hex, expected)
    }

    func testAppleCardWrappedLineIsOneLogicalRow() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        let joined = parsed.charges.first(where: { $0.merchantText == "Hilltop Hardware" })
        XCTAssertNotNil(joined)
        XCTAssertFalse(joined?.isDuplicate ?? true)
        // No invalid-type pair from the wrap: rows 6 has no error at all.
        XCTAssertFalse(parsed.errors.contains(where: { $0.row == 6 }))
    }

    func testAppleCardCreditAndInterestAcceptedCaseInsensitively() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        let appleCharges = parsed.charges.filter { $0.merchantText == "Apple Card" }
        // Payment row plus the Credit and interest rows.
        XCTAssertEqual(appleCharges.count, 3)
    }

    func testAppleCardUnknownTypeFailsClosedWithoutTheCell() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        let typeErrors = parsed.errors.filter {
            $0.code == RanchOSFinanceCSV.codeInvalid && $0.row == 10
        }
        XCTAssertEqual(typeErrors.count, 1)
        XCTAssertEqual(typeErrors.first?.message, "activity type is invalid")
        for error in parsed.errors {
            XCTAssertFalse(error.message.contains("Mystery Shop"))
            XCTAssertFalse(error.message.contains("11.11"))
        }
        // The bad row produces no charge; the other nine rows are unaffected.
        XCTAssertEqual(parsed.charges.count, 7)
    }

    func testAppleCardDuplicateStaysVisibleAndFlagged() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        let duplicates = parsed.errors.filter { $0.code == RanchOSFinanceCSV.codeDuplicateRow }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.row, 7)
        let dupCharges = parsed.charges.filter(\.isDuplicate)
        XCTAssertEqual(dupCharges.count, 1)
        XCTAssertEqual(dupCharges.first?.merchantText, "Fresh Fields Market")
    }

    func testAppleCardZeroAndFutureRowsRejected() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        XCTAssertTrue(parsed.errors.contains(where: {
            $0.row == 8 && $0.code == RanchOSFinanceCSV.codeAmountZero
        }))
        XCTAssertTrue(parsed.errors.contains(where: {
            $0.row == 9 && $0.code == RanchOSFinanceCSV.codeFutureDate
        }))
    }

    func testAppleCardMissingColumnIsFileLevel() {
        let bytes = Data(
            "Transaction Date,Clearing Date,Description,Merchant,Type,Amount (USD),Purchased By\n09/01/2026,09/03/2026,Desc,Shop,purchase,1.00,Sam\n".utf8)
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        XCTAssertEqual(parsed.kind, .appleCard)
        XCTAssertEqual(parsed.rowCount, 0)
        XCTAssertTrue(parsed.charges.isEmpty)
        XCTAssertEqual(parsed.errors.count, 1)
        XCTAssertEqual(parsed.errors.first?.row, 0)
        XCTAssertEqual(parsed.errors.first?.code, RanchOSFinanceCSV.codeMissingColumn)
    }

    func testAppleCardKeepsCategoryText() throws {
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        let fields = parsed.charges.filter { $0.merchantText == "Fresh Fields Market" }
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(fields.allSatisfy { $0.categoryText == "Groceries" })
        XCTAssertEqual(
            Set(parsed.charges.filter { $0.merchantText == "Apple Card" }.map(\.categoryText)),
            ["Payment", "Interest", "Fees"])

        let bank = try fixtureBytes("FinanceSampleBank")
        XCTAssertTrue(RanchOSFinanceCSV.parse(bytes: bank).charges.allSatisfy(\.categoryText.isEmpty))
    }

    // MARK: - Bank fixture

    func testBankFixtureIngests() throws {
        let bytes = try fixtureBytes("FinanceSampleBank")
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        XCTAssertEqual(parsed.kind, .bank)
        XCTAssertEqual(parsed.rowCount, 5)
        XCTAssertEqual(parsed.charges.count, 4)
        XCTAssertEqual(parsed.errors.count, 2)
        XCTAssertTrue(parsed.errors.contains(where: {
            $0.row == 3 && $0.code == RanchOSFinanceCSV.codeDuplicateRow
        }))
        XCTAssertTrue(parsed.errors.contains(where: {
            $0.row == 4 && $0.code == RanchOSFinanceCSV.codeInvalid
        }))
        let hank = parsed.charges.first(where: { $0.merchantText == "HARDWARE HANK" })
        XCTAssertNotNil(hank)
        XCTAssertEqual(hank?.isDuplicate, false)
    }

    // MARK: - Unrecognized files

    func testUnrecognizedFileListsWithZeroCharges() {
        let bytes = Data("Foo,Bar\n1,2\n".utf8)
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        XCTAssertEqual(parsed.kind, .unrecognized)
        XCTAssertEqual(parsed.rowCount, 0)
        XCTAssertEqual(parsed.charges.count, 0)
        XCTAssertEqual(parsed.errors.count, 1)
        XCTAssertEqual(parsed.errors.first?.row, 0)
        XCTAssertEqual(parsed.errors.first?.code, RanchOSFinanceCSV.codeInvalid)
    }

    func testUnreadableBytesFailClosed() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)

        XCTAssertEqual(parsed.kind, .unrecognized)
        XCTAssertTrue(parsed.charges.isEmpty)
        XCTAssertFalse(parsed.errors.isEmpty)
    }

    // MARK: - Store: ingest, vendors, categories

    @MainActor
    func testIngestCreatesAppleCategoriesAndPlacesVendors() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")

        let outcome = store.ingest(fileName: "card.csv", bytes: bytes)

        XCTAssertEqual(outcome.file.rowCount, 10)
        XCTAssertEqual(outcome.file.errorCount, 4)
        XCTAssertEqual(outcome.newVendors.count, 4)
        // Six Apple values become categories; Uncategorized stays the one
        // flagged row. Rejected rows (Misc) create nothing.
        XCTAssertEqual(
            Set(store.ledger.categories.map(\.name)),
            ["Uncategorized", "Groceries", "Payment", "Clothing", "Interest", "Fees", "Hardware"])
        XCTAssertEqual(store.ledger.categories.filter(\.isUncategorized).count, 1)
        // Single-category vendors land; Apple Card is mixed
        // (Payment, Interest, Fees) and stays Uncategorized.
        XCTAssertEqual(vendorCategoryName("fresh fields market", store: store), "Groceries")
        XCTAssertEqual(vendorCategoryName("trail outfitters", store: store), "Clothing")
        XCTAssertEqual(vendorCategoryName("hilltop hardware", store: store), "Hardware")
        XCTAssertEqual(vendorCategoryName("apple card", store: store), "Uncategorized")
        // Placement is file data, not a guess: no suggestion marks.
        for vendor in outcome.newVendors {
            XCTAssertNil(store.vendor(id: vendor.id)?.suggestion)
        }
        // Re-ingesting identical bytes is a no-op.
        let again = store.ingest(fileName: "card.csv", bytes: bytes)
        XCTAssertEqual(again.file.id, outcome.file.id)
        XCTAssertTrue(again.newVendors.isEmpty)
        XCTAssertEqual(store.ledger.files.count, 1)
        XCTAssertEqual(store.ledger.charges.count, 7)
    }

    @MainActor
    func testCreateDeleteCategoryMovesVendors() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)
        XCTAssertFalse(outcome.newVendors.isEmpty)

        XCTAssertNil(store.createCategory(name: "   "))
        let feed = store.createCategory(name: "Feed & Seed")
        XCTAssertNotNil(feed)
        XCTAssertNil(store.createCategory(name: "feed & seed"))

        let vendor = outcome.newVendors[0]
        store.assign(vendorID: vendor.id, categoryID: feed!.id)
        XCTAssertEqual(store.vendor(id: vendor.id)?.categoryID, feed!.id)

        let chargesBefore = store.ledger.charges.count
        let filesBefore = store.ledger.files.count
        XCTAssertTrue(store.deleteCategory(id: feed!.id))
        XCTAssertEqual(store.vendor(id: vendor.id)?.categoryID, store.uncategorizedID)
        XCTAssertNil(store.vendor(id: vendor.id)?.suggestion)
        XCTAssertEqual(store.ledger.charges.count, chargesBefore)
        XCTAssertEqual(store.ledger.files.count, filesBefore)

        // Uncategorized itself cannot be deleted.
        XCTAssertFalse(store.deleteCategory(id: store.uncategorizedID!))
    }

    // MARK: - Store: rename

    @MainActor
    func testRenameKeepsIdentityAndAssignments() throws {
        let store = try tempStore()
        let feed = store.createCategory(name: "Feed")!
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)
        let vendorID = outcome.newVendors[0].id
        store.assign(vendorID: vendorID, categoryID: feed.id)

        XCTAssertTrue(store.renameCategory(id: feed.id, newName: "Feed & Seed"))

        let renamed = store.category(id: feed.id)
        XCTAssertEqual(renamed?.id, feed.id)
        XCTAssertEqual(renamed?.name, "Feed & Seed")
        XCTAssertEqual(store.vendor(id: vendorID)?.categoryID, feed.id)
        XCTAssertEqual(store.ledger.categories.count, 2)
    }

    @MainActor
    func testRenameBlankOrDuplicateReverts() throws {
        let store = try tempStore()
        let feed = store.createCategory(name: "Feed")!
        _ = store.createCategory(name: "Seed")!

        XCTAssertFalse(store.renameCategory(id: feed.id, newName: "   "))
        XCTAssertFalse(store.renameCategory(id: feed.id, newName: "seed"))
        XCTAssertEqual(store.category(id: feed.id)?.name, "Feed")
        XCTAssertTrue(store.renameCategory(id: feed.id, newName: "Feed"))
        XCTAssertEqual(store.category(id: feed.id)?.name, "Feed")
    }

    @MainActor
    func testAssignVendorUpdatesItsCharges() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        // Groceries already exists from the file; move the vendor off it.
        let feed = store.createCategory(name: "Feed")!

        guard let vendor = store.ledger.vendors.first(where: { $0.key == "fresh fields market" }) else {
            return XCTFail("expected vendor missing")
        }
        XCTAssertEqual(store.charges(vendorID: vendor.id).count, 2)
        store.assign(vendorID: vendor.id, categoryID: feed.id)

        for charge in store.charges(vendorID: vendor.id) {
            let resolved = store.vendor(id: charge.vendorID!).flatMap { store.category(id: $0.categoryID) }
            XCTAssertEqual(resolved?.id, feed.id)
        }
    }

    // MARK: - Suggestions

    @MainActor
    func testSuggestionMatchesExistingCategory() async throws {
        let suggester = FakeFinanceSuggester(answer: "groceries")
        let store = try tempStore(suggester: suggester)
        let feed = store.createCategory(name: "Groceries")!
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)

        await store.requestSuggestion(vendorID: outcome.newVendors[0].id)

        XCTAssertEqual(store.vendor(id: outcome.newVendors[0].id)?.categoryID, feed.id)
        XCTAssertEqual(store.vendor(id: outcome.newVendors[0].id)?.suggestion, .suggested)
        XCTAssertEqual(store.ledger.categories.count, 2)
        XCTAssertEqual(suggester.calls.count, 1)
    }

    @MainActor
    func testSuggestionOutsideListLeavesUncategorized() async throws {
        let suggester = FakeFinanceSuggester(answer: "Vet Care")
        let store = try tempStore(suggester: suggester)
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)

        await store.requestSuggestion(vendorID: outcome.newVendors[0].id)

        // The model may only pick from the existing list. An invented name
        // creates nothing and the vendor stays Uncategorized.
        XCTAssertEqual(store.ledger.categories.count, 1)
        let vendor = store.vendor(id: outcome.newVendors[0].id)
        XCTAssertEqual(vendor?.categoryID, store.uncategorizedID)
        XCTAssertEqual(vendor?.suggestion, .notObvious)
        XCTAssertEqual(suggester.calls.count, 1)
    }

    @MainActor
    func testUncategorizedAnswerLeavesUncategorized() async throws {
        let store = try tempStore(suggester: FakeFinanceSuggester(answer: "Uncategorized"))
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)

        await store.requestSuggestion(vendorID: outcome.newVendors[0].id)

        XCTAssertEqual(store.ledger.categories.count, 1)
        let vendor = store.vendor(id: outcome.newVendors[0].id)
        XCTAssertEqual(vendor?.categoryID, store.uncategorizedID)
        XCTAssertEqual(vendor?.suggestion, .notObvious)
    }

    @MainActor
    func testSuggestionNeverOverwritesHisAssignment() async throws {
        let suggester = FakeFinanceSuggester(answer: "Groceries")
        let store = try tempStore(suggester: suggester)
        _ = store.createCategory(name: "Groceries")
        let manual = store.createCategory(name: "Manual")!
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)
        let vendorID = outcome.newVendors[0].id
        store.assign(vendorID: vendorID, categoryID: manual.id)

        // His assignment is the rule: the model is not even asked.
        await store.requestSuggestion(vendorID: vendorID)

        XCTAssertEqual(store.vendor(id: vendorID)?.categoryID, manual.id)
        XCTAssertNil(store.vendor(id: vendorID)?.suggestion)
        XCTAssertTrue(suggester.calls.isEmpty)
    }

    @MainActor
    func testUnavailableSuggestionLeavesUncategorized() async throws {
        let store = try tempStore(suggester: FakeFinanceSuggester(answer: nil))
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)

        await store.requestSuggestion(vendorID: outcome.newVendors[0].id)

        let vendor = store.vendor(id: outcome.newVendors[0].id)
        XCTAssertEqual(vendor?.categoryID, store.uncategorizedID)
        XCTAssertEqual(vendor?.suggestion, .unavailable)
    }

    @MainActor
    func testManualAssignClearsSuggestion() async throws {
        let store = try tempStore(suggester: FakeFinanceSuggester(answer: "Vet Care"))
        _ = store.createCategory(name: "Vet Care")
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)
        let vendorID = outcome.newVendors[0].id
        await store.requestSuggestion(vendorID: vendorID)
        XCTAssertEqual(store.vendor(id: vendorID)?.suggestion, .suggested)

        let other = store.createCategory(name: "Manual")!
        store.assign(vendorID: vendorID, categoryID: other.id)
        XCTAssertNil(store.vendor(id: vendorID)?.suggestion)
        XCTAssertEqual(store.vendor(id: vendorID)?.categoryID, other.id)
    }

    // MARK: - Suggester hygiene

    func testPromptCarriesNoStatementData() {
        let prompt = RanchOSFinanceSuggester.prompt(
            vendorName: "FARM SUPPLY COOP",
            categories: ["Uncategorized", "Feed & Seed"])
        XCTAssertTrue(prompt.contains("FARM SUPPLY COOP"))
        XCTAssertTrue(prompt.contains("Feed & Seed"))
        XCTAssertFalse(prompt.contains("84.12"))
        XCTAssertFalse(prompt.contains("-500.00"))
        XCTAssertFalse(prompt.contains("2318.44"))
        XCTAssertFalse(prompt.contains("Transaction Date"))
    }

    func testCleanedSuggestionIsOneShortLine() {
        XCTAssertEqual(RanchOSFinanceSuggester.clean("  \"Vet Care\"\nExtra line"), "Vet Care")
        XCTAssertNil(RanchOSFinanceSuggester.clean("   "))
        XCTAssertNil(RanchOSFinanceSuggester.clean(String(repeating: "x", count: 65)))
    }

    func testLiveSuggesterReturnsNilOrValidName() async {
        let live = RanchOSFinanceLiveSuggester()
        let result = await live.suggestCategory(vendorName: "FARM SUPPLY COOP", categories: ["Uncategorized"])
        if let result {
            XCTAssertEqual(RanchOSFinanceSuggester.clean(result), result)
        }
    }

    // MARK: - Persistence round-trip

    @MainActor
    func testRelaunchRestoresFilesVendorsAndAssignments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")

        let first = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let card = try fixtureBytes("FinanceSampleAppleCard")
        let bank = try fixtureBytes("FinanceSampleBank")
        _ = first.ingest(fileName: "card.csv", bytes: card)
        let bankOutcome = first.ingest(fileName: "bank.csv", bytes: bank)
        let feed = first.createCategory(name: "Feed & Seed")!
        first.assign(vendorID: bankOutcome.newVendors[0].id, categoryID: feed.id)
        XCTAssertEqual(first.ledger.files.count, 2)
        XCTAssertEqual(first.ledger.vendors.count, 7)
        let freshID = first.ledger.vendors.first(where: { $0.key == "fresh fields market" })!.id

        let second = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertEqual(second.ledger.files.count, 2)
        XCTAssertEqual(second.ledger.charges.count, first.ledger.charges.count)
        XCTAssertEqual(second.ledger.vendors.count, 7)
        XCTAssertEqual(second.vendor(id: bankOutcome.newVendors[0].id)?.categoryID, feed.id)
        // Uncategorized, six Apple values, and Feed & Seed.
        XCTAssertEqual(second.ledger.categories.count, 8)
        // The Apple placement and the kept Category cell survive.
        let freshVendor = second.vendor(id: freshID)!
        XCTAssertEqual(second.category(id: freshVendor.categoryID)?.name, "Groceries")
        XCTAssertTrue(second.ledger.charges.contains(where: {
            $0.vendorID == freshID && $0.appleCategoryText == "Groceries"
        }))
    }

    // MARK: - Store: Apple placement

    @MainActor
    func testAppleValueReusesHisCategoryCaseInsensitively() throws {
        let store = try tempStore()
        let his = store.createCategory(name: "groceries")!
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)

        XCTAssertEqual(store.ledger.categories.filter { $0.name.lowercased() == "groceries" }.count, 1)
        let freshID = store.ledger.vendors.first(where: { $0.key == "fresh fields market" })!.id
        XCTAssertEqual(store.vendor(id: freshID)?.categoryID, his.id)
    }

    @MainActor
    func testMixedAppleCategoriesLeaveVendorUncategorized() throws {
        let store = try tempStore()
        let bytes = Data(
            "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n09/20/2026,09/22/2026,Dinner,Mixed Shop,Dining,purchase,30.00,Sam\n09/21/2026,09/23/2026,Fuel,Mixed Shop,Travel,purchase,40.00,Sam\n".utf8)
        let outcome = store.ingest(fileName: "mixed.csv", bytes: bytes)

        XCTAssertEqual(outcome.newVendors.count, 1)
        XCTAssertEqual(outcome.newVendors.first?.categoryID, store.uncategorizedID)
        // Both values still become categories.
        XCTAssertTrue(store.ledger.categories.contains(where: { $0.name == "Dining" }))
        XCTAssertTrue(store.ledger.categories.contains(where: { $0.name == "Travel" }))
    }

    @MainActor
    func testBlankAppleCategoryLeavesVendorUncategorized() throws {
        let store = try tempStore()
        let bytes = Data(
            "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n09/20/2026,09/22/2026,No category shown,Blank Shop,,purchase,12.00,Sam\n".utf8)
        let outcome = store.ingest(fileName: "blank.csv", bytes: bytes)

        XCTAssertEqual(outcome.newVendors.count, 1)
        XCTAssertEqual(outcome.newVendors.first?.categoryID, store.uncategorizedID)
        XCTAssertEqual(store.ledger.categories.count, 1)
    }

    @MainActor
    func testSecondIngestDoesNotMoveHisVendor() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let manual = store.createCategory(name: "Manual")!
        let freshID = store.ledger.vendors.first(where: { $0.key == "fresh fields market" })!.id
        store.assign(vendorID: freshID, categoryID: manual.id)

        let second = Data(
            "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n09/20/2026,09/22/2026,More groceries,Fresh Fields Market,Dining,purchase,12.00,Sam\n".utf8)
        let outcome = store.ingest(fileName: "card2.csv", bytes: second)

        XCTAssertTrue(outcome.newVendors.isEmpty)
        XCTAssertEqual(store.vendor(id: freshID)?.categoryID, manual.id)
        XCTAssertTrue(store.ledger.categories.contains(where: { $0.name == "Dining" }))
    }

    @MainActor
    func testBankFileCreatesNoCategories() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleBank")
        let outcome = store.ingest(fileName: "bank.csv", bytes: bytes)

        XCTAssertEqual(store.ledger.categories.count, 1)
        for vendor in outcome.newVendors {
            XCTAssertEqual(vendor.categoryID, store.uncategorizedID)
        }
        XCTAssertTrue(store.ledger.charges.allSatisfy { $0.appleCategoryText == nil })
    }

    @MainActor
    func testSuggestionSkipsPlacedVendorButServesUncategorized() async throws {
        let suggester = FakeFinanceSuggester(answer: "Payment")
        let store = try tempStore(suggester: suggester)
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let freshID = store.ledger.vendors.first(where: { $0.key == "fresh fields market" })!.id
        let appleID = store.ledger.vendors.first(where: { $0.key == "apple card" })!.id

        await store.requestSuggestion(vendorID: freshID)
        XCTAssertTrue(suggester.calls.isEmpty)
        XCTAssertNil(store.vendor(id: freshID)?.suggestion)

        // Payment came from the file; the obvious-name path may pick it.
        await store.requestSuggestion(vendorID: appleID)
        XCTAssertEqual(suggester.calls.count, 1)
        let payment = store.ledger.categories.first(where: { $0.name == "Payment" })!
        XCTAssertEqual(store.vendor(id: appleID)?.categoryID, payment.id)
        XCTAssertEqual(store.vendor(id: appleID)?.suggestion, .suggested)
    }

    // MARK: - Store: charge assignment

    @MainActor
    func testChargeAssignmentWinsOverVendorRule() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let seed = store.createCategory(name: "Seed")!
        let groceries = store.ledger.categories.first(where: { $0.name == "Groceries" })!
        let ids = store.ledger.charges
            .filter { $0.merchantText == "Fresh Fields Market" }
            .map(\.id)
        XCTAssertEqual(ids.count, 2)

        store.assign(chargeID: ids[0], categoryID: seed.id)

        let first = store.ledger.charges.first(where: { $0.id == ids[0] })!
        let second = store.ledger.charges.first(where: { $0.id == ids[1] })!
        XCTAssertEqual(store.categoryID(for: first), seed.id)
        XCTAssertEqual(store.categoryID(for: second), groceries.id)
        XCTAssertEqual(store.vendor(id: first.vendorID!)?.categoryID, groceries.id)
    }

    @MainActor
    func testBulkAssignByFilterLeavesVendorRule() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let seed = store.createCategory(name: "Seed")!
        let groceries = store.ledger.categories.first(where: { $0.name == "Groceries" })!

        let matched = store.charges(matchingVendorFilter: "fresh")
        XCTAssertEqual(matched.count, 2)
        store.assign(chargeIDs: Set(matched.map(\.id)), categoryID: seed.id)

        for id in matched.map(\.id) {
            let charge = store.ledger.charges.first(where: { $0.id == id })!
            XCTAssertEqual(store.categoryID(for: charge), seed.id)
        }
        XCTAssertEqual(store.vendor(id: matched[0].vendorID!)?.categoryID, groceries.id)
        XCTAssertEqual(store.charges(matchingVendorFilter: "   ").count, store.ledger.charges.count)
        XCTAssertTrue(store.charges(matchingVendorFilter: "zzz-no-such-vendor").isEmpty)
    }

    @MainActor
    func testAssigningVendorCategoryClearsOverride() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let seed = store.createCategory(name: "Seed")!
        let groceries = store.ledger.categories.first(where: { $0.name == "Groceries" })!
        let id = store.ledger.charges.first(where: { $0.merchantText == "Fresh Fields Market" })!.id

        store.assign(chargeID: id, categoryID: seed.id)
        XCTAssertNotNil(store.ledger.charges.first(where: { $0.id == id })?.categoryOverrideID)

        store.assign(chargeID: id, categoryID: groceries.id)
        let charge = store.ledger.charges.first(where: { $0.id == id })!
        XCTAssertNil(charge.categoryOverrideID)
        XCTAssertEqual(store.categoryID(for: charge), groceries.id)
    }

    @MainActor
    func testDeleteCategoryMovesChargeOverridesToUncategorized() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let feed = store.createCategory(name: "Feed")!
        let id = store.ledger.charges.first(where: { $0.merchantText == "Fresh Fields Market" })!.id
        store.assign(chargeID: id, categoryID: feed.id)

        XCTAssertTrue(store.deleteCategory(id: feed.id))

        let charge = store.ledger.charges.first(where: { $0.id == id })!
        XCTAssertEqual(charge.categoryOverrideID, store.uncategorizedID)
        XCTAssertEqual(store.categoryID(for: charge), store.uncategorizedID)
        XCTAssertEqual(vendorCategoryName("fresh fields market", store: store), "Groceries")
    }

    // MARK: - Helpers

    private func fixtureBytes(_ name: String) throws -> Data {
        let bundle = Bundle(for: RanchOSFinanceCategoriesTests.self)
        guard let url = bundle.url(forResource: name, withExtension: "csv") else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(name).csv"])
        }
        return try Data(contentsOf: url)
    }

    @MainActor
    private func tempStore(suggester: FakeFinanceSuggester = FakeFinanceSuggester(answer: nil)) throws -> RanchOSFinanceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return RanchOSFinanceStore(
            persistenceURL: directory.appendingPathComponent("ledger.json"),
            suggester: suggester)
    }

    @MainActor
    private func vendorCategoryName(_ key: String, store: RanchOSFinanceStore) -> String? {
        guard let vendor = store.ledger.vendors.first(where: { $0.key == key }) else { return nil }
        return store.category(id: vendor.categoryID)?.name
    }
}

@MainActor
private final class FakeFinanceSuggester: RanchOSFinanceCategorySuggesting, @unchecked Sendable {
    var answer: String?
    var calls: [(String, [String])] = []

    init(answer: String?) {
        self.answer = answer
    }

    func suggestCategory(vendorName: String, categories: [String]) async -> String? {
        calls.append((vendorName, categories))
        return answer
    }
}
