import SwiftUI

enum TaskCompletionMeterRequirement: Equatable {
    case none
    case activationRequired(meterType: String, unit: String)
    case confirmationRequired(currentValue: Double, unit: String)
    case unavailable(String)
}

/// Same completion gate as the iPhone app: a task on an asset with an active
/// meter needs a confirmed or entered reading before the server records it.
enum TaskCompletionPolicy {
    static func requirement(
        scheduleKind: String?,
        hasLinkedAsset: Bool,
        asset: MacRanchAsset?
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

    /// Entering 0 means "no change" and confirms the current reading, since
    /// the server rejects a completion reading below the current one.
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

    /// Prefills the note from the editor's result notes, skipping the
    /// auto-generated "Completed on …" text older builds wrote there.
    static func initialNote(resultNotes: String) -> String {
        let trimmed = resultNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Completed on ") && trimmed.hasSuffix(".") && trimmed.count <= 26 {
            return ""
        }
        return trimmed
    }
}

struct TaskCompletionRequest: Identifiable {
    var id: UUID { task.id }
    let task: MaintenanceTask
    var initialNote: String
    var source: MaintenanceStore.CompletionSource
}

struct TaskCompletionSheet: View {
    @ObservedObject var store: MaintenanceStore
    let request: TaskCompletionRequest
    let onClose: () -> Void

    @State private var note = ""
    @State private var linkedAsset: MacRanchAsset?
    @State private var meterValue = ""
    @State private var confirmedCurrent = false
    @State private var isLoadingContext = true
    @State private var isActivating = false
    @State private var isSubmitting = false
    @State private var localError: String?

    private var task: MaintenanceTask { request.task }

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
            && TaskCompletionPolicy.canSubmit(
                requirement: requirement,
                confirmedCurrent: confirmedCurrent,
                enteredValue: meterValue
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Complete task")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.item)
                    .font(.headline)
                Text("Completion time is recorded by the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            meterSection

            VStack(alignment: .leading, spacing: 6) {
                Text("Note")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            if let localError {
                Text(localError)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting || isActivating)
                Button {
                    Task { await complete() }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Mark Complete")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            note = request.initialNote
            await loadCompletionContext()
        }
    }

    @ViewBuilder
    private var meterSection: some View {
        if isLoadingContext {
            GroupBox("Operating meter") {
                ProgressView("Loading current reading…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            switch requirement {
            case .none:
                EmptyView()
            case .activationRequired(let meterType, let unit):
                GroupBox("Operating meter") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A \(meterType.replacingOccurrences(of: "_", with: " ")) meter is proposed for this asset. Activate it before completing the task.")
                            .fixedSize(horizontal: false, vertical: true)
                        if !unit.isEmpty {
                            Text("Unit: \(unit)")
                                .foregroundStyle(.secondary)
                        }
                        Button(isActivating ? "Activating…" : "Activate meter") {
                            Task { await activateMeter() }
                        }
                        .disabled(isActivating)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .confirmationRequired(let currentValue, let unit):
                GroupBox("Operating meter") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current reading: \(Self.formatValue(currentValue)) \(unit)")
                        Toggle("Confirm this current reading", isOn: $confirmedCurrent)
                            .onChange(of: confirmedCurrent) { confirmed in
                                if confirmed { meterValue = "" }
                            }
                        if !confirmedCurrent {
                            TextField("Enter current reading (0 = no change)", text: $meterValue)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("Required. Enter the reading shown on the equipment, or 0 if it has not changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .unavailable(let message):
                GroupBox("Operating meter") {
                    Text(message)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @MainActor
    private func loadCompletionContext() async {
        defer { isLoadingContext = false }
        guard let assetId = task.assetId else { return }
        do {
            linkedAsset = try await store.apiClient.fetchAsset(id: assetId)
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
            linkedAsset = try await store.apiClient.activateMeter(assetId: assetId)
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
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = await store.complete(
            task: task,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            meterValue: submission.value,
            confirmCurrentMeter: submission.confirmCurrent,
            source: request.source
        )
        isSubmitting = false
        if let failure {
            localError = failure
            return
        }
        onClose()
    }

    private static func formatValue(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
