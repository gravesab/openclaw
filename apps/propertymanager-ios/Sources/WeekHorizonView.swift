import SwiftUI

struct WeekHorizonView: View {
    @EnvironmentObject private var store: PropertyStore
    @AppStorage("pm.weeks.selectedBlockId") private var selectedBlockId: String = ""
    @State private var completingTask: MaintenanceTask?
    @State private var bypassRequest: TaskBypassRequest?

    private var blocks: [PlanningTwoWeekBlock] {
        WeekHorizonPlanning.twoWeekBlocks()
    }

    private var selectedBlock: PlanningTwoWeekBlock? {
        if let match = blocks.first(where: { $0.id == selectedBlockId }) {
            return match
        }
        return WeekHorizonPlanning.defaultBlock(in: blocks)
    }

    private var bucket: WeekHorizonBucket<MaintenanceTask>? {
        guard let selectedBlock else { return nil }
        return WeekHorizonBucketing.bucket(
            tasks: store.tasks,
            block: selectedBlock,
            facts: { task in
                WeekHorizonBucketing.TaskFacts(
                    nextDue: task.nextDue,
                    scheduleKind: task.scheduleKind ?? "calendar",
                    isActive: task.isActive,
                    isWorkRequest: false,
                    dueMeter: task.dueMeter == true,
                    overdueMeter: task.overdueMeter == true
                )
            }
        )
    }

    var body: some View {
        List {
            if store.isLoading {
                ProgressView("Loading tasks…")
            }

            Section {
                if blocks.isEmpty {
                    Text("No planning weeks available.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Two weeks", selection: Binding(
                        get: { selectedBlock?.id ?? blocks[0].id },
                        set: { selectedBlockId = $0 }
                    )) {
                        ForEach(blocks) { block in
                            Text(block.label).tag(block.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Each selection is 2 weeks (14 days).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Show")
            }

            if let bucket {
                Section("Overdue") {
                    if bucket.overdue.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bucket.overdue) { task in
                            weekTaskRow(task)
                        }
                    }
                }

                ForEach(Array(bucket.weeks.enumerated()), id: \.offset) { _, section in
                    Section(section.week.label) {
                        if section.tasks.isEmpty {
                            Text("None")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(section.tasks) { task in
                                weekTaskRow(task)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Weeks")
        .navigationDestination(for: UUID.self) { taskID in
            TaskDetailView(taskID: taskID)
        }
        .refreshable {
            await store.refresh()
        }
        .onAppear {
            if selectedBlockId.isEmpty, let block = WeekHorizonPlanning.defaultBlock(in: blocks) {
                selectedBlockId = block.id
            }
        }
        .sheet(item: $completingTask) { task in
            TaskCompletionSheet(task: task) {
                completingTask = nil
            }
            .environmentObject(store)
        }
        .sheet(item: $bypassRequest) { request in
            TaskBypassSheet(task: request.task, initialAction: request.action)
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private func weekTaskRow(_ task: MaintenanceTask) -> some View {
        let group = TaskTitle.displayAssetName(task: task, assets: store.assets)
        TaskRowView(
            task: task,
            groupName: group,
            onComplete: { completingTask = task },
            onBypass: { action in
                bypassRequest = TaskBypassRequest(task: task, action: action)
            }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                bypassRequest = TaskBypassRequest(task: task, action: .skip)
            } label: {
                Label("Bypass", systemImage: "forward.end")
            }
            .tint(.indigo)
        }
    }
}
