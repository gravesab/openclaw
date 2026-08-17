import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID

    @State private var note = ""
    @State private var showCompleteConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showEdit = false
    @State private var completionReceipt: TaskCompletionReceipt?
    @State private var isProcessingCompletionReceipt = false

    private var task: MaintenanceTask? {
        store.tasks.first(where: { $0.id == taskID })
    }

    var body: some View {
        Group {
            if let task {
                List {
                    Section("Status") {
                        LabeledContent("Due", value: task.dueStatus.label)
                        LabeledContent("Priority", value: task.priority)
                        LabeledContent("Frequency", value: task.frequency)
                        LabeledContent(
                            "Last done",
                            value: task.lastDone.map {
                                $0.formatted(date: .abbreviated, time: .omitted)
                            } ?? "Never"
                        )
                        LabeledContent("Next due", value: task.nextDue.formatted(date: .abbreviated, time: .omitted))
                        if let eta = TaskTitle.estimatedTimeLabel(minutes: task.estimatedMinutes) {
                            Text(eta)
                        }
                    }

                    Section("Task") {
                        LabeledContent("Area", value: task.area)
                        LabeledContent("Item", value: {
                            let group = TaskTitle.displayAssetName(task: task, assets: store.assets)
                            return TaskTitle.displayItemTitle(item: task.item, group: group)
                        }())
                        LabeledContent("Category", value: task.categoryName)
                        HStack {
                            Text("Origin")
                            Spacer()
                            TaskOriginBadge(origin: task.origin)
                        }
                        if let manufacturer = task.manufacturer, !manufacturer.isEmpty {
                            LabeledContent("Manufacturer", value: manufacturer)
                        }
                        if let manual = task.sourceManualName, !manual.isEmpty {
                            LabeledContent("Source manual", value: manual)
                        }
                        if let description = task.taskDescription, !description.isEmpty {
                            Text(description)
                        }
                    }

                    if let instructions = task.responseInstructions, !instructions.isEmpty {
                        Section("Instructions") {
                            Text(instructions)
                        }
                    }

                    if let supplies = task.suppliesNeeded, !supplies.isEmpty {
                        Section("Supplies") {
                            Text(supplies)
                        }
                    }

                    if let notes = task.notes, !notes.isEmpty {
                        Section("Notes") {
                            Text(notes)
                        }
                    }

                    Section("Parts") {
                        if task.hasPartInfo {
                            if let vendor = task.vendor, !vendor.isEmpty {
                                LabeledContent("Vendor", value: vendor)
                            }
                            if let partNumber = task.partNumber, !partNumber.isEmpty {
                                LabeledContent("Part #", value: partNumber)
                            }
                            if let partURL = task.partURL, !partURL.isEmpty {
                                if let url = URL(string: partURL) {
                                    Link("Open part link", destination: url)
                                } else {
                                    LabeledContent("Part URL", value: partURL)
                                }
                            }
                            if let partCost = task.partCost {
                                LabeledContent("Part cost", value: partCost.formatted(.currency(code: "USD")))
                            }
                            if let annualCost = task.annualCost {
                                LabeledContent("Annual cost", value: annualCost.formatted(.currency(code: "USD")))
                            }
                            if let parts = task.parts, !parts.isEmpty {
                                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(part.displayTitle)
                                            .font(.subheadline.weight(.semibold))
                                        if let vendor = part.vendor, !vendor.isEmpty {
                                            Text("Vendor: \(vendor)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let number = part.displayPartNumber {
                                            Text("Part # \(number)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let oem = part.oemPartNumber, !oem.isEmpty, oem != part.displayPartNumber {
                                            Text("OEM # \(oem)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let quantity = part.quantity {
                                            Text("Qty \(quantity.formatted())")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let cost = part.cost {
                                            Text(cost.formatted(.currency(code: "USD")))
                                                .font(.caption)
                                        }
                                        if let notes = part.notes, !notes.isEmpty {
                                            Text(notes)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let buyURL = part.buyURL, let url = URL(string: buyURL) {
                                            Link("Buy / supply link", destination: url)
                                                .font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } else {
                            Text("No part info")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Mark complete") {
                        TextField("Optional completion note", text: $note, axis: .vertical)
                            .lineLimit(3...6)
                        Button {
                            showCompleteConfirm = true
                        } label: {
                            if store.isCompleting {
                                ProgressView()
                            } else {
                                Label("Mark Done", systemImage: "checkmark.circle.fill")
                            }
                        }
                        .disabled(store.isCompleting)
                    }

                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            if store.isSaving {
                                ProgressView()
                            } else {
                                Label("Delete Task", systemImage: "trash")
                            }
                        }
                        .disabled(store.isSaving || store.isCompleting)
                    }
                }
                .navigationTitle({
                    let group = TaskTitle.displayAssetName(task: task, assets: store.assets)
                    return TaskTitle.displayItemTitle(item: task.item, group: group)
                }())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") {
                            showEdit = true
                        }
                    }
                }
                .sheet(isPresented: $showEdit) {
                    TaskEditView(task: task)
                        .environmentObject(store)
                }
                .confirmationDialog(
                    "Mark \(task.item) done?",
                    isPresented: $showCompleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Mark Done", role: .none) {
                        Task {
                            if let receipt = await store.completeWithReceipt(
                                task: task,
                                note: note
                            ) {
                                note = ""
                                completionReceipt = receipt
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog(
                    "Delete \(task.item)?",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete Task", role: .destructive) {
                        Task {
                            let ok = await store.delete(task: task)
                            if ok {
                                dismiss()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the task from the active list. Completion history is kept.")
                }
                .sheet(item: $completionReceipt) { receipt in
                    detailCompletionResultSheet(receipt)
                }
            } else {
                ContentUnavailableView(
                    "Task unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Pull to refresh the task list.")
                )
            }
        }
    }

    @ViewBuilder
    private func detailCompletionResultSheet(
        _ receipt: TaskCompletionReceipt
    ) -> some View {
        NavigationStack {
            Form {
                Section {
                    Label("Task Completed", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))

                    Text(receipt.task.item)
                        .font(.headline)
                }

                Section("Completion") {
                    LabeledContent("Completed by", value: receipt.completedBy)
                    LabeledContent("Device", value: receipt.deviceLabel)
                    LabeledContent(
                        "Completed",
                        value: detailCompletionTimestamp(receipt.completedAt)
                    )
                }
            }
            .navigationTitle("Task Completed")
            .interactiveDismissDisabled(isProcessingCompletionReceipt)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Undo") {
                        Task {
                            isProcessingCompletionReceipt = true
                            let ok = await store.undoCompletion(
                                taskID: receipt.task.id,
                                completionID: receipt.completionID
                            )
                            isProcessingCompletionReceipt = false

                            if ok {
                                completionReceipt = nil
                            }
                        }
                    }
                    .disabled(isProcessingCompletionReceipt)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        Task {
                            isProcessingCompletionReceipt = true
                            let ok = await store.acknowledgeCompletion(
                                taskID: receipt.task.id,
                                completionID: receipt.completionID
                            )
                            isProcessingCompletionReceipt = false

                            if ok {
                                store.removeCompletedTaskFromCurrentDisplay(
                                    taskID: receipt.task.id
                                )
                                completionReceipt = nil
                                dismiss()
                            }
                        }
                    }
                    .disabled(isProcessingCompletionReceipt)
                }
            }
        }
    }

    private func detailCompletionTimestamp(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let date =
            formatter.date(from: raw)
            ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: raw)
            }()

        guard let date else { return raw }

        return date.formatted(
            date: .long,
            time: .shortened
        )
    }
}
