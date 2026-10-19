import SwiftUI

/// Planning surface: overdue plus the two weeks inside the selected 14-day picker block.
struct WeekHorizonMacView: View {
    @ObservedObject var store: MaintenanceStore
    @Binding var selectedTaskID: UUID?
    var onDone: (MaintenanceTask) -> Void
    var onBypass: (MaintenanceTask, TaskBypassAction) -> Void

    @AppStorage("pm.weeks.selectedBlockId") private var selectedBlockId: String = ""

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
                    scheduleKind: task.scheduleKind,
                    isActive: task.isActive,
                    isWorkRequest: task.kind == .workRequest,
                    dueMeter: task.dueMeter == true,
                    overdueMeter: task.overdueMeter == true
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !blocks.isEmpty {
                Picker("Two weeks", selection: Binding(
                    get: { selectedBlock?.id ?? blocks[0].id },
                    set: { selectedBlockId = $0 }
                )) {
                    ForEach(blocks) { block in
                        Text(block.label).tag(block.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Text("Each selection is 2 weeks (14 days). Overdue stays visible for every selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let bucket {
                        weekSection(title: "Overdue", tasks: bucket.overdue)
                        ForEach(Array(bucket.weeks.enumerated()), id: \.offset) { _, section in
                            weekSection(title: section.week.label, tasks: section.tasks)
                        }
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            if selectedBlockId.isEmpty, let block = WeekHorizonPlanning.defaultBlock(in: blocks) {
                selectedBlockId = block.id
            }
        }
    }

    @ViewBuilder
    private func weekSection(title: String, tasks: [MaintenanceTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(tasks) { task in
                    TaskRowView(
                        task: task,
                        groupName: TaskTitle.displayAssetName(
                            area: task.area,
                            assetId: task.assetId,
                            assets: store.assets
                        ),
                        assets: store.assets,
                        isSelected: task.id == selectedTaskID,
                        onDone: { onDone(task) },
                        onBypass: { action in onBypass(task, action) }
                    )
                    .onTapGesture {
                        selectedTaskID = task.id
                    }
                    .contextMenu {
                        TaskBypassMenuItems(task: task) { action in
                            onBypass(task, action)
                        }
                    }
                }
            }
        }
    }
}
