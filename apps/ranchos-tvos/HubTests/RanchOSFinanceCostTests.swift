import Foundation
import XCTest

/// Cost by thing: uses link charges to targets, fuel math, the cap rule,
/// and persistence. All fixtures synthetic.
final class RanchOSFinanceCostTests: XCTestCase {
    // MARK: - Fuel and exact uses

    @MainActor
    func testFuelUseGallonsTimesPrice() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)

        let use = store.addFuelUse(
            chargeID: hank.id, equipmentRecordID: "lawnmower",
            gallons: Decimal(string: "5.25")!, pricePerGallon: Decimal(string: "3.19")!)

        XCTAssertNotNil(use)
        XCTAssertEqual(use?.amount, Decimal(string: "16.75"))
        XCTAssertEqual(use?.gallons, Decimal(string: "5.25"))
        XCTAssertEqual(use?.pricePerGallon, Decimal(string: "3.19"))
        XCTAssertEqual(use?.kind, .equipment)
        XCTAssertEqual(use?.name, "Lawnmower")
        XCTAssertEqual(store.allocatedAmount(chargeID: hank.id), Decimal(string: "16.75"))
        XCTAssertEqual(store.unallocatedAmount(chargeID: hank.id), Decimal(string: "18.45"))
    }

    @MainActor
    func testUsesCannotExceedTheCharge() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)

        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(string: "35.21")!))
        XCTAssertTrue(store.uses(chargeID: hank.id).isEmpty)

        XCTAssertNotNil(store.addExactUse(
            chargeID: hank.id, kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(string: "35.20")!))
        XCTAssertEqual(store.unallocatedAmount(chargeID: hank.id), Decimal(0))
        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(string: "0.01")!))
    }

    @MainActor
    func testRemainderStaysUnallocatedNeverHousehold() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)

        // Untouched: the whole charge is unallocated and no use exists —
        // in particular no implicit household use.
        XCTAssertTrue(store.ledger.uses.isEmpty)
        XCTAssertTrue(store.chargesWithUnallocated().contains(where: { $0.id == hank.id }))

        _ = store.addExactUse(
            chargeID: hank.id, kind: .equipment, recordID: "lawnmower",
            amount: Decimal(string: "10.00")!)
        XCTAssertEqual(store.unallocatedAmount(chargeID: hank.id), Decimal(string: "25.20"))
        XCTAssertTrue(store.chargesWithUnallocated().contains(where: { $0.id == hank.id }))
        XCTAssertFalse(store.uses(chargeID: hank.id).contains(where: { $0.kind == .household }))
    }

    // MARK: - Unknown targets fail closed

    @MainActor
    func testUnknownTargetsRejected() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)

        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .equipment, recordID: "nope", amount: Decimal(1)))
        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .propertyAsset, recordID: "nope", amount: Decimal(1)))
        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .operation, recordID: UUID().uuidString, amount: Decimal(1)))
        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .household, recordID: "nope", amount: Decimal(1)))
        XCTAssertNil(store.addExactUse(
            chargeID: UUID(), kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(1)))
        XCTAssertNil(store.addExactUse(
            chargeID: hank.id, kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(0)))
        XCTAssertNil(store.addFuelUse(
            chargeID: hank.id, equipmentRecordID: "nope",
            gallons: Decimal(1), pricePerGallon: Decimal(1)))
        XCTAssertNil(store.addFuelUse(
            chargeID: hank.id, equipmentRecordID: "lawnmower",
            gallons: Decimal(0), pricePerGallon: Decimal(3)))
        XCTAssertNil(store.addFuelUse(
            chargeID: hank.id, equipmentRecordID: "lawnmower",
            gallons: Decimal(5), pricePerGallon: Decimal(string: "-1")!))
        XCTAssertTrue(store.ledger.uses.isEmpty)
    }

    // MARK: - Operations and totals

    @MainActor
    func testOperationsAndCostByTarget() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)

        XCTAssertNil(store.createOperation(name: "   "))
        let mowing = store.createOperation(name: "Mowing")!
        XCTAssertNil(store.createOperation(name: "mowing"))

        _ = store.addExactUse(
            chargeID: hank.id, kind: .operation, recordID: mowing.id.uuidString,
            amount: Decimal(string: "20.00")!)
        _ = store.addFuelUse(
            chargeID: hank.id, equipmentRecordID: "lawnmower",
            gallons: Decimal(5), pricePerGallon: Decimal(string: "3.04")!)

        let totals = store.costByTarget()
        XCTAssertEqual(totals.count, 2)
        // Sorted by name: Lawnmower before Mowing.
        XCTAssertEqual(totals.map(\.name), ["Lawnmower", "Mowing"])
        XCTAssertEqual(totals.first(where: { $0.kind == .equipment })?.total, Decimal(string: "15.20"))
        XCTAssertEqual(totals.first(where: { $0.kind == .operation })?.total, Decimal(string: "20.00"))
        // One charge, two uses, fully allocated.
        XCTAssertEqual(store.unallocatedAmount(chargeID: hank.id), Decimal(0))
        XCTAssertFalse(store.chargesWithUnallocated().contains(where: { $0.id == hank.id }))
    }

    @MainActor
    func testTargetTotalsSumAcrossCharges() throws {
        let store = try tempStore()
        _ = try hankCharge(store: store)
        let card = try fixtureBytes("FinanceSampleAppleCard")
        _ = store.ingest(fileName: "card.csv", bytes: card)
        let charges = store.ledger.charges.filter { $0.amountText == "84.12" }
        XCTAssertEqual(charges.count, 2)

        for charge in charges {
            _ = store.addExactUse(
                chargeID: charge.id, kind: .propertyAsset, recordID: "water-system",
                amount: Decimal(string: "4.12")!)
        }

        let totals = store.costByTarget()
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.name, "Water system")
        XCTAssertEqual(totals.first?.total, Decimal(string: "8.24"))
    }

    @MainActor
    func testRemoveUseRestoresRemainder() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)

        let use = store.addExactUse(
            chargeID: hank.id, kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(10))!
        store.removeUse(id: use.id)

        XCTAssertTrue(store.uses(chargeID: hank.id).isEmpty)
        XCTAssertEqual(store.unallocatedAmount(chargeID: hank.id), Decimal(string: "35.20"))
    }

    // MARK: - Allocation is additional to categories

    @MainActor
    func testCategoryEditsLeaveUsesAlone() throws {
        let store = try tempStore()
        let hank = try hankCharge(store: store)
        let feed = store.createCategory(name: "Feed")!
        store.assign(vendorID: hank.vendorID!, categoryID: feed.id)
        _ = store.addExactUse(
            chargeID: hank.id, kind: .household,
            recordID: RanchOSFinanceMoney.householdRecordID, amount: Decimal(10))!

        XCTAssertTrue(store.renameCategory(id: feed.id, newName: "Feed & Seed"))
        let seed = store.createCategory(name: "Seed")!
        XCTAssertTrue(store.deleteCategory(id: seed.id))

        XCTAssertEqual(store.uses(chargeID: hank.id).count, 1)
        XCTAssertEqual(store.uses(chargeID: hank.id).first?.amount, Decimal(10))
    }

    // MARK: - Persistence

    @MainActor
    func testAllocationSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")

        let first = RanchOSFinanceStore(
            persistenceURL: url, suggester: FakeCostSuggester())
        let bank = try fixtureBytes("FinanceSampleBank")
        _ = first.ingest(fileName: "bank.csv", bytes: bank)
        let hank = first.ledger.charges.first(where: { $0.merchantText == "HARDWARE HANK" })!
        let mowing = first.createOperation(name: "Mowing")!
        _ = first.addFuelUse(
            chargeID: hank.id, equipmentRecordID: "lawnmower",
            gallons: Decimal(5), pricePerGallon: Decimal(string: "3.04")!)
        _ = first.addExactUse(
            chargeID: hank.id, kind: .operation, recordID: mowing.id.uuidString,
            amount: Decimal(string: "20.00")!)

        let second = RanchOSFinanceStore(persistenceURL: url, suggester: FakeCostSuggester())
        XCTAssertEqual(second.ledger.uses.count, 2)
        XCTAssertEqual(second.ledger.operations.count, 1)
        XCTAssertEqual(second.unallocatedAmount(chargeID: hank.id), Decimal(0))
        XCTAssertEqual(second.costByTarget().count, 2)
        let fuel = second.ledger.uses.first(where: \.isFuel)
        XCTAssertEqual(fuel?.gallons, Decimal(5))
        XCTAssertEqual(fuel?.pricePerGallon, Decimal(string: "3.04"))
    }

    @MainActor
    func testLedgerWithoutUsesStillOpens() throws {
        let store = try tempStore()
        _ = try hankCharge(store: store)

        let data = try JSONEncoder().encode(store.ledger)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "uses")
        object.removeValue(forKey: "operations")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RanchOSFinanceLedger.self, from: legacy)

        XCTAssertTrue(decoded.uses.isEmpty)
        XCTAssertTrue(decoded.operations.isEmpty)
        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertFalse(decoded.charges.isEmpty)
    }

    // MARK: - Helpers

    /// HARDWARE HANK bank charge: "(35.20)" parses to 35.20 allocatable.
    @MainActor
    private func hankCharge(store: RanchOSFinanceStore) throws -> RanchOSFinanceCharge {
        let bytes = try fixtureBytes("FinanceSampleBank")
        _ = store.ingest(fileName: "bank.csv", bytes: bytes)
        let hank = try XCTUnwrap(store.ledger.charges.first(where: { $0.merchantText == "HARDWARE HANK" }))
        XCTAssertEqual(store.allocatableAmount(charge: hank), Decimal(string: "35.20"))
        return hank
    }

    private func fixtureBytes(_ name: String) throws -> Data {
        let bundle = Bundle(for: RanchOSFinanceCostTests.self)
        guard let url = bundle.url(forResource: name, withExtension: "csv") else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(name).csv"])
        }
        return try Data(contentsOf: url)
    }

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
            suggester: FakeCostSuggester())
    }
}

private final class FakeCostSuggester: RanchOSFinanceCategorySuggesting, @unchecked Sendable {
    func suggestCategory(vendorName: String, categories: [String]) async -> String? { nil }
}
