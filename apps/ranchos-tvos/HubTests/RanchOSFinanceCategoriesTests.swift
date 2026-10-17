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

    @MainActor
    func testCategoryVendorGroupsListAssignments() throws {
        let store = try tempStore()
        let uncategorized = try XCTUnwrap(store.uncategorizedID)
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let fuel = try XCTUnwrap(store.createCategory(name: "Fuel"))
        _ = store.createCategory(name: "Seed")
        store.mutateLedger { ledger in
            ledger.vendors.append(contentsOf: [
                RanchOSFinanceVendor(
                    id: UUID(), name: "Zeta Feed", key: "zeta", categoryID: feed.id, suggestion: nil),
                RanchOSFinanceVendor(
                    id: UUID(), name: "Alpha Feed", key: "alpha", categoryID: feed.id, suggestion: nil),
                RanchOSFinanceVendor(
                    id: UUID(), name: "Fuel Stop", key: "fuel", categoryID: fuel.id, suggestion: nil),
                RanchOSFinanceVendor(
                    id: UUID(), name: "Mystery Shop", key: "mystery", categoryID: uncategorized, suggestion: nil),
            ])
        }

        let groups = store.categoryVendorGroups(matching: "")
        XCTAssertEqual(groups.map(\.category.name), ["Uncategorized", "Feed", "Fuel", "Seed"])
        XCTAssertEqual(groups[0].vendors.map(\.name), ["Mystery Shop"])
        XCTAssertEqual(groups[1].vendors.map(\.name), ["Alpha Feed", "Zeta Feed"])
        XCTAssertTrue(groups[3].vendors.isEmpty)

        let byCategory = store.categoryVendorGroups(matching: "feed")
        XCTAssertEqual(byCategory.map(\.category.name), ["Feed"])
        XCTAssertEqual(byCategory[0].vendors.map(\.name), ["Alpha Feed", "Zeta Feed"])

        let byVendor = store.categoryVendorGroups(matching: "zeta")
        XCTAssertEqual(byVendor.map(\.category.name), ["Feed"])
        XCTAssertEqual(byVendor[0].vendors.map(\.name), ["Zeta Feed"])

        XCTAssertTrue(store.categoryVendorGroups(matching: "seed")[0].vendors.isEmpty)
        XCTAssertTrue(store.categoryVendorGroups(matching: "no such vendor").isEmpty)

        let mystery = try XCTUnwrap(groups[0].vendors.first)
        store.assign(vendorID: mystery.id, categoryID: fuel.id)
        let moved = store.categoryVendorGroups(matching: "")
        XCTAssertTrue(moved[0].vendors.isEmpty)
        XCTAssertEqual(moved[2].vendors.map(\.name), ["Fuel Stop", "Mystery Shop"])
    }

    @MainActor
    func testAddingACategoryFromAVendorBuildsTheList() throws {
        let store = try tempStore()
        let uncategorized = try XCTUnwrap(store.uncategorizedID)
        let vendor = RanchOSFinanceVendor(
            id: UUID(), name: "Creek Supply", key: "creek", categoryID: uncategorized, suggestion: .notObvious)
        store.mutateLedger { $0.vendors.append(vendor) }

        let created = store.addCategory(name: "  Fence  ", forVendor: vendor.id)
        XCTAssertNil(created.problem)
        let fence = try XCTUnwrap(store.category(id: try XCTUnwrap(created.categoryID)))
        XCTAssertEqual(fence.name, "Fence")
        XCTAssertEqual(store.vendor(id: vendor.id)?.categoryID, fence.id)
        XCTAssertNil(store.vendor(id: vendor.id)?.suggestion)
        XCTAssertEqual(store.categoryVendorGroups(matching: "fence").map(\.category.name), ["Fence"])

        let again = store.addCategory(name: "fence", forVendor: vendor.id)
        XCTAssertEqual(again.categoryID, fence.id)
        XCTAssertEqual(store.ledger.categories.filter { $0.name.lowercased() == "fence" }.count, 1)

        XCTAssertEqual(store.addCategory(name: "  ", forVendor: vendor.id).problem, "Type a name.")
        XCTAssertEqual(
            store.addCategory(name: String(repeating: "a", count: 65), forVendor: vendor.id).problem,
            "Use 64 characters or fewer.")
        XCTAssertEqual(
            store.addCategory(name: "Other", forVendor: vendor.id).problem,
            "Other is Uncategorized. Choose another name.")
        XCTAssertEqual(store.addCategory(name: "Feed", forVendor: UUID()).problem, "That vendor is gone.")
        XCTAssertEqual(store.vendor(id: vendor.id)?.categoryID, fence.id)
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

        XCTAssertEqual(store.categoryRenameProblem(id: feed.id, newName: " "), "Type a name.")
        XCTAssertEqual(store.categoryRenameProblem(id: feed.id, newName: "SEED"), "SEED is already a category.")
        XCTAssertNotNil(store.categoryRenameProblem(id: feed.id, newName: "other"))
        XCTAssertNil(store.categoryRenameProblem(id: feed.id, newName: "Hay"))
        let uncategorized = try XCTUnwrap(store.uncategorizedID)
        XCTAssertEqual(store.categoryRenameProblem(id: uncategorized, newName: "Misc"), "Uncategorized keeps its name.")
        XCTAssertFalse(store.renameCategory(id: uncategorized, newName: "Misc"))
        XCTAssertEqual(store.category(id: uncategorized)?.name, "Uncategorized")
    }

    @MainActor
    func testRenameCategoryRenamesItsHistoryRows() throws {
        let store = try tempStore()
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Alpha Feed,Feed,purchase,12.00,Sam
        07/02/2026,07/02/2026,B,Beta Shop,Shopping,purchase,8.00,Sam
        """
        let file = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8)).file
        _ = try XCTUnwrap(store.archiveStatement(fileID: file.id))
        XCTAssertTrue(store.renameCategory(id: feed.id, newName: "Feed & Hay"))
        let names = store.ledger.archives.flatMap(\.charges).map(\.categoryName)
        XCTAssertTrue(names.contains("Feed & Hay"))
        XCTAssertFalse(names.contains("Feed"))
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
    func testAppleOtherStaysUncategorizedAndOtherLoansStays() throws {
        let store = try tempStore()
        let bytes = Data(
            "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n09/20/2026,09/22/2026,Misc,Sample Shop,Other,purchase,12.00,Sam\n09/21/2026,09/22/2026,Loan,Other Loans Shop,Other Loans,purchase,8.00,Sam\n".utf8)
        _ = store.ingest(fileName: "other.csv", bytes: bytes)

        XCTAssertEqual(vendorCategoryName("sample shop", store: store), "Uncategorized")
        XCTAssertEqual(vendorCategoryName("other loans shop", store: store), "Other Loans")
        XCTAssertFalse(store.ledger.categories.contains { $0.name.lowercased() == "other" })
        XCTAssertEqual(store.createCategory(name: " Other ")?.id, store.uncategorizedID)
        let loans = try XCTUnwrap(store.ledger.categories.first { $0.name == "Other Loans" })
        XCTAssertFalse(store.renameCategory(id: loans.id, newName: "Other"))
        XCTAssertEqual(store.category(id: loans.id)?.name, "Other Loans")
    }

    @MainActor
    func testSavedOtherCategoryFoldsIntoUncategorized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let uncategorized = try XCTUnwrap(store.uncategorizedID)
        let otherID = UUID()
        let vendorID = UUID()
        let profileID = UUID()
        let chargeID = UUID()
        store.mutateLedger { ledger in
            ledger.categories.append(RanchOSFinanceCategory(
                id: otherID, name: "Other", isUncategorized: false))
            ledger.categories.append(RanchOSFinanceCategory(
                id: UUID(), name: "Other Loans", isUncategorized: false))
            ledger.vendors.append(RanchOSFinanceVendor(
                id: vendorID, name: "Sample Shop", key: "sample shop",
                categoryID: otherID, suggestion: .suggested))
            ledger.charges.append(RanchOSFinanceCharge(
                id: chargeID, fileID: UUID(), dateText: "09/01/2026",
                merchantText: "Sample Shop", amountText: "1.00", vendorID: vendorID,
                isDuplicate: false, categoryOverrideID: otherID))
            ledger.chartProfiles.append(RanchOSFinanceChartProfile(
                id: profileID, name: "Kept", categoryIDs: [otherID]))
            ledger.archives.append(RanchOSFinanceArchive(
                id: UUID(), fileID: UUID(), fileName: "sample.csv", source: "Apple",
                rangeLabel: "September 2026", archivedAt: Date(),
                charges: [RanchOSFinanceArchiveCharge(
                    id: UUID(), dateText: "09/01/2026", merchantText: "Sample Shop",
                    amountText: "1.00", categoryName: "Other")]))
        }

        let opened = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertFalse(opened.ledger.categories.contains { $0.name.lowercased() == "other" })
        XCTAssertTrue(opened.ledger.categories.contains { $0.name == "Other Loans" })
        XCTAssertEqual(opened.vendor(id: vendorID)?.categoryID, uncategorized)
        XCTAssertNil(opened.vendor(id: vendorID)?.suggestion)
        XCTAssertEqual(opened.ledger.charges.first { $0.id == chargeID }?.categoryOverrideID, uncategorized)
        XCTAssertEqual(opened.ledger.chartProfiles.first { $0.id == profileID }?.categoryIDs, [uncategorized])
        XCTAssertEqual(opened.ledger.archives.first?.charges.first?.categoryName, "Uncategorized")
    }

    @MainActor
    func testDeleteCategoryMovesHistoryToUncategorized() throws {
        let store = try tempStore()
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        store.mutateLedger { ledger in
            ledger.archives.append(RanchOSFinanceArchive(
                id: UUID(), fileID: UUID(), fileName: "sample.csv", source: "Bank",
                rangeLabel: "September 2026", archivedAt: Date(),
                charges: [RanchOSFinanceArchiveCharge(
                    id: UUID(), dateText: "09/01/2026", merchantText: "Sample Shop",
                    amountText: "1.00", categoryName: "Feed")]))
        }

        XCTAssertTrue(store.deleteCategory(id: feed.id))
        XCTAssertEqual(store.ledger.archives.first?.charges.first?.categoryName, "Uncategorized")
        XCTAssertNil(store.ledger.categories.first { $0.name == "Feed" })
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

    @MainActor
    func testSourceDateRangeAndMonthsAlreadyIn() throws {
        let store = try tempStore()
        let apple = try fixtureBytes("FinanceSampleAppleCard")
        let appleFile = store.ingest(fileName: "card.csv", bytes: apple, source: "Apple").file
        XCTAssertEqual(appleFile.source, "Apple")
        XCTAssertEqual(store.dateRangeLabel(fileID: appleFile.id), "September 2026")
        XCTAssertEqual(RanchOSFinanceDates.display("09/01/2026"), "Sep 1, 2026")

        let june = Data("Posted Date,Memo,Amount\n06/02/2026,FARM SUPPLY COOP,-10.00\n07/15/2026,HARDWARE HANK,-4.00\n".utf8)
        let july = Data("Posted Date,Memo,Amount\n07/04/2026,CAPITAL ONE,-20.00\n".utf8)
        let juneFile = store.ingest(fileName: "chase.csv", bytes: june, source: "Chase").file
        let capital = store.ingest(fileName: "capital.csv", bytes: july, source: "Capital One").file
        XCTAssertEqual(store.dateRangeLabel(fileID: juneFile.id), "Jun 2, 2026 – Jul 15, 2026")
        XCTAssertEqual(store.dateRangeLabel(fileID: capital.id), "July 2026")

        let months = store.monthsAlreadyIn()
        XCTAssertEqual(months.map(\.source), ["Apple", "Capital One", "Chase", "Chase"])
        XCTAssertEqual(months.map(\.label), ["September 2026", "July 2026", "June 2026", "July 2026"])

        XCTAssertFalse(store.setSource(fileID: juneFile.id, source: "   "))
        XCTAssertTrue(store.setSource(fileID: juneFile.id, source: "Chase Checking"))
        XCTAssertEqual(store.monthsAlreadyIn().filter { $0.source == "Chase Checking" }.map(\.label), ["June 2026", "July 2026"])
        let august = Data("Posted Date,Memo,Amount\n08/01/2026,OTHER SHOP,-3.00\n".utf8)
        let unlabeled = store.ingest(fileName: "blank.csv", bytes: august, source: "   ").file
        XCTAssertNil(unlabeled.source)
        XCTAssertEqual(
            store.monthsAlreadyIn().first { $0.source == RanchOSFinanceDates.missingSource }?.label,
            "August 2026")
    }

    @MainActor
    func testArchiveKeepsTheAssignedCategories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let file = store.ingest(fileName: "card.csv", bytes: bytes, source: "Apple").file
        let seed = store.createCategory(name: "Seed")!
        let charge = store.ledger.charges.first(where: { $0.merchantText == "Fresh Fields Market" })!
        store.assign(chargeID: charge.id, categoryID: seed.id)

        let archived = store.archiveStatement(fileID: file.id)
        XCTAssertEqual(archived?.source, "Apple")
        XCTAssertEqual(archived?.rangeLabel, "September 2026")
        XCTAssertEqual(archived?.charges.count, store.charges(fileID: file.id).count)
        let frozen = archived?.charges.first(where: { $0.id == charge.id })
        XCTAssertEqual(frozen?.categoryName, "Seed")
        XCTAssertEqual(RanchOSFinanceDates.display(frozen?.dateText ?? ""), "Sep 1, 2026")

        let pets = store.createCategory(name: "Pets")!
        store.assign(chargeID: charge.id, categoryID: pets.id)
        XCTAssertEqual(store.archive(fileID: file.id)?.charges.first(where: { $0.id == charge.id })?.categoryName, "Seed")

        let updated = store.archiveStatement(fileID: file.id)
        XCTAssertEqual(updated?.id, archived?.id)
        XCTAssertEqual(store.ledger.archives.count, 1)
        XCTAssertEqual(updated?.charges.first(where: { $0.id == charge.id })?.categoryName, "Pets")

        let reloaded = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertEqual(reloaded.ledger.archives.count, 1)
        XCTAssertEqual(reloaded.ledger.archives[0].rangeLabel, "September 2026")
        XCTAssertEqual(
            reloaded.ledger.archives[0].charges.first(where: { $0.id == charge.id })?.categoryName,
            "Pets")
    }

    @MainActor
    func testEveryChargeFromSupplierIsRemembered() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: bytes)
        let seed = store.createCategory(name: "Seed")!
        let charges = store.ledger.charges.filter { $0.merchantText == "Fresh Fields Market" }
        XCTAssertEqual(charges.count, 2)
        let vendorID = charges[0].vendorID!
        store.assign(chargeID: charges[0].id, categoryID: seed.id)
        XCTAssertNotNil(store.ledger.charges.first(where: { $0.id == charges[0].id })?.categoryOverrideID)

        store.assignEveryCharge(vendorID: vendorID, categoryID: seed.id)

        for charge in store.ledger.charges where charge.vendorID == vendorID {
            XCTAssertNil(charge.categoryOverrideID)
            XCTAssertEqual(store.categoryID(for: charge), seed.id)
        }
        let vendor = store.vendor(id: vendorID)
        XCTAssertEqual(vendor?.categoryID, seed.id)
        XCTAssertNil(vendor?.suggestion)
        let other = store.ledger.charges.first(where: { $0.merchantText == "Hilltop Hardware" })!
        XCTAssertNotEqual(store.categoryID(for: other), seed.id)

        let later = Data(
            "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n10/01/2026,10/02/2026,More groceries,Fresh Fields Market,Groceries,purchase,12.00,Sam Sample\n".utf8)
        _ = store.ingest(fileName: "later.csv", bytes: later)
        let added = store.ledger.charges.filter { $0.merchantText == "Fresh Fields Market" }
        XCTAssertEqual(added.count, 3)
        for charge in added {
            XCTAssertEqual(store.categoryID(for: charge), seed.id)
            XCTAssertNil(charge.categoryOverrideID)
        }
        XCTAssertEqual(store.vendor(id: vendorID)?.categoryID, seed.id)
    }

    @MainActor
    func testAssignmentCanChangeImportAndHistorySeparately() throws {
        let store = try tempStore()
        let bytes = try fixtureBytes("FinanceSampleAppleCard")
        let file = store.ingest(fileName: "card.csv", bytes: bytes, source: "Apple").file
        let seed = store.createCategory(name: "Seed")!
        let pets = store.createCategory(name: "Pets")!
        let fresh = store.ledger.charges.filter { $0.merchantText == "Fresh Fields Market" }
        XCTAssertEqual(fresh.count, 2)
        let hilltop = store.ledger.charges.first { $0.merchantText == "Hilltop Hardware" }!
        let vendorID = fresh[0].vendorID!
        let supplierCategory = store.vendor(id: vendorID)!.categoryID
        store.assign(chargeID: fresh[0].id, categoryID: seed.id)
        store.archiveStatement(fileID: file.id)

        store.applyAssignment(
            chargeID: fresh[0].id, categoryID: pets.id, currentImport: false, history: false)
        XCTAssertEqual(store.categoryName(for: liveCharge(store, fresh[0].id)), "Pets")
        XCTAssertNotEqual(store.categoryName(for: liveCharge(store, fresh[1].id)), "Pets")
        XCTAssertEqual(historyName(store, fileID: file.id, chargeID: fresh[0].id), "Seed")

        store.applyAssignment(
            chargeID: fresh[0].id, categoryID: pets.id, currentImport: true, history: false)
        for charge in store.ledger.charges where charge.vendorID == vendorID {
            XCTAssertEqual(store.categoryName(for: charge), "Pets")
        }
        XCTAssertNotEqual(store.categoryName(for: hilltop), "Pets")
        XCTAssertEqual(historyName(store, fileID: file.id, chargeID: fresh[0].id), "Seed")
        XCTAssertEqual(store.vendor(id: vendorID)?.categoryID, supplierCategory)

        let feed = store.createCategory(name: "Feed")!
        store.applyAssignment(
            chargeID: fresh[1].id, categoryID: feed.id, currentImport: false, history: true)
        XCTAssertEqual(store.categoryName(for: liveCharge(store, fresh[1].id)), "Feed")
        XCTAssertEqual(store.categoryName(for: liveCharge(store, fresh[0].id)), "Pets")
        let archived = store.archive(fileID: file.id)!
        let freshKey = RanchOSFinanceStore.vendorKey("Fresh Fields Market")
        let archivedFresh = archived.charges.filter { RanchOSFinanceStore.vendorKey($0.merchantText) == freshKey }
        XCTAssertEqual(archivedFresh.count, 2)
        XCTAssertTrue(archivedFresh.allSatisfy { $0.categoryName == "Feed" })
        XCTAssertNotEqual(historyName(store, fileID: file.id, chargeID: hilltop.id), "Feed")
        XCTAssertEqual(store.vendor(id: vendorID)?.categoryID, supplierCategory)
    }

    @MainActor
    func testTypedLoanCanBeRenamed() throws {
        let store = try tempStore()
        let typed = try XCTUnwrap(store.createAccount(name: "Farm note", kind: .loan))
        let listed = try XCTUnwrap(store.createAccount(name: "Wells Fargo", kind: .loan))
        let card = try XCTUnwrap(store.createAccount(name: "Chase", kind: .creditCard))
        XCTAssertTrue(store.loanNameWasTyped(typed))
        XCTAssertFalse(store.loanNameWasTyped(listed))
        XCTAssertTrue(store.renameTypedLoan(accountID: typed.id, name: "  Truck note  "))
        XCTAssertEqual(store.ledger.accounts.first { $0.id == typed.id }?.name, "Truck note")
        XCTAssertFalse(store.renameTypedLoan(accountID: listed.id, name: "House loan"))
        XCTAssertEqual(store.ledger.accounts.first { $0.id == listed.id }?.name, "Wells Fargo")
        XCTAssertFalse(store.renameTypedLoan(accountID: card.id, name: "Something"))
        XCTAssertFalse(store.renameTypedLoan(accountID: typed.id, name: "   "))
        let other = try XCTUnwrap(store.createAccount(name: "Pool loan", kind: .loan))
        XCTAssertFalse(store.renameTypedLoan(accountID: typed.id, name: "pool loan"))
        XCTAssertEqual(store.ledger.accounts.first { $0.id == typed.id }?.name, "Truck note")
        XCTAssertEqual(store.ledger.accounts.first { $0.id == other.id }?.name, "Pool loan")

        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Alpha Market,Groceries,purchase,5.00,Sam
        """
        let file = store.ingest(
            fileName: "loan.csv", bytes: Data(csv.utf8), source: "Truck note", accountID: typed.id).file
        XCTAssertTrue(store.renameTypedLoan(accountID: typed.id, name: "Equipment note"))
        XCTAssertEqual(store.file(id: file.id)?.source, "Equipment note")
    }

    @MainActor
    func testVendorParetoInsideOneCategory() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let fuel = try XCTUnwrap(store.createCategory(name: "Fuel"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Alpha Fuel,Fuel,purchase,60.00,Sam
        07/02/2026,07/02/2026,B,Beta Fuel,Fuel,purchase,30.00,Sam
        07/03/2026,07/03/2026,C,Alpha Fuel,Fuel,purchase,20.00,Sam
        07/04/2026,07/04/2026,D,Gamma Market,Groceries,purchase,500.00,Sam
        07/05/2026,07/05/2026,E,Beta Fuel,Fuel,payment,-40.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: apple.name, accountID: apple.id)
        let query = RanchOSFinanceChartQuery(
            account: .all, categoryIDs: [], year: nil, month: nil, money: .expenses, limitsCategories: true)
        let bars = store.vendorTotals(categoryID: fuel.id, query: query)
        XCTAssertEqual(bars.map(\.name), ["Alpha Fuel", "Beta Fuel"])
        XCTAssertEqual(bars.map(\.total), [80, 30])
        let ranked = RanchOSFinancePareto.vendors(from: bars)
        XCTAssertEqual(ranked.filter(\.inEighty).map(\.name), ["Alpha Fuel", "Beta Fuel"])
        XCTAssertEqual(ranked.last?.cumulative, 110)

        var income = query
        income.money = .income
        XCTAssertEqual(store.vendorTotals(categoryID: fuel.id, query: income).map(\.total), [40])
    }

    @MainActor
    func testIncomeAndExpensesIgnoreTheCategoryFilter() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let fuel = try XCTUnwrap(store.createCategory(name: "Fuel"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/20/2026,06/20/2026,A,Alpha Fuel,Fuel,purchase,100.00,Sam
        07/02/2026,07/02/2026,B,Beta Market,Groceries,purchase,50.00,Sam
        07/05/2026,07/05/2026,C,Card payment,Payment,payment,-40.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)
        let fuelOnly = RanchOSFinanceChartQuery(
            account: .all, categoryIDs: [fuel.id], year: nil, month: nil, money: .expenses, limitsCategories: true)
        let all = store.incomeAndExpenses(fuelOnly)
        XCTAssertEqual(all.income, 40)
        XCTAssertEqual(all.expenses, 150)

        let july = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2026, month: 7, day: 1))
        let julyEnd = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2026, month: 7, day: 31))
        let inJuly = store.incomeAndExpenses(fuelOnly, windows: [(july, julyEnd)])
        XCTAssertEqual(inJuly.income, 40)
        XCTAssertEqual(inJuly.expenses, 50)
        XCTAssertEqual(store.incomeAndExpenses(fuelOnly, windows: []).expenses, 0)
    }

    @MainActor
    func testDownloadLinkTakesOnlyWebPages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let bank = try XCTUnwrap(store.createAccount(name: "Prairie Bank", kind: .bank))
        XCTAssertNil(store.ledger.accounts[0].downloadURL)

        XCTAssertNil(store.setDownloadLink(accountID: bank.id, text: "  bank.example/statements "))
        XCTAssertEqual(store.ledger.accounts[0].downloadURL, "https://bank.example/statements")
        for bad in ["file:///etc/hosts", "javascript:alert(1)", "not a link", "localhost", "mailto:a@bank.example"] {
            XCTAssertNotNil(store.setDownloadLink(accountID: bank.id, text: bad), bad)
        }
        XCTAssertEqual(store.ledger.accounts[0].downloadURL, "https://bank.example/statements")
        XCTAssertNil(store.setDownloadLink(accountID: bank.id, text: "http://Bank.example/csv?x=1"))
        let reopened = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertEqual(reopened.ledger.accounts[0].downloadURL, "http://Bank.example/csv?x=1")

        XCTAssertNil(store.setDownloadLink(accountID: bank.id, text: "   "))
        XCTAssertNil(store.ledger.accounts[0].downloadURL)
        XCTAssertEqual(store.setDownloadLink(accountID: UUID(), text: "bank.example"), "That account is gone.")
    }

    func testStatementIsFiledInTheAccountFolder() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let folder = root.appendingPathComponent("Prairie Bank", isDirectory: true)
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let july = downloads.appendingPathComponent("statement.csv")
        try Data("Posted Date,Memo,Amount\n07/02/2026,CREEK SUPPLY,-30.00\n".utf8).write(to: july)
        let filed = try RanchOSFinanceAccountFolders.file(july, into: folder)
        XCTAssertEqual(filed.lastPathComponent, "statement.csv")
        XCTAssertEqual(filed.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: filed), try Data(contentsOf: july))
        XCTAssertTrue(manager.fileExists(atPath: july.path))

        XCTAssertEqual(try RanchOSFinanceAccountFolders.file(july, into: folder).lastPathComponent, "statement.csv")
        XCTAssertEqual(try RanchOSFinanceAccountFolders.file(filed, into: folder), filed)

        try Data("Posted Date,Memo,Amount\n08/02/2026,CREEK SUPPLY,-40.00\n".utf8).write(to: july)
        XCTAssertEqual(try RanchOSFinanceAccountFolders.file(july, into: folder).lastPathComponent, "statement 2.csv")
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path).sorted(), ["statement 2.csv", "statement.csv"])
    }

    @MainActor
    func testTypedNamesJoinThatTypesPicker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertTrue(store.pickerNames(for: .other).isEmpty)

        let creek = try XCTUnwrap(store.createAccount(name: "Creek Bank", kind: .bank))
        _ = try XCTUnwrap(store.createAccount(name: "Feed Store Tab", kind: .other))
        _ = try XCTUnwrap(store.createAccount(name: "Chase", kind: .bank))
        XCTAssertTrue(store.pickerNames(for: .bank).contains("Creek Bank"))
        XCTAssertFalse(store.pickerNames(for: .creditCard).contains("Creek Bank"))
        XCTAssertEqual(store.pickerNames(for: .other), ["Feed Store Tab"])
        XCTAssertEqual(store.pickerNames(for: .bank).filter { $0 == "Chase" }.count, 1)
        let banks = store.pickerNames(for: .bank)
        XCTAssertEqual(banks, banks.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        store.deleteAccount(id: creek.id)
        XCTAssertTrue(store.pickerNames(for: .bank).contains("Creek Bank"))
        let reopened = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertTrue(reopened.pickerNames(for: .bank).contains("Creek Bank"))
        XCTAssertEqual(reopened.pickerNames(for: .other), ["Feed Store Tab"])

        let note = try XCTUnwrap(store.createAccount(name: "Frm note", kind: .loan, purpose: "Truck"))
        XCTAssertTrue(store.renameTypedLoan(accountID: note.id, name: "Farm note"))
        XCTAssertTrue(store.pickerNames(for: .loan).contains("Farm note"))
        XCTAssertFalse(store.pickerNames(for: .loan).contains("Frm note"))
    }

    @MainActor
    func testOlderLedgerAccountsSeedThePicker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        var ledger = RanchOSFinanceStore.freshLedger()
        ledger.accounts = [RanchOSFinanceAccount(id: UUID(), name: "Prairie Credit Union", kind: .loan, purpose: "Pool")]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        json.removeValue(forKey: "addedNames")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertTrue(store.pickerNames(for: .loan).contains("Prairie Credit Union"))
        XCTAssertEqual(store.ledger.addedNames, [RanchOSFinanceAddedName(kind: .loan, name: "Prairie Credit Union")])
    }

    @MainActor
    func testRemovingAnAccountListsWhatChanges() throws {
        let store = try tempStore()
        let empty = try XCTUnwrap(store.createAccount(name: "Prairie Bank", kind: .bank))
        XCTAssertEqual(store.accountRemovalConsequences(id: empty.id), [
            "Prairie Bank leaves the Accounts list, with its type.",
            "No transactions are tied to it, so nothing else changes.",
        ])

        let card = try XCTUnwrap(store.createAccount(name: "Capital One", kind: .creditCard))
        XCTAssertNil(store.setDownloadLink(accountID: card.id, text: "bank.example/statements"))
        let csv = """
        Posted Date,Memo,Amount
        07/02/2026,CREEK SUPPLY,30.00
        07/03/2026,ALPHA FUEL,20.00
        """
        _ = store.ingest(fileName: "card.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)
        let lines = store.accountRemovalConsequences(id: card.id)
        XCTAssertEqual(lines.first, "Capital One leaves the Accounts list, with its type, and its download page link.")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Its 2 transactions stay") })
        XCTAssertTrue(lines.contains { $0.contains("purchases would count as income") })
        XCTAssertTrue(lines.contains { $0.contains("not deleted") })

        let bank = try XCTUnwrap(store.createAccount(name: "Creek Bank", kind: .bank))
        let bankCSV = """
        Posted Date,Memo,Amount
        07/04/2026,GAMMA MARKET,-15.00
        """
        _ = store.ingest(fileName: "bank.csv", bytes: Data(bankCSV.utf8), source: bank.name, accountID: bank.id)
        let bankLines = store.accountRemovalConsequences(id: bank.id)
        XCTAssertTrue(bankLines.contains { $0.hasPrefix("Its 1 transaction stays") })
        XCTAssertFalse(bankLines.contains { $0.contains("bank way") })

        store.deleteAccount(id: card.id)
        XCTAssertTrue(store.accountRemovalConsequences(id: card.id).isEmpty)
        XCTAssertEqual(store.ledger.charges.count, 3)
    }

    @MainActor
    func testSameLenderLoansNeedDifferentPurposes() throws {
        let store = try tempStore()
        let house = try XCTUnwrap(store.createAccount(name: "Prairie Bank", kind: .loan, purpose: "House"))
        XCTAssertNil(store.accountAddProblem(name: "prairie bank", kind: .loan, purpose: "Pasture"))
        let pasture = try XCTUnwrap(store.createAccount(name: "prairie bank", kind: .loan, purpose: " Pasture "))
        XCTAssertNotNil(store.accountAddProblem(name: "Prairie Bank", kind: .loan, purpose: "house"))
        XCTAssertNil(store.createAccount(name: "Prairie Bank", kind: .loan, purpose: "house"))
        XCTAssertNil(store.accountAddProblem(name: "Prairie Bank", kind: .creditCard, purpose: nil))
        let card = try XCTUnwrap(store.createAccount(name: "Prairie Bank", kind: .creditCard))
        XCTAssertNotNil(store.accountAddProblem(name: "Prairie Bank", kind: .creditCard, purpose: nil))
        XCTAssertEqual(store.ledger.accounts.count, 3)

        XCTAssertEqual(store.accountDisplayName(house), "Prairie Bank · House")
        XCTAssertEqual(store.accountDisplayName(pasture), "prairie bank · Pasture")
        XCTAssertEqual(store.accountDisplayName(card), "Prairie Bank")
        XCTAssertEqual(store.accountLabel(pasture), "prairie bank · Pasture · Loan")

        let accounts = store.ledger.accounts
        XCTAssertEqual(RanchOSFinanceAccountFolders.folderName(for: house, among: accounts), "Prairie Bank - Loan")
        XCTAssertEqual(
            RanchOSFinanceAccountFolders.folderName(for: pasture, among: accounts), "prairie bank - Loan - Pasture")
        XCTAssertEqual(
            RanchOSFinanceAccountFolders.folderName(for: card, among: accounts), "Prairie Bank - Credit card")
    }

    @MainActor
    func testLoanPurposeIsKeptOnlyForALoan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let loan = try XCTUnwrap(store.createAccount(name: "Wells Fargo", kind: .loan, purpose: "  House  "))
        let card = try XCTUnwrap(store.createAccount(name: "Chase", kind: .creditCard, purpose: "Ignored"))
        XCTAssertEqual(loan.purpose, "House")
        XCTAssertNil(card.purpose)
        store.setLoanPurpose(accountID: card.id, purpose: "Truck")
        XCTAssertNil(store.ledger.accounts.first { $0.id == card.id }?.purpose)
        store.setLoanPurpose(accountID: loan.id, purpose: "   ")
        XCTAssertNil(store.ledger.accounts.first { $0.id == loan.id }?.purpose)
        store.setLoanPurpose(accountID: loan.id, purpose: "Truck")

        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        for index in accounts.indices {
            accounts[index].removeValue(forKey: "purpose")
        }
        object["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let opened = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertEqual(opened.ledger.accounts.count, 2)
        XCTAssertTrue(opened.ledger.accounts.allSatisfy { $0.purpose == nil })
        opened.setLoanPurpose(accountID: loan.id, purpose: "House")
        let reloaded = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertEqual(reloaded.ledger.accounts.first { $0.id == loan.id }?.purpose, "House")
        XCTAssertNil(reloaded.ledger.accounts.first { $0.id == card.id }?.purpose)
    }

    @MainActor
    func testAccountsBringAStatementIntoRecentAndLeaveHistory() throws {
        let store = try tempStore()
        XCTAssertNil(store.createAccount(name: "   ", kind: .creditCard))
        let citi = try XCTUnwrap(store.createAccount(name: "Citi", kind: .creditCard))
        XCTAssertNil(store.createAccount(name: "citi", kind: .creditCard))
        XCTAssertNotNil(store.createAccount(name: "Citi", kind: .bank))
        XCTAssertNotNil(store.createAccount(name: "Bank of America", kind: .bank))
        XCTAssertEqual(citi.kind, .creditCard)
        XCTAssertEqual(
            store.accountsByName.map(\.name),
            ["Bank of America", "Citi", "Citi"])

        let bytes = try fixtureBytes("FinanceSampleBank")
        let file = store.ingest(fileName: "citi.csv", bytes: bytes, source: citi.name).file
        XCTAssertEqual(file.source, "Citi")
        XCTAssertFalse(store.ledger.charges.isEmpty)
        XCTAssertTrue(store.ledger.archives.isEmpty)

        store.deleteAccount(id: citi.id)
        XCTAssertNil(store.ledger.accounts.first { $0.id == citi.id })
        XCTAssertEqual(store.file(id: file.id)?.source, "Citi")
        XCTAssertFalse(store.ledger.charges.isEmpty)
    }

    @MainActor
    func testPullPlacesChargesOnThatAccount() throws {
        let store = try tempStore()
        let card = try XCTUnwrap(store.createAccount(name: "Citi", kind: .creditCard))
        let bank = try XCTUnwrap(store.createAccount(name: "Citi", kind: .bank))
        let bytes = try fixtureBytes("FinanceSampleBank")
        let file = store.ingest(fileName: "citi.csv", bytes: bytes, source: card.name, accountID: card.id).file
        XCTAssertEqual(file.accountID, card.id)
        XCTAssertEqual(store.charges(forAccount: card.id).count, store.ledger.charges.count)
        XCTAssertTrue(store.charges(forAccount: bank.id).isEmpty)
        XCTAssertEqual(store.recentAccountGroups().map(\.title), ["Citi · Credit card"])

        let again = store.ingest(fileName: "citi-again.csv", bytes: bytes, source: bank.name, accountID: bank.id).file
        XCTAssertEqual(again.id, file.id)
        XCTAssertEqual(again.accountID, card.id)
        XCTAssertTrue(store.charges(forAccount: bank.id).isEmpty)
    }

    @MainActor
    func testAccountMenuAndAutomationCheck() {
        let cards = RanchOSFinanceAccountCatalog.names(for: .creditCard)
        let banks = RanchOSFinanceAccountCatalog.names(for: .bank)
        XCTAssertEqual(cards, cards.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(cards.contains("American Express"))
        XCTAssertFalse(cards.contains("Ally"))
        XCTAssertFalse(cards.contains("Rocket Mortgage"))
        XCTAssertTrue(banks.contains("Bank of America"))
        XCTAssertTrue(banks.contains("Chase"))
        XCTAssertFalse(banks.contains("American Express"))
        XCTAssertFalse(banks.contains("Apple Card"))
        let loans = RanchOSFinanceAccountCatalog.names(for: .loan)
        XCTAssertEqual(loans, loans.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(loans.contains("Rocket Mortgage"))
        XCTAssertTrue(loans.contains("Nelnet"))
        XCTAssertTrue(loans.contains("First United Bank"))
        XCTAssertTrue(loans.contains("TFCU"))
        XCTAssertFalse(loans.contains("American Express"))
        XCTAssertTrue(RanchOSFinanceAccountCatalog.names(for: .other).isEmpty)

        let apple = RanchOSFinanceAccountCatalog.automation(kind: .creditCard, name: "Apple Card")
        XCTAssertFalse(apple.automated)
        XCTAssertTrue(apple.detail.contains("FinanceKit"))

        let citi = RanchOSFinanceAccountCatalog.automation(kind: .creditCard, name: "Citi")
        XCTAssertFalse(citi.automated)
        XCTAssertTrue(citi.detail.contains("sign in"))
        XCTAssertTrue(citi.detail.contains("API"))

        let bank = RanchOSFinanceAccountCatalog.automation(kind: .bank, name: "Bank of America")
        XCTAssertFalse(bank.automated)
        XCTAssertTrue(bank.detail.contains("sign in"))
        XCTAssertFalse(bank.detail.contains("FinanceKit"))
    }

    @MainActor
    func testAccountFolderUsesTheAccountName() {
        let card = RanchOSFinanceAccount(id: UUID(), name: "Citi", kind: .creditCard)
        let bank = RanchOSFinanceAccount(id: UUID(), name: "Citi", kind: .bank)
        XCTAssertEqual(
            RanchOSFinanceAccountFolders.folderName(for: card, among: [card]),
            "Citi")
        XCTAssertEqual(
            RanchOSFinanceAccountFolders.folderName(for: card, among: [card, bank]),
            "Citi - Credit card")
        XCTAssertEqual(
            RanchOSFinanceAccountFolders.folderName(for: bank, among: [card, bank]),
            "Citi - Bank")
        let slash = RanchOSFinanceAccount(id: UUID(), name: "A/B:C", kind: .bank)
        XCTAssertEqual(
            RanchOSFinanceAccountFolders.folderName(for: slash, among: [slash]),
            "A-B-C")
    }

    @MainActor
    func testLedgerWithoutAccountsStillOpens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertNotNil(store.createAccount(name: "Chase", kind: .bank))
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "accounts")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let reloaded = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertTrue(reloaded.ledger.accounts.isEmpty)
        XCTAssertFalse(reloaded.ledger.categories.isEmpty)
    }

    @MainActor
    func testAssignmentCategoriesAreAlphabetical() throws {
        let store = try tempStore()
        store.createCategory(name: "Seed")
        store.createCategory(name: "Fuel")
        store.createCategory(name: "apple")
        XCTAssertEqual(
            store.categoriesByName.map(\.name),
            ["apple", "Fuel", "Seed", "Uncategorized"])
        XCTAssertEqual(
            store.ledger.categories.map(\.name),
            ["Uncategorized", "Seed", "Fuel", "apple"])
    }

    @MainActor
    func testChartsSliceExpensesByCategoryMonthAndWeek() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let bank = try XCTUnwrap(store.createAccount(name: "BancFirst", kind: .bank))
        let appleCSV = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2026,06/02/2026,A,Alpha Market,Groceries,purchase,10.00,Sam
        06/02/2026,06/02/2026,A,Alpha Market,Groceries,purchase,10.00,Sam
        06/10/2026,06/10/2026,B,Beta Fuel,Fuel,purchase,20.00,Sam
        06/18/2026,06/18/2026,C,Alpha Market,Groceries,purchase,30.00,Sam
        06/25/2026,06/25/2026,D,City Power,Utilities,purchase,40.00,Sam
        07/03/2026,07/03/2026,E,Alpha Market,Groceries,purchase,5.00,Sam
        06/04/2026,06/04/2026,Pay,Apple Card,Payment,payment,-100.00,Sam
        """
        let bankCSV = """
        Posted Date,Memo,Amount
        06/03/2026,FARM SUPPLY,-15.00
        06/03/2026,PAYROLL,80.00
        """
        _ = store.ingest(
            fileName: "apple.csv", bytes: Data(appleCSV.utf8), source: apple.name, accountID: apple.id)
        _ = store.ingest(
            fileName: "bank.csv", bytes: Data(bankCSV.utf8), source: bank.name, accountID: bank.id)

        let june = RanchOSFinanceChartQuery(
            account: .account(apple.id), categoryIDs: [], year: 2026, month: 6, money: .expenses)
        let juneBars = store.categoryTotals(june)
        XCTAssertEqual(juneBars.map(\.name), ["Fuel", "Groceries", "Payment", "Uncategorized", "Utilities"])
        XCTAssertEqual(juneBars.map(\.total), [20, 40, 0, 0, 40])
        let weeks = store.weekTotals(year: 2026, month: 6, query: june)
        XCTAssertEqual(weeks.map(\.title), [
            "Week 1 · 1–7", "Week 2 · 8–14", "Week 3 · 15–21", "Week 4 · 22–30",
        ])
        XCTAssertEqual(weeks.map(\.total), [10, 20, 30, 40])

        let groceries = try XCTUnwrap(store.ledger.categories.first { $0.name == "Groceries" }?.id)
        var groceriesOnly = june
        groceriesOnly.categoryIDs = [groceries]
        groceriesOnly.year = nil
        groceriesOnly.month = nil
        XCTAssertEqual(store.categoryTotals(groceriesOnly).map(\.total), [45])

        var income = june
        income.money = .income
        let incomeBars = store.categoryTotals(income)
        XCTAssertEqual(incomeBars.map(\.name), ["Fuel", "Groceries", "Payment", "Uncategorized", "Utilities"])
        XCTAssertEqual(incomeBars.map(\.total), [0, 0, 100, 0, 0])

        let bankJune = RanchOSFinanceChartQuery(
            account: .account(bank.id), categoryIDs: [], year: 2026, month: 6, money: .expenses)
        let bankBars = store.categoryTotals(bankJune)
        XCTAssertEqual(bankBars.map(\.name), ["Fuel", "Groceries", "Payment", "Uncategorized", "Utilities"])
        XCTAssertEqual(bankBars.map(\.total), [0, 0, 0, 15, 0])
        var bankIncome = bankJune
        bankIncome.money = .income
        XCTAssertEqual(store.categoryTotals(bankIncome).map(\.total), [0, 0, 0, 80, 0])

        XCTAssertEqual(
            store.chartMonths(account: .all).map(\.label),
            ["June 2026", "July 2026"])
        let pareto = RanchOSFinancePareto.bars(from: juneBars)
        XCTAssertEqual(pareto.map(\.name), ["Groceries", "Utilities", "Fuel"])
        XCTAssertEqual(pareto.map(\.inEighty), [true, true, false])
    }

    @MainActor
    func testChartTimeFiltersDayWeekHalfAndYear() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2025,06/02/2025,A,Alpha Market,Groceries,purchase,7.00,Sam
        01/10/2026,01/10/2026,B,Beta Fuel,Fuel,purchase,5.00,Sam
        06/02/2026,06/02/2026,C,Alpha Market,Groceries,purchase,10.00,Sam
        08/15/2026,08/15/2026,D,City Power,Utilities,purchase,8.00,Sam
        10/02/2026,10/02/2026,E,Alpha Market,Groceries,purchase,4.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: apple.name, accountID: apple.id)

        XCTAssertEqual(
            RanchOSFinanceChartTime.allCases.map(\.label),
            ["All dates", "Daily", "By week", "By month", "Semi-annual", "Annual", "Same period last year"])
        let jan1 = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2026, month: 1, day: 1))
        let jan7 = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2026, month: 1, day: 7))
        let jan8 = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2026, month: 1, day: 8))
        let dec31 = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2026, month: 12, day: 31))
        let leapEnd = try XCTUnwrap(RanchOSFinanceDates.utcDate(year: 2024, month: 12, day: 31))
        XCTAssertEqual(RanchOSFinanceDates.weekOfYear(jan1), 1)
        XCTAssertEqual(RanchOSFinanceDates.weekOfYear(jan7), 1)
        XCTAssertEqual(RanchOSFinanceDates.weekOfYear(jan8), 2)
        XCTAssertEqual(RanchOSFinanceDates.weekOfYear(dec31), 52)
        XCTAssertEqual(RanchOSFinanceDates.weekOfYear(leapEnd), 52)

        let query = RanchOSFinanceChartQuery(
            account: .account(apple.id), categoryIDs: [], year: nil, month: nil, money: .expenses)
        let weeks = store.periodBars(time: .week, year: 2026, month: 1, half: 1, query: query)
        XCTAssertEqual(weeks.count, 52)
        XCTAssertEqual(weeks.first?.label, "Week 1 · Jan 1–7")
        XCTAssertEqual(weeks.last?.id, "2026-W52")
        XCTAssertEqual(weeks.map(\.total).reduce(0, +), 27)
        let groceries = try XCTUnwrap(store.ledger.categories.first { $0.name == "Groceries" }?.id)
        var groceriesOnly = query
        groceriesOnly.categoryIDs = [groceries]
        groceriesOnly.limitsCategories = true
        let groceryWeeks = store.periodBars(time: .week, year: 2026, month: 1, half: 1, query: groceriesOnly)
        XCTAssertEqual(groceryWeeks.map(\.total).reduce(0, +), 14)

        let months = store.periodBars(time: .month, year: 2026, month: 1, half: 1, query: query)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.map(\.shortLabel), ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])
        XCTAssertEqual(months.map(\.total), [5, 0, 0, 0, 0, 10, 0, 8, 0, 4, 0, 0])
        let rankedMonths = RanchOSFinancePareto.trend(from: months)
        XCTAssertEqual(rankedMonths.map(\.name), ["June 2026", "August 2026", "January 2026", "October 2026"])
        XCTAssertEqual(rankedMonths.map(\.inEighty), [true, true, true, false])

        let half = store.periodBars(time: .semiannual, year: 2026, month: 1, half: 2, query: query)
        XCTAssertEqual(half.map(\.shortLabel), ["Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])
        XCTAssertEqual(half.map(\.total), [0, 8, 0, 4, 0, 0])

        let days = store.periodBars(time: .daily, year: 2026, month: 6, half: 1, query: query)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days[1].total, 10)

        let years = store.periodBars(time: .annual, year: 2026, month: 1, half: 1, query: query)
        XCTAssertEqual(years.map(\.label), ["2025", "2026"])
        XCTAssertEqual(years.map(\.total), [7, 27])
        XCTAssertTrue(store.periodBars(time: .samePeriodLastYear, year: 2026, month: 1, half: 1, query: query).isEmpty)

        let june = try XCTUnwrap(months.first { $0.shortLabel == "Jun" })
        let october = try XCTUnwrap(months.first { $0.shortLabel == "Oct" })
        let picked = store.categoryTotals(query, windows: [(start: june.start, end: june.end), (start: october.start, end: october.end)])
        XCTAssertEqual(picked.first { $0.name == "Groceries" }?.total, 14)
        XCTAssertEqual(picked.first { $0.name == "Fuel" }?.total, 0)
        XCTAssertEqual(picked.first { $0.name == "Utilities" }?.total, 0)
    }

    func testParetoKeepsTheBarThatReachesEightyPercent() {
        let hotels = RanchOSFinanceCategoryBar(categoryID: UUID(), name: "Hotels", total: 90)
        let gas = RanchOSFinanceCategoryBar(categoryID: UUID(), name: "Gas", total: 10)
        let ranked = RanchOSFinancePareto.bars(from: [gas, hotels])
        XCTAssertEqual(ranked.map(\.name), ["Hotels", "Gas"])
        XCTAssertEqual(ranked.map(\.inEighty), [true, false])
        XCTAssertEqual(RanchOSFinancePareto.percentText(ranked[0].cumulative, of: 100), "90%")
    }

    @MainActor
    func testSamePeriodLastYearComparesTheSelectedSlice() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2025,06/02/2025,A,Alpha Market,Groceries,purchase,7.00,Sam
        06/10/2025,06/10/2025,B,Beta Fuel,Fuel,purchase,3.00,Sam
        06/20/2025,06/20/2025,C,City Inn,Hotels,purchase,8.00,Sam
        06/02/2026,06/02/2026,D,Alpha Market,Groceries,purchase,10.00,Sam
        06/02/2026,06/02/2026,D,Alpha Market,Groceries,purchase,10.00,Sam
        06/18/2026,06/18/2026,E,Alpha Market,Groceries,purchase,30.00,Sam
        06/25/2026,06/25/2026,F,Beta Fuel,Fuel,purchase,20.00,Sam
        10/02/2026,10/02/2026,G,Alpha Market,Groceries,purchase,4.00,Sam
        """
        _ = store.ingest(
            fileName: "apple.csv", bytes: Data(csv.utf8), source: apple.name, accountID: apple.id)

        let june = RanchOSFinanceChartQuery(
            account: .account(apple.id), categoryIDs: [], year: 2026, month: 6, money: .expenses)
        let compared = store.samePeriodLastYear(june)
        XCTAssertEqual(compared.currentLabel, "June 2026")
        XCTAssertEqual(compared.priorLabel, "June 2025")
        XCTAssertEqual(compared.categories.map(\.name), ["Fuel", "Groceries", "Hotels", "Uncategorized"])
        XCTAssertEqual(compared.categories.map(\.total), [20, 40, 0, 0])
        XCTAssertEqual(compared.categories.map(\.priorTotal), [3, 7, 8, 0])
        XCTAssertEqual(compared.weeks.map(\.total), [10, 0, 30, 20])
        XCTAssertEqual(compared.weeks.map(\.priorTotal), [7, 3, 8, 0])

        let groceries = try XCTUnwrap(store.ledger.categories.first { $0.name == "Groceries" }?.id)
        var groceriesOnly = june
        groceriesOnly.categoryIDs = [groceries]
        groceriesOnly.year = nil
        groceriesOnly.month = nil
        let groceriesYear = store.samePeriodLastYear(groceriesOnly)
        XCTAssertEqual(groceriesYear.currentLabel, "Jan 1, 2026 – Oct 2, 2026")
        XCTAssertEqual(groceriesYear.priorLabel, "Jan 1, 2025 – Oct 2, 2025")
        XCTAssertEqual(groceriesYear.categories.map(\.name), ["Groceries"])
        XCTAssertEqual(groceriesYear.categories.map(\.total), [44])
        XCTAssertEqual(groceriesYear.categories.map(\.priorTotal), [7])
        XCTAssertTrue(groceriesYear.weeks.isEmpty)
    }

    @MainActor
    func testShowProfileRemembersItsCategories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        XCTAssertTrue(store.chartProfilesByName.isEmpty)
        let living = try XCTUnwrap(store.createChartProfile(name: "Day-to-day living"))
        _ = try XCTUnwrap(store.createChartProfile(name: "Health"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2026,06/02/2026,A,Power Co,Electric,purchase,40.00,Sam
        06/03/2026,06/03/2026,B,Landlord,Rent,purchase,100.00,Sam
        06/04/2026,06/04/2026,C,Beta Fuel,Gas,purchase,15.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id)
        let rent = try XCTUnwrap(store.ledger.categories.first { $0.name == "Rent" }?.id)
        let electric = try XCTUnwrap(store.ledger.categories.first { $0.name == "Electric" }?.id)
        store.setChartProfileCategories(id: living.id, categoryIDs: [electric, rent])
        XCTAssertNil(store.createChartProfile(name: " day-to-day living "))
        let health = try XCTUnwrap(store.ledger.chartProfiles.first { $0.name == "Health" })
        XCTAssertTrue(health.categoryIDs.isEmpty)

        let reloaded = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        let saved = try XCTUnwrap(reloaded.ledger.chartProfiles.first { $0.name == "Day-to-day living" })
        XCTAssertEqual(Set(saved.categoryIDs), [rent, electric])
        let limited = RanchOSFinanceChartQuery(
            account: .all, categoryIDs: Set(saved.categoryIDs), year: nil, month: nil,
            money: .expenses, limitsCategories: true)
        let bars = reloaded.categoryTotals(limited)
        XCTAssertEqual(bars.map(\.name), ["Electric", "Rent"])
        XCTAssertEqual(bars.map(\.total), [40, 100])
        var emptyProfile = limited
        emptyProfile.categoryIDs = []
        XCTAssertTrue(reloaded.categoryTotals(emptyProfile).isEmpty)
        var everyCategory = limited
        everyCategory.categoryIDs = []
        everyCategory.limitsCategories = false
        XCTAssertEqual(
            reloaded.categoryTotals(everyCategory).first { $0.name == "Gas" }?.total,
            15)

        XCTAssertNotNil(reloaded.createChartProfile(name: "Clinic"))
        reloaded.deleteCategory(id: rent)
        let afterDelete = try XCTUnwrap(reloaded.ledger.chartProfiles.first { $0.name == "Day-to-day living" })
        XCTAssertEqual(afterDelete.categoryIDs, [electric])

        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "chartProfiles")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let opened = RanchOSFinanceStore(persistenceURL: url, suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertTrue(opened.chartProfilesByName.isEmpty)
    }

    @MainActor
    func testNewFilterKeepsOnlyTheCategoriesTurnedOn() throws {
        let store = try tempStore()
        let gas = try XCTUnwrap(store.createCategory(name: "Gas"))
        let grocery = try XCTUnwrap(store.createCategory(name: "Grocery"))
        let saved = try XCTUnwrap(
            store.createChartProfile(name: "Errands", categoryIDs: [grocery.id, gas.id]))
        XCTAssertEqual(Set(saved.categoryIDs), [gas.id, grocery.id])
        XCTAssertNil(store.createChartProfile(name: "errands", categoryIDs: [gas.id]))
        let kept = try XCTUnwrap(store.ledger.chartProfiles.first { $0.name == "Errands" })
        XCTAssertEqual(Set(kept.categoryIDs), [gas.id, grocery.id])
        let fuel = try XCTUnwrap(store.createCategory(name: "Fuel"))
        store.setChartProfileCategories(id: saved.id, categoryIDs: Set(kept.categoryIDs).union([fuel.id]))
        let added = try XCTUnwrap(store.ledger.chartProfiles.first { $0.name == "Errands" })
        XCTAssertEqual(Set(added.categoryIDs), [gas.id, grocery.id, fuel.id])
        let query = RanchOSFinanceChartQuery(
            account: .all, categoryIDs: Set(kept.categoryIDs), year: nil, month: nil,
            money: .expenses, limitsCategories: true)
        XCTAssertEqual(store.categoryTotals(query).map(\.name), ["Gas", "Grocery"])
    }

    @MainActor
    func testHistoryListsEveryAccountBeforeAnyArchive() throws {
        let store = try tempStore()
        _ = try XCTUnwrap(store.createAccount(name: "Chase", kind: .creditCard))
        _ = try XCTUnwrap(store.createAccount(name: "BancFirst", kind: .bank))
        let groups = store.historyGroups()
        XCTAssertEqual(groups.map(\.account), ["BancFirst", "Chase"])
        XCTAssertTrue(groups.allSatisfy { $0.archives.isEmpty })
    }

    @MainActor
    func testOctoberPromptsEachAccountToArchiveTheMonthBefore() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let citi = try XCTUnwrap(store.createAccount(name: "Citi", kind: .creditCard))
        let appleCSV = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2026,06/02/2026,A,Alpha Market,Groceries,purchase,10.00,Sam
        09/15/2026,09/15/2026,B,Alpha Market,Groceries,purchase,20.00,Sam
        10/02/2026,10/02/2026,C,Alpha Market,Groceries,purchase,30.00,Sam
        """
        let citiCSV = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        08/04/2026,08/04/2026,D,City Fuel,Fuel,purchase,12.00,Sam
        10/03/2026,10/03/2026,E,City Fuel,Fuel,purchase,14.00,Sam
        """
        let appleFile = store.ingest(
            fileName: "apple.csv", bytes: Data(appleCSV.utf8), source: apple.name, accountID: apple.id).file
        let citiFile = store.ingest(
            fileName: "citi.csv", bytes: Data(citiCSV.utf8), source: citi.name, accountID: citi.id).file

        let ready = store.accountsReadyToArchive()
        XCTAssertEqual(ready.map(\.accountName), ["Apple Card", "Apple Card", "Citi"])
        XCTAssertEqual(ready.map(\.month.label), ["June 2026", "September 2026", "August 2026"])
        XCTAssertEqual(ready.map(\.openMonthLabel), ["October 2026", "October 2026", "October 2026"])

        for offer in ready {
            for fileID in offer.fileIDs {
                _ = store.archiveMonths(fileID: fileID, months: [offer.month])
            }
        }
        XCTAssertTrue(store.accountsReadyToArchive().isEmpty)
        XCTAssertEqual(store.historyGroups().map(\.account), ["Apple Card", "Citi"])
        let appleHistory = try XCTUnwrap(store.historyGroups().first { $0.account == "Apple Card" }?.archives.first)
        XCTAssertEqual(appleHistory.year, 2026)
        XCTAssertEqual(appleHistory.month, 9)
        XCTAssertEqual(store.archiveDaySpan(appleHistory), "Sep 15, 2026")
        XCTAssertEqual(appleHistory.fileID, appleFile.id)
        XCTAssertEqual(store.ledger.charges.filter { $0.fileID == appleFile.id }.count, 3)
        XCTAssertEqual(store.ledger.charges.filter { $0.fileID == citiFile.id }.count, 2)
        let appleRecent = store.recentAccountGroups().first { $0.id == apple.id.uuidString }?.charges ?? []
        let citiRecent = store.recentAccountGroups().first { $0.id == citi.id.uuidString }?.charges ?? []
        XCTAssertEqual(appleRecent.count, 1)
        XCTAssertEqual(citiRecent.count, 1)
        XCTAssertEqual(
            appleRecent.map { RanchOSFinanceDates.yearMonth(RanchOSFinanceDates.parse($0.dateText) ?? .distantPast).month },
            [10])
        XCTAssertFalse(appleRecent.contains { store.isMovedToHistory($0) })
        XCTAssertEqual(appleHistory.charges.map(\.categoryName), ["Groceries"])
    }

    @MainActor
    func testClosedMonthLeavesRecentAfterCategoriesAreChecked() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2026,06/02/2026,A,Alpha Market,Groceries,purchase,10.00,Sam
        07/03/2026,07/03/2026,B,Alpha Market,Groceries,purchase,5.00,Sam
        """
        let file = store.ingest(
            fileName: "apple.csv", bytes: Data(csv.utf8), source: apple.name, accountID: apple.id).file
        XCTAssertEqual(store.recentAccountGroups().first?.charges.count, 2)
        let ready = store.accountsReadyToArchive()
        XCTAssertEqual(ready.map(\.month.label), ["June 2026"])

        let june = try XCTUnwrap(store.ledger.charges.first { charge in
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
            return RanchOSFinanceDates.yearMonth(date).month == 6
        })
        let pantry = try XCTUnwrap(store.createCategory(name: "Pantry"))
        store.assign(chargeID: june.id, categoryID: pantry.id)

        for offer in ready {
            for fileID in offer.fileIDs {
                _ = store.archiveMonths(fileID: fileID, months: [offer.month])
            }
        }
        let history = try XCTUnwrap(store.historyGroups().first { $0.account == "Apple Card" }?.archives.first)
        XCTAssertEqual(history.month, 6)
        XCTAssertEqual(history.charges.map(\.categoryName), ["Pantry"])
        XCTAssertEqual(history.fileID, file.id)
        let recent = store.recentAccountGroups().first?.charges ?? []
        XCTAssertEqual(recent.count, 1)
        let remaining = try XCTUnwrap(recent.first)
        let remainingMonth = RanchOSFinanceDates.yearMonth(
            try XCTUnwrap(RanchOSFinanceDates.parse(remaining.dateText))).month
        XCTAssertEqual(remainingMonth, 7)
        XCTAssertFalse(store.isMovedToHistory(remaining))
        XCTAssertEqual(store.ledger.charges.count, 2)
        XCTAssertTrue(store.accountsReadyToArchive().isEmpty)
    }

    @MainActor
    func testJulyLeavesOnlyJulyAndMovesJuneAndEarlier() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        05/04/2026,05/04/2026,A,Alpha Market,Groceries,purchase,3.00,Sam
        06/02/2026,06/02/2026,B,Alpha Market,Groceries,purchase,10.00,Sam
        07/01/2026,07/01/2026,C,Alpha Market,Groceries,purchase,5.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: apple.name, accountID: apple.id)
        let ready = store.accountsReadyToArchive()
        XCTAssertEqual(ready.map(\.month.label), ["May 2026", "June 2026"])
        XCTAssertEqual(ready.map(\.openMonthLabel), ["July 2026", "July 2026"])
        for offer in ready {
            for fileID in offer.fileIDs {
                _ = store.archiveMonths(fileID: fileID, months: [offer.month])
            }
        }
        let recent = store.recentAccountGroups().first?.charges ?? []
        XCTAssertEqual(recent.count, 1)
        let month = RanchOSFinanceDates.yearMonth(
            try XCTUnwrap(RanchOSFinanceDates.parse(recent[0].dateText))).month
        XCTAssertEqual(month, 7)
        let archivedMonths = store.historyGroups().first?.archives.compactMap(\.month) ?? []
        XCTAssertEqual(archivedMonths, [6, 5])
        XCTAssertTrue(store.accountsReadyToArchive().isEmpty)
    }

    @MainActor
    func testClearingEarlierMonthsLeavesOnlyRecentVendorsListed() throws {
        let store = try tempStore()
        let apple = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let groceries = try XCTUnwrap(store.createCategory(name: "Groceries"))
        let fuel = try XCTUnwrap(store.createCategory(name: "Fuel"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        06/02/2026,06/02/2026,A,Alpha Market,Groceries,purchase,10.00,Sam
        07/01/2026,07/01/2026,B,Beta Fuel,Fuel,purchase,5.00,Sam
        """
        _ = store.ingest(fileName: "apple.csv", bytes: Data(csv.utf8), source: apple.name, accountID: apple.id)
        let june = try XCTUnwrap(store.ledger.charges.first { charge in
            guard let date = RanchOSFinanceDates.parse(charge.dateText) else { return false }
            return RanchOSFinanceDates.yearMonth(date).month == 6
        })
        store.assign(chargeID: june.id, categoryID: groceries.id)
        for offer in store.accountsReadyToArchive() {
            for fileID in offer.fileIDs {
                _ = store.archiveMonths(fileID: fileID, months: [offer.month])
            }
        }
        XCTAssertEqual(store.recentVendors().map(\.name), ["Beta Fuel"])
        let alpha = try XCTUnwrap(store.ledger.vendors.first { $0.name == "Alpha Market" })
        XCTAssertEqual(alpha.categoryID, groceries.id)
        XCTAssertNotNil(store.ledger.vendors.first { $0.name == "Beta Fuel" })
        XCTAssertEqual(store.categoryName(for: liveCharge(store, june.id)), "Groceries")
        XCTAssertEqual(store.ledger.categories.map(\.id).contains(groceries.id), true)
        XCTAssertEqual(store.ledger.categories.map(\.id).contains(fuel.id), true)
        XCTAssertEqual(store.recentAccountGroups().first?.charges.count, 1)
    }

    // MARK: - Split transactions

    private var splitLedgerURL: URL?

    @MainActor
    private func splitFixture() throws -> (
        store: RanchOSFinanceStore, fileID: UUID, farm: UUID, other: UUID,
        feed: RanchOSFinanceCategory, hardware: RanchOSFinanceCategory
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        splitLedgerURL = directory.appendingPathComponent("ledger.json")
        let store = RanchOSFinanceStore(persistenceURL: splitLedgerURL, suggester: FakeFinanceSuggester(answer: nil))
        let feed = try XCTUnwrap(store.createCategory(name: "Feed"))
        let hardware = try XCTUnwrap(store.createCategory(name: "Hardware"))
        let csv = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Prairie Farm Store,Feed,purchase,100.00,Sam
        07/09/2026,07/09/2026,B,Prairie Farm Store,Feed,purchase,50.00,Sam
        """
        let card = try XCTUnwrap(store.createAccount(name: "Apple Card", kind: .creditCard))
        let file = store.ingest(
            fileName: "apple.csv", bytes: Data(csv.utf8), source: card.name, accountID: card.id).file
        let charges = store.charges(fileID: file.id).sorted { $0.dateText < $1.dateText }
        return (store, file.id, charges[0].id, charges[1].id, feed, hardware)
    }

    @MainActor
    func testSplitChargeChartsEachPieceAndKeepsItInHistory() throws {
        let (store, fileID, farm, _, feed, hardware) = try splitFixture()
        XCTAssertTrue(store.splitCharge(chargeID: farm, parts: [(feed.id, 60), (hardware.id, 40)]))
        let split = liveCharge(store, farm)
        XCTAssertTrue(store.isSplit(split))
        XCTAssertNil(store.categoryID(for: split))
        XCTAssertEqual(store.categoryName(for: split), "Split")

        let all = RanchOSFinanceChartQuery(
            account: .all, categoryIDs: [], year: nil, month: nil, money: .expenses, limitsCategories: false)
        let totals = Dictionary(uniqueKeysWithValues: store.categoryTotals(all).map { ($0.categoryID, $0.total) })
        XCTAssertEqual(totals[feed.id], 110)
        XCTAssertEqual(totals[hardware.id], 40)
        var hardwareOnly = all
        hardwareOnly.categoryIDs = [hardware.id]
        hardwareOnly.limitsCategories = true
        let bars = store.periodBars(time: .month, year: 2026, month: 7, half: 2, query: hardwareOnly)
        XCTAssertEqual(bars.first { $0.id == "2026-07" }?.total, 40)
        XCTAssertEqual(store.vendorTotals(categoryID: hardware.id, query: all).map(\.total), [40])

        let reopened = RanchOSFinanceStore(
            persistenceURL: try XCTUnwrap(splitLedgerURL), suggester: FakeFinanceSuggester(answer: nil))
        XCTAssertEqual(reopened.splitParts(for: liveCharge(reopened, farm)).map(\.amount), [60, 40])

        _ = try XCTUnwrap(store.archiveStatement(fileID: fileID))
        let kept = try XCTUnwrap(store.archive(fileID: fileID)?.charges.first { $0.id == farm })
        XCTAssertEqual(kept.categoryName, "Split")
        XCTAssertEqual(kept.splitParts?.map(\.categoryName), ["Feed", "Hardware"])
        XCTAssertEqual(kept.splitParts?.map(\.amount), [60, 40])

        XCTAssertTrue(store.renameCategory(id: hardware.id, newName: "Tools"))
        let renamed = try XCTUnwrap(store.archive(fileID: fileID)?.charges.first { $0.id == farm })
        XCTAssertEqual(renamed.splitParts?.map(\.categoryName), ["Feed", "Tools"])
    }

    @MainActor
    func testSplitNeedsPiecesThatAddUp() throws {
        let (store, _, farm, _, feed, hardware) = try splitFixture()
        XCTAssertEqual(store.splitProblem(chargeID: farm, parts: [(feed.id, 100)]), "A split needs at least two categories.")
        XCTAssertEqual(store.splitProblem(chargeID: farm, parts: [(feed.id, 50), (feed.id, 50)]), "Use each category once.")
        XCTAssertEqual(
            store.splitProblem(chargeID: farm, parts: [(feed.id, 100), (hardware.id, 0)]),
            "Every piece needs an amount above zero.")
        XCTAssertEqual(
            store.splitProblem(chargeID: farm, parts: [(feed.id, 50), (hardware.id, 40)]), "$10.00 is still unassigned.")
        XCTAssertEqual(
            store.splitProblem(chargeID: farm, parts: [(feed.id, 70), (hardware.id, 40)]),
            "The pieces are $10.00 over the transaction.")
        XCTAssertFalse(store.splitCharge(chargeID: farm, parts: [(feed.id, 50), (hardware.id, 40)]))
        XCTAssertNil(liveCharge(store, farm).splitParts)
        XCTAssertNil(store.splitProblem(chargeID: farm, parts: [(feed.id, 60.004), (hardware.id, 40)]))
    }

    @MainActor
    func testOneCategoryEndsOnlyThatSplit() throws {
        let (store, _, farm, other, feed, hardware) = try splitFixture()
        XCTAssertTrue(store.splitCharge(chargeID: farm, parts: [(feed.id, 60), (hardware.id, 40)]))
        XCTAssertTrue(store.splitCharge(chargeID: other, parts: [(feed.id, 25), (hardware.id, 25)]))
        store.applyAssignment(chargeID: farm, categoryID: hardware.id, currentImport: true, history: false)
        XCTAssertFalse(store.isSplit(liveCharge(store, farm)))
        XCTAssertEqual(store.categoryName(for: liveCharge(store, farm)), "Hardware")
        XCTAssertTrue(store.isSplit(liveCharge(store, other)))

        store.removeSplit(chargeID: other)
        XCTAssertFalse(store.isSplit(liveCharge(store, other)))
        XCTAssertEqual(store.categoryName(for: liveCharge(store, other)), "Feed")
    }

    @MainActor
    func testDeletingACategoryMovesItsSplitPiece() throws {
        let (store, fileID, farm, _, feed, hardware) = try splitFixture()
        let uncategorized = try XCTUnwrap(store.uncategorizedID)
        XCTAssertTrue(store.splitCharge(chargeID: farm, parts: [(uncategorized, 60), (hardware.id, 40)]))
        _ = try XCTUnwrap(store.archiveStatement(fileID: fileID))
        XCTAssertTrue(store.deleteCategory(id: hardware.id))
        let charge = liveCharge(store, farm)
        XCTAssertFalse(store.isSplit(charge))
        XCTAssertEqual(store.categoryID(for: charge), uncategorized)
        let kept = try XCTUnwrap(store.archive(fileID: fileID)?.charges.first { $0.id == farm })
        XCTAssertNil(kept.splitParts)
        XCTAssertEqual(kept.categoryName, "Uncategorized")
        XCTAssertNotNil(store.category(id: feed.id))
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

    @MainActor
    private func historyName(_ store: RanchOSFinanceStore, fileID: UUID, chargeID: UUID) -> String? {
        store.archive(fileID: fileID)?.charges.first { $0.id == chargeID }?.categoryName
    }

    @MainActor
    private func liveCharge(_ store: RanchOSFinanceStore, _ id: UUID) -> RanchOSFinanceCharge {
        store.ledger.charges.first { $0.id == id }!
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
