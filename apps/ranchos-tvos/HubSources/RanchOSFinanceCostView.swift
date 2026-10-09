import SwiftUI

/// One charge: its facts, how its money splits across uses, and the
/// unallocated remainder. Every use fact is entered by him; nothing here is
/// guessed.
struct RanchOSFinanceChargeView: View {
    @Bindable var store: RanchOSFinanceStore
    let chargeID: UUID
    @State private var showingAddUse = false

    var body: some View {
        if let charge = store.ledger.charges.first(where: { $0.id == chargeID }) {
            List {
                Section("Charge") {
                    Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                        .font(.headline)
                    Text("\(charge.dateText) · \(charge.amountText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(categoryName(charge: charge))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("Category", selection: Binding(
                        get: { store.categoryID(for: charge) ?? store.uncategorizedID ?? charge.id },
                        set: { store.assign(chargeID: charge.id, categoryID: $0) }
                    )) {
                        ForEach(store.ledger.categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    if charge.categoryOverrideID != nil {
                        Text("This charge only. The vendor rule is unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Allocation") {
                    Text("Allocated \(RanchOSFinanceMoney.format(store.allocatedAmount(chargeID: charge.id)))")
                    Text("Unallocated \(RanchOSFinanceMoney.format(store.unallocatedAmount(chargeID: charge.id)))")
                        .foregroundStyle(.secondary)
                }
                Section("Uses") {
                    let uses = store.uses(chargeID: charge.id)
                    if uses.isEmpty {
                        Text("No uses yet. The full amount is unallocated.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(uses) { use in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(use.name)
                                    .font(.subheadline.weight(.medium))
                                Text(useDetail(use))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(RanchOSFinanceMoney.format(use.amount))
                                .font(.subheadline)
                            Button("Delete", role: .destructive) {
                                store.removeUse(id: use.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Button("Add use") { showingAddUse = true }
                }
            }
            .navigationTitle("Charge")
            .sheet(isPresented: $showingAddUse) {
                RanchOSFinanceAddUseSheet(store: store, chargeID: charge.id)
            }
        } else {
            Text("That charge is no longer listed.")
                .foregroundStyle(.secondary)
        }
    }

    private func categoryName(charge: RanchOSFinanceCharge) -> String {
        guard let categoryID = store.categoryID(for: charge),
            let category = store.category(id: categoryID)
        else {
            return RanchOSFinanceSuggestionLabels.uncategorized
        }
        return category.name
    }

    private func useDetail(_ use: RanchOSFinanceUse) -> String {
        if let gallons = use.gallons, let price = use.pricePerGallon {
            return "\(use.kind.label) · \(formattedDecimal(gallons)) gal × \(RanchOSFinanceMoney.format(price))"
        }
        return use.kind.label
    }

    private func formattedDecimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

/// Adds one use to a charge: pick the target kind, the target, and either an
/// exact dollar amount or, for equipment fuel, gallons and price per gallon.
/// The Add button stays disabled unless the use fits the remainder.
struct RanchOSFinanceAddUseSheet: View {
    @Bindable var store: RanchOSFinanceStore
    let chargeID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var kind: RanchOSFinanceTargetKind = .equipment
    @State private var equipmentID: String = RanchOSPropertyEquipment.allCases.first?.rawValue ?? ""
    @State private var assetID: String = RanchOSPropertyAsset.allCases.first?.rawValue ?? ""
    @State private var operationID: UUID?
    @State private var newOperationName = ""
    @State private var fuelMode = false
    @State private var amountText = ""
    @State private var gallonsText = ""
    @State private var priceText = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    Picker("Kind", selection: $kind) {
                        ForEach(RanchOSFinanceTargetKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .onChange(of: kind) { fuelMode = false }
                    switch kind {
                    case .equipment:
                        Picker("Equipment", selection: $equipmentID) {
                            ForEach(RanchOSPropertyEquipment.allCases) { equipment in
                                Text(equipment.title).tag(equipment.rawValue)
                            }
                        }
                    case .propertyAsset:
                        Picker("Asset", selection: $assetID) {
                            ForEach(RanchOSPropertyAsset.allCases) { asset in
                                Text(asset.title).tag(asset.rawValue)
                            }
                        }
                    case .operation:
                        if !store.ledger.operations.isEmpty {
                            Picker("Operation", selection: $operationID) {
                                ForEach(store.ledger.operations) { operation in
                                    Text(operation.name).tag(operation.id as UUID?)
                                }
                            }
                        }
                        TextField("New operation", text: $newOperationName)
                    case .household:
                        Text(RanchOSFinanceMoney.householdName)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Amount") {
                    Text("Remaining on this charge: \(RanchOSFinanceMoney.format(store.unallocatedAmount(chargeID: chargeID)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if kind == .equipment {
                        Toggle("Fuel (gallons × price)", isOn: $fuelMode)
                    }
                    if kind == .equipment && fuelMode {
                        TextField("Gallons", text: $gallonsText)
                        TextField("Price per gallon", text: $priceText)
                        if let fuel = fuelPreview {
                            Text("\(gallonsText) gal × \(RanchOSFinanceMoney.format(fuel.price)) = \(RanchOSFinanceMoney.format(fuel.amount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("Amount", text: $amountText)
                    }
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add use")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
            }
            .onAppear {
                if operationID == nil {
                    operationID = store.ledger.operations.first?.id
                }
            }
        }
    }

    private struct Draft {
        var recordID: String
        var amount: Decimal
        var gallons: Decimal?
        var price: Decimal?
        var newOperation: String?
    }

    private var fuelPreview: (price: Decimal, amount: Decimal)? {
        guard let gallons = RanchOSFinanceCSV.parseAmount(gallonsText), gallons > 0,
            let price = RanchOSFinanceCSV.parseAmount(priceText), price > 0
        else {
            return nil
        }
        return (price, RanchOSFinanceMoney.roundedCents(gallons * price))
    }

    private func draft() -> Draft? {
        let recordID: String
        var newOperation: String?
        switch kind {
        case .equipment:
            recordID = equipmentID
        case .propertyAsset:
            recordID = assetID
        case .operation:
            let trimmed = newOperationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                newOperation = trimmed
                recordID = ""
            } else if let operationID,
                let operation = store.operation(id: operationID)
            {
                recordID = operation.id.uuidString
            } else {
                return nil
            }
        case .household:
            recordID = RanchOSFinanceMoney.householdRecordID
        }
        if kind == .equipment && fuelMode {
            guard let gallons = RanchOSFinanceCSV.parseAmount(gallonsText), gallons > 0,
                let price = RanchOSFinanceCSV.parseAmount(priceText), price > 0
            else {
                return nil
            }
            let amount = RanchOSFinanceMoney.roundedCents(gallons * price)
            guard amount > 0 else { return nil }
            return Draft(recordID: recordID, amount: amount, gallons: gallons, price: price)
        }
        guard let amount = RanchOSFinanceCSV.parseAmount(amountText),
            RanchOSFinanceMoney.roundedCents(amount) > 0
        else {
            return nil
        }
        return Draft(recordID: recordID, amount: RanchOSFinanceMoney.roundedCents(amount), newOperation: newOperation)
    }

    private var canAdd: Bool {
        guard let draft = draft() else { return false }
        return draft.amount <= store.unallocatedAmount(chargeID: chargeID)
    }

    private func add() {
        error = nil
        guard var draft = draft() else {
            error = "Enter the target and a positive amount."
            return
        }
        if let newOperation = draft.newOperation {
            guard let operation = store.createOperation(name: newOperation) else {
                error = "An operation named \"\(newOperation)\" already exists."
                return
            }
            draft.recordID = operation.id.uuidString
        }
        let added: RanchOSFinanceUse?
        if let gallons = draft.gallons, let price = draft.price {
            added = store.addFuelUse(
                chargeID: chargeID, equipmentRecordID: draft.recordID,
                gallons: gallons, pricePerGallon: price)
        } else {
            added = store.addExactUse(
                chargeID: chargeID, kind: kind, recordID: draft.recordID, amount: draft.amount)
        }
        guard added != nil else {
            error = "That amount doesn't fit the remaining \(RanchOSFinanceMoney.format(store.unallocatedAmount(chargeID: chargeID)))."
            return
        }
        dismiss()
    }
}

/// Cost by thing: each target with the sum of amounts linked to it, then the
/// charges with money still unallocated.
struct RanchOSFinanceCostView: View {
    @Bindable var store: RanchOSFinanceStore

    var body: some View {
        List {
            Section("Targets") {
                let totals = store.costByTarget()
                if totals.isEmpty {
                    Text("No costs linked yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(totals) { total in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(total.name)
                                .font(.subheadline.weight(.medium))
                            Text(total.kind.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(RanchOSFinanceMoney.format(total.total))
                            .font(.subheadline)
                    }
                }
            }
            Section("Still unallocated") {
                let charges = store.chargesWithUnallocated()
                if charges.isEmpty {
                    Text("Everything is allocated.")
                        .foregroundStyle(.secondary)
                }
                ForEach(charges) { charge in
                    NavigationLink {
                        RanchOSFinanceChargeView(store: store, chargeID: charge.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                                .font(.subheadline.weight(.medium))
                            Text("\(charge.amountText) · unallocated \(RanchOSFinanceMoney.format(store.unallocatedAmount(chargeID: charge.id)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cost by thing")
    }
}
