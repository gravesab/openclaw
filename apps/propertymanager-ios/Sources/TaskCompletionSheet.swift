import SwiftUI

enum TaskCompletionMeterRequirement: Equatable {
    case none
    case activationRequired(meterType: String, unit: String)
    case confirmationRequired(currentValue: Double, unit: String)
    case unavailable(String)
}

enum TaskCompletionPolicy {
    static func requirement(
        scheduleKind: String?,
        hasLinkedAsset: Bool,
        asset: RanchAsset?
    ) -> TaskCompletionMeterRequirement {
        let meterScheduled = scheduleKind == "meter" || scheduleKind == "both"
        guard hasLinkedAsset else {
            return meterScheduled
                ? .unavailable("This meter-scheduled task has no linked asset.")
                : .none
        }
        guard let asset else {
            return .unavailable("The linked asset could not be loaded.")
        }

        if let meter = asset.meter, meter.hasMeter, asset.meterActivatedAt != nil {
            return .confirmationRequired(
                currentValue: meter.currentValue ?? 0,
                unit: meter.unit
            )
        }
        if asset.meterNeedsActivation, let proposed = asset.proposedMeter {
            return .activationRequired(
                meterType: proposed.meterType ?? "meter",
                unit: proposed.unit ?? ""
            )
        }
        return meterScheduled
            ? .unavailable("Activate a meter on the linked asset before completing this task.")
            : .none
    }

    static func meterValue(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    /// What to send for the meter. Entering 0 means "no change" and confirms the current
    /// reading, since the server rejects a completion reading below the current one.
    static func meterSubmission(
        requirement: TaskCompletionMeterRequirement,
        confirmedCurrent: Bool,
        enteredValue: String
    ) -> (value: Double?, confirmCurrent: Bool) {
        guard case .confirmationRequired = requirement else { return (nil, false) }
        if confirmedCurrent { return (nil, true) }
        guard let value = meterValue(enteredValue) else { return (nil, false) }
        return value == 0 ? (nil, true) : (value, false)
    }

    static func canSubmit(
        requirement: TaskCompletionMeterRequirement,
        confirmedCurrent: Bool,
        enteredValue: String
    ) -> Bool {
        switch requirement {
        case .none:
            return true
        case .confirmationRequired:
            return confirmedCurrent || meterValue(enteredValue) != nil
        case .activationRequired, .unavailable:
            return false
        }
    }
}

struct TaskCompletionSheet: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss

    let task: MaintenanceTask
    var onCompleted: () -> Void = {}

    @State private var note = ""
    @State private var linkedAsset: RanchAsset?
    @State private var meterValue = ""
    @State private var confirmedCurrent = false
    @State private var isLoadingContext = true
    @State private var isActivating = false
    @State private var isSubmitting = false
    @State private var localError: String?

    private var requirement: TaskCompletionMeterRequirement {
        TaskCompletionPolicy.requirement(
            scheduleKind: task.scheduleKind,
            hasLinkedAsset: task.assetId != nil,
            asset: linkedAsset
        )
    }

    private var canSubmit: Bool {
        !isLoadingContext
            && !isActivating
            && !isSubmitting
            && !store.isCompleting
            && TaskCompletionPolicy.canSubmit(
                requirement: requirement,
                confirmedCurrent: confirmedCurrent,
                enteredValue: meterValue
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    Text(task.item)
                    LabeledContent("Completion time", value: "Recorded by the server")
                        .foregroundStyle(.secondary)
                }

                meterSection

                Section("Note") {
                    TextField("Completion note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let localError {
                    Section("Cannot complete") {
                        Text(localError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Complete task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(store.isCompleting || isActivating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await complete() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .task { await loadCompletionContext() }
    }

    @ViewBuilder
    private var meterSection: some View {
        if isLoadingContext {
            Section("Operating meter") {
                ProgressView("Loading current reading…")
            }
        } else {
            switch requirement {
            case .none:
                EmptyView()
            case .activationRequired(let meterType, let unit):
                Section("Operating meter") {
                    Text("A \(meterType.replacingOccurrences(of: "_", with: " ")) meter is proposed for this asset. Activate it explicitly before completing the task.")
                    if !unit.isEmpty {
                        LabeledContent("Unit", value: unit)
                    }
                    Button {
                        Task { await activateMeter() }
                    } label: {
                        if isActivating {
                            ProgressView()
                        } else {
                            Text("Activate meter")
                        }
                    }
                    .disabled(isActivating)
                }
            case .confirmationRequired(let currentValue, let unit):
                Section("Operating meter") {
                    LabeledContent("Current reading", value: "\(formatValue(currentValue)) \(unit)")
                    Toggle("Confirm this current reading", isOn: $confirmedCurrent)
                        .onChange(of: confirmedCurrent) { _, confirmed in
                            if confirmed { meterValue = "" }
                        }
                    if !confirmedCurrent {
                        TextField("Enter current reading (0 = no change)", text: $meterValue)
                            .keyboardType(.decimalPad)
                    }
                    Text("Required. Enter the reading shown on the equipment, or 0 if it has not changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let message):
                Section("Operating meter") {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @MainActor
    private func loadCompletionContext() async {
        defer { isLoadingContext = false }
        guard let assetId = task.assetId else { return }
        do {
            linkedAsset = try await store.client.fetchAsset(id: assetId)
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func activateMeter() async {
        guard let assetId = task.assetId else { return }
        isActivating = true
        localError = nil
        defer { isActivating = false }
        do {
            linkedAsset = try await store.client.activateMeter(assetId: assetId)
            await store.refreshAssets()
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func complete() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        localError = nil
        let submission = TaskCompletionPolicy.meterSubmission(
            requirement: requirement,
            confirmedCurrent: confirmedCurrent,
            enteredValue: meterValue
        )

        let succeeded = await store.complete(
            task: task,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
            meterValue: submission.value,
            confirmCurrentMeter: submission.confirmCurrent
        )
        guard succeeded else {
            localError = store.errorMessage ?? "The task could not be completed."
            isSubmitting = false
            return
        }
        onCompleted()
        dismiss()
    }

    private func formatValue(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
