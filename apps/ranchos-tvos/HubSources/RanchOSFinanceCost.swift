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
