import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var store: PropertyStore
    let taskID: UUID

    @State private var note = ""
    @State private var showCompleteConfirm = false
    @State private var showEdit = false

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
                        LabeledContent("Last done", value: task.lastDone.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Next due", value: task.nextDue.formatted(date: .abbreviated, time: .omitted))
                        if let minutes = task.estimatedMinutes {
                            LabeledContent("Estimate", value: "\(minutes) min")
                        }
                    }

                    Section("Task") {
                        LabeledContent("Area", value: task.area)
                        LabeledContent("Item", value: task.item)
                        LabeledContent("Category", value: task.categoryName)
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
                                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(part.name?.isEmpty == false ? part.name! : "Part \(index + 1)")
                                            .font(.subheadline.weight(.semibold))
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
                                        if let cost = part.cost {
                                            Text(cost.formatted(.currency(code: "USD")))
                                                .font(.caption)
                                        }
                                        if let buyURL = part.buyURL, let url = URL(string: buyURL) {
                                            Link("Buy / reference", destination: url)
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
                }
                .navigationTitle(task.item)
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
                            _ = await store.complete(task: task, note: note)
                            note = ""
                        }
                    }
                    Button("Cancel", role: .cancel) {}
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
}
