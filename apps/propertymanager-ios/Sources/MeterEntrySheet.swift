import SwiftUI

private enum MeterEntryMode: String, CaseIterable, Identifiable {
    case absolute
    case add

    var id: String { rawValue }

    func title(for meterType: String?) -> String {
        switch self {
        case .absolute:
            return "Absolute"
        case .add:
            switch meterType {
            case "mileage":
                return "Add miles"
            case "cycles":
                return "Add cycles"
            default:
                return "Add hours"
            }
        }
    }

    func fieldLabel(for meterType: String?) -> String {
        switch self {
        case .absolute:
            return "Meter reading"
        case .add:
            switch meterType {
            case "mileage":
                return "Miles since last"
            case "cycles":
                return "Cycles since last"
            default:
                return "Hours since last"
            }
        }
    }
}

struct MeterEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PropertyStore

    let asset: RanchAsset
    var onSaved: (RanchAsset) -> Void

    @State private var entryMode: MeterEntryMode = .absolute
    @State private var valueText = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var pendingPreview: LowerReadingPreview?
    @State private var correctionReason = "correction"
    @State private var errorMessage: String?
    @State private var savedAsset: RanchAsset?

    private var displayAsset: RanchAsset { savedAsset ?? asset }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let current = displayAsset.meter?.currentValue {
                        LabeledContent("Current total") {
                            Text(formatMeter(current) + " \(displayAsset.meter?.unit ?? "")")
                        }
                    }
                    if let tasks = displayAsset.tasks?.filter({ $0.remainingMeter != nil }), !tasks.isEmpty {
                        ForEach(tasks.prefix(3)) { task in
                            LabeledContent(task.item) {
                                if task.overdueMeter == true {
                                    Text("Overdue").foregroundStyle(.red)
                                } else if let rem = task.remainingMeter {
                                    Text("\(formatDecimal(rem)) left")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Reading") {
                    Picker("Mode", selection: $entryMode) {
                        ForEach(MeterEntryMode.allCases) { mode in
                            Text(mode.title(for: asset.meter?.meterType)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(pendingPreview != nil)

                    TextField(entryMode.fieldLabel(for: asset.meter?.meterType), text: $valueText)
                        .keyboardType(.decimalPad)
                    TextField("Note (optional)", text: $note)
                }
                if let preview = pendingPreview {
                    Section("Lower reading confirmation") {
                        if let prev = preview.previousValue, let proposed = preview.proposedValue {
                            Text("Previous: \(prev) → Proposed: \(proposed)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Picker("Reason", selection: $correctionReason) {
                            ForEach(preview.options ?? ["correction", "replacement", "rollover"], id: \.self) { opt in
                                Text(opt.capitalized).tag(opt)
                            }
                        }
                    }
                }
            }
            .navigationTitle(asset.meter?.updateButtonTitle ?? "Update Meter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingPreview == nil ? "Save" : "Confirm") {
                        Task { await save() }
                    }
                    .disabled(isSaving || valueText.isEmpty)
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() async {
        guard let amount = Double(valueText.replacingOccurrences(of: ",", with: ".")) else {
            errorMessage = "Enter a valid number."
            return
        }
        if entryMode == .add, amount <= 0 {
            errorMessage = "Enter a positive amount since last reading."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if let preview = pendingPreview {
                let updated = try await store.client.confirmMeterReading(
                    assetId: asset.id,
                    preview: preview,
                    correctionReason: correctionReason,
                    note: note.isEmpty ? nil : note
                )
                savedAsset = updated
                onSaved(updated)
                dismiss()
            } else {
                let updated: RanchAsset
                if entryMode == .add {
                    updated = try await store.client.submitMeterReading(
                        assetId: asset.id,
                        delta: amount,
                        note: note.isEmpty ? nil : note,
                        entryMethod: "manual"
                    )
                } else {
                    updated = try await store.client.submitMeterReading(
                        assetId: asset.id,
                        value: amount,
                        note: note.isEmpty ? nil : note,
                        entryMethod: "manual"
                    )
                }
                savedAsset = updated
                onSaved(updated)
                dismiss()
            }
        } catch PropertyAPIError.lowerReadingConfirmation(let preview) {
            pendingPreview = preview
            errorMessage = "Reading is lower than current. Choose a reason and tap Confirm."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatMeter(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func formatDecimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
