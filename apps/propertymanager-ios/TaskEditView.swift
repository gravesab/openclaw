import SwiftUI

struct TaskEditView: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss

    let task: MaintenanceTask

    @State private var vendor: String
    @State private var partNumber: String
    @State private var partURL: String
    @State private var partCostText: String
    @State private var annualCostText: String
    @State private var notes: String
    @State private var suppliesNeeded: String
    @State private var taskDescription: String
    @State private var localError: String?
    @State private var isSaving = false

    init(task: MaintenanceTask) {
        self.task = task
        _vendor = State(initialValue: task.vendor ?? "")
        _partNumber = State(initialValue: task.partNumber ?? "")
        _partURL = State(initialValue: task.partURL ?? "")
        _partCostText = State(initialValue: Self.costText(task.partCost))
        _annualCostText = State(initialValue: Self.costText(task.annualCost))
        _notes = State(initialValue: task.notes ?? "")
        _suppliesNeeded = State(initialValue: task.suppliesNeeded ?? "")
        _taskDescription = State(initialValue: task.taskDescription ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Parts") {
                    TextField("Vendor", text: $vendor)
                    TextField("Part #", text: $partNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Part URL", text: $partURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Part cost", text: $partCostText)
                        .keyboardType(.decimalPad)
                    TextField("Annual cost", text: $annualCostText)
                        .keyboardType(.decimalPad)
                }

                Section("Details") {
                    TextField("Description", text: $taskDescription, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Supplies needed", text: $suppliesNeeded, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let localError {
                    Section("Error") {
                        Text(localError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving…")
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func save() async {
        localError = nil

        let partCost: Double?
        let annualCost: Double?
        do {
            partCost = try Self.parseCost(partCostText)
            annualCost = try Self.parseCost(annualCostText)
        } catch {
            localError = error.localizedDescription
            return
        }

        var fields: [String: Any] = [
            "vendor": vendor,
            "part_number": partNumber,
            "part_url": partURL,
            "notes": notes,
            "supplies_needed": suppliesNeeded,
            "task_description": taskDescription,
        ]
        if let partCost {
            fields["part_cost"] = partCost
        } else {
            fields["part_cost"] = NSNull()
        }
        if let annualCost {
            fields["annual_cost"] = annualCost
        } else {
            fields["annual_cost"] = NSNull()
        }

        isSaving = true
        defer { isSaving = false }

        let ok = await store.saveEdits(taskID: task.id, fields: fields)
        if ok {
            dismiss()
        } else {
            localError = store.errorMessage ?? "Could not save changes."
        }
    }

    private static func costText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func parseCost(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        guard let value = Double(trimmed) else {
            throw CostParseError.invalid
        }
        return value
    }
}

private enum CostParseError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "Cost must be a number."
    }
}
