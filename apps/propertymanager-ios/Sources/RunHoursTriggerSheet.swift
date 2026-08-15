import SwiftUI

/// Edit absolute run-hours trigger + optional repeat interval.
/// Gate: linked asset must have activated `runtime_hours` meter.
/// Deliberate Save only — no autosave of partial/invalid trigger text.
struct RunHoursTriggerSheet: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss

    let taskID: UUID
    let taskTitle: String
    let assetID: UUID?
    let currentScheduleKind: String?
    let calendarIsMeaningful: Bool
    let initialTrigger: Decimal?
    let initialInterval: Decimal?

    @State private var triggerText: String
    @State private var intervalText: String
    @State private var scheduleChoice: ScheduleChoice
    @State private var isSaving = false
    @State private var localError: String?

    enum ScheduleChoice: String, CaseIterable, Identifiable {
        case meter
        case both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .meter: return "Meter only"
            case .both: return "Calendar + meter (both)"
            }
        }
    }

    init(
        taskID: UUID,
        taskTitle: String,
        assetID: UUID?,
        currentScheduleKind: String?,
        calendarIsMeaningful: Bool,
        initialTrigger: Decimal?,
        initialInterval: Decimal?
    ) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.assetID = assetID
        self.currentScheduleKind = currentScheduleKind
        self.calendarIsMeaningful = calendarIsMeaningful
        self.initialTrigger = initialTrigger
        self.initialInterval = initialInterval
        _triggerText = State(initialValue: Self.formatOptional(initialTrigger))
        _intervalText = State(initialValue: Self.formatOptional(initialInterval))
        let kind = (currentScheduleKind ?? "").lowercased()
        if kind == "both" || (kind == "calendar" && calendarIsMeaningful) || (kind != "meter" && calendarIsMeaningful) {
            _scheduleChoice = State(initialValue: .both)
        } else {
            _scheduleChoice = State(initialValue: .meter)
        }
    }

    private var linkedRuntimeHours: Bool {
        guard let assetID,
              let asset = store.assets.first(where: { $0.id == assetID })
        else { return false }
        return asset.meter?.meterType == "runtime_hours" && asset.meterActivatedAt != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    Text(taskTitle)
                }
                if !linkedRuntimeHours {
                    Section {
                        Text("Link an activated runtime-hours asset before setting a run-hours trigger.")
                            .foregroundStyle(.red)
                    }
                }
                Section("Run hours trigger") {
                    TextField("Due when meter reaches (hours)", text: $triggerText)
                        .keyboardType(.decimalPad)
                    TextField("Repeat every (hours, optional)", text: $intervalText)
                        .keyboardType(.decimalPad)
                    Picker("Schedule", selection: $scheduleChoice) {
                        ForEach(ScheduleChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    Text("Absolute trigger is an operator scheduling decision. Manufacturer interval provenance is preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let localError {
                    Section {
                        Text(localError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Hour trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        linkedRuntimeHours && assetID != nil && parseDecimal(triggerText) != nil
    }

    private func save() async {
        guard linkedRuntimeHours, assetID != nil else {
            localError = "Linked activated runtime_hours asset required."
            return
        }
        guard let trigger = parseDecimal(triggerText) else {
            localError = "Enter a valid due meter reading in hours (blank is not zero)."
            return
        }
        if trigger < 0 {
            localError = "Trigger must be nonnegative."
            return
        }
        isSaving = true
        localError = nil
        defer { isSaving = false }

        // Explicit schedule_kind only — never rely on silent API promotion.
        var fields: [String: Any] = [
            "next_due_meter_value": NSDecimalNumber(decimal: trigger).stringValue,
            "schedule_kind": scheduleChoice.rawValue,
            "meter_interval_unit": "hrs",
            "asset_id": assetID!.uuidString,
        ]
        // Do not send origin / source_manual_name — preserve manufacturer authorship.
        if let interval = parseDecimal(intervalText) {
            if interval < 0 {
                localError = "Interval must be nonnegative."
                return
            }
            fields["meter_interval_value"] = NSDecimalNumber(decimal: interval).stringValue
        } else if intervalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields["meter_interval_value"] = NSNull()
        } else {
            localError = "Repeat interval is not a valid number."
            return
        }

        let ok = await store.saveEdits(taskID: taskID, fields: fields)
        if ok {
            await store.refreshAssets()
            dismiss()
        } else {
            localError = store.errorMessage ?? "Save failed"
        }
    }

    private func parseDecimal(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private static func formatOptional(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }
}
