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
    @State private var triggerHoursText: String
    @State private var intervalHoursText: String
    @State private var suppliesNeeded: String
    @State private var taskDescription: String
    @State private var parts: [TaskPartDraft]
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
        _triggerHoursText = State(initialValue: Self.formatOptional(task.nextDueMeterValue))
        _intervalHoursText = State(initialValue: Self.formatOptional(task.meterIntervalValue))
        _suppliesNeeded = State(initialValue: task.suppliesNeeded ?? "")
        _taskDescription = State(initialValue: task.taskDescription ?? "")
        let existingParts = (task.parts ?? []).map(TaskPartDraft.init(from:))
        _parts = State(initialValue: existingParts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Origin") {
                    TaskOriginBadge(origin: task.origin)
                    if let manufacturer = task.manufacturer, !manufacturer.isEmpty {
                        LabeledContent("Manufacturer", value: manufacturer)
                    }
                    if let manual = task.sourceManualName, !manual.isEmpty {
                        LabeledContent("Source manual", value: manual)
                    }
                }

                Section {
                    ForEach($parts) { $part in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Part name", text: $part.name)
                            TextField("Vendor", text: $part.vendor)
                            TextField("Part #", text: $part.partNumber)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("OEM part #", text: $part.oemPartNumber)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Quantity", text: $part.quantityText)
                                .keyboardType(.decimalPad)
                            TextField("Cost", text: $part.costText)
                                .keyboardType(.decimalPad)
                            TextField("Supply / buy URL", text: $part.buyURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                            TextField("Part notes", text: $part.notes, axis: .vertical)
                                .lineLimit(2...5)
                            Button("Remove part", role: .destructive) {
                                parts.removeAll { $0.id == part.id }
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        parts.append(TaskPartDraft())
                    } label: {
                        Label("Add Part", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Parts list")
                } footer: {
                    Text("Add one or more parts with quantity, cost, and a supply URL.")
                }

                Section("Primary part fields") {
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


                if task.showsRunHoursTrigger {
                    Section("Run hours trigger") {
                        TextField("Due when meter reaches (hours)", text: $triggerHoursText)
                            .keyboardType(.decimalPad)
                        TextField("Repeat every (hours)", text: $intervalHoursText)
                            .keyboardType(.decimalPad)
                        if let badge = task.runHoursBadge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(task.overdueMeter == true ? Color.red : Color.secondary)
                        }
                    }
                }

                Section("Details") {
                    if let eta = TaskTitle.estimatedTimeLabel(minutes: task.estimatedMinutes) {
                        Text(eta)
                            .foregroundStyle(.secondary)
                    }
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
        let partPayloads: [[String: Any]]
        do {
            partCost = try Self.parseCost(partCostText)
            annualCost = try Self.parseCost(annualCostText)
            partPayloads = try parts.map { try $0.asAPIDictionary() }
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

        
        if task.showsRunHoursTrigger {
            if let trigger = Double(triggerHoursText.replacingOccurrences(of: ",", with: ".")) {
                fields["next_due_meter_value"] = trigger
                fields["schedule_kind"] = "meter"
                fields["meter_interval_unit"] = "hrs"
            } else if triggerHoursText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["next_due_meter_value"] = NSNull()
            }
            if let interval = Double(intervalHoursText.replacingOccurrences(of: ",", with: ".")) {
                fields["meter_interval_value"] = interval
            } else if intervalHoursText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["meter_interval_value"] = NSNull()
            }
        }

let ok = await store.saveEdits(taskID: task.id, fields: fields, parts: partPayloads)
        if ok {
            dismiss()
        } else {
            localError = store.errorMessage ?? "Could not save changes."
        }
    }


    private static func formatOptional(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
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
