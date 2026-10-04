import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID

    @State private var showCompletionSheet = false
    @State private var showDeleteConfirm = false
    @State private var showEdit = false
    @State private var bypassAction: TaskBypassAction?
    @State private var scheduleEvents: [TaskScheduleEvent] = []

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
                        Button {
                            showCompletionSheet = true
                        } label: {
                            if store.isCompleting {
                                ProgressView()
                            } else {
                                Label("Mark Done", systemImage: "checkmark.circle.fill")
                            }
                        }
                        .disabled(store.isCompleting)
                        Menu {
                            Button {
                                bypassAction = .skip
                            } label: {
                                Label("Skip to Next Due", systemImage: "forward.end")
                            }
                            .disabled(!TaskBypassPolicy.canSkip(task))
                            Button {
                                bypassAction = .reschedule
                            } label: {
                                Label("Reschedule…", systemImage: "calendar.badge.clock")
                            }
                        } label: {
                            Label("Bypass", systemImage: "arrow.uturn.forward.circle")
                        }
                        .disabled(store.isCompleting || store.isBypassing)
                    }

                    TaskScheduleHistorySection(events: scheduleEvents)

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
                .sheet(isPresented: $showCompletionSheet) {
                    TaskCompletionSheet(task: task) {
                        showCompletionSheet = false
                        dismiss()
                    }
                    .environmentObject(store)
                }
                .sheet(item: $bypassAction) { action in
                    TaskBypassSheet(task: task, initialAction: action) {
                        Task { await loadScheduleEvents() }
                    }
                    .environmentObject(store)
                }
                .task(id: taskID) { await loadScheduleEvents() }
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
            } else {
                ContentUnavailableView(
                    "Task unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Pull to refresh the task list.")
                )
            }
        }
    }

    @MainActor
    private func loadScheduleEvents() async {
        do {
            scheduleEvents = try await store.client.fetchScheduleEvents(taskID: taskID)
        } catch {
            // History is supplementary; the task itself is already on screen.
            guard !error.isCancellation else { return }
            scheduleEvents = []
        }
    }
}
