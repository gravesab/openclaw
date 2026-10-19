import SwiftUI

/// Read-only Weeks planning: overdue + two week sections for a selected 14-day block.
struct RanchOSWeekHorizonView: View {
    let propertyStore: RanchOSPropertyLiveStore
    @AppStorage("ranchos.weeks.selectedBlockId") private var selectedBlockId: String = ""

    private var blocks: [PlanningTwoWeekBlock] {
        WeekHorizonPlanning.twoWeekBlocks()
    }

    private var selectedBlock: PlanningTwoWeekBlock? {
        if let match = blocks.first(where: { $0.id == selectedBlockId }) {
            return match
        }
        return WeekHorizonPlanning.defaultBlock(in: blocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weeks")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(RanchOSTheme.ink)
                Spacer()
                Label("READ ONLY", systemImage: "lock.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RanchOSTheme.olive)
            }

            if blocks.isEmpty {
                Text("No planning weeks available.")
                    .foregroundStyle(RanchOSTheme.mutedInk)
            } else {
                Picker("Two weeks", selection: Binding(
                    get: { selectedBlock?.id ?? blocks[0].id },
                    set: { selectedBlockId = $0 }
                )) {
                    ForEach(blocks) { block in
                        Text(block.label).tag(block.id)
                    }
                }
                #if os(tvOS)
                .pickerStyle(.menu)
                #else
                .pickerStyle(.menu)
                #endif
                Text("Each selection is 2 weeks (14 days).")
                    .font(.caption)
                    .foregroundStyle(RanchOSTheme.mutedInk)
            }

            weeksContent
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            if selectedBlockId.isEmpty, let block = WeekHorizonPlanning.defaultBlock(in: blocks) {
                selectedBlockId = block.id
            }
        }
        .task {
            await propertyStore.refresh()
        }
    }

    @ViewBuilder
    private var weeksContent: some View {
        switch propertyStore.state {
        case .loading:
            ProgressView("Loading tasks…")
                .frame(maxWidth: .infinity, minHeight: 80)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(RanchOSTheme.mutedInk)
        case .ready(let dashboard):
            if let selectedBlock {
                let dated = dashboard.tasks.compactMap { task -> (RanchOSPropertyLiveTask, Date)? in
                    guard let due = task.nextDueDate else { return nil }
                    return (task, due)
                }
                let bucket = WeekHorizonBucketing.bucket(
                    tasks: dated,
                    block: selectedBlock,
                    facts: { pair in
                        WeekHorizonBucketing.TaskFacts(
                            nextDue: pair.1,
                            scheduleKind: pair.0.scheduleKind ?? "calendar",
                            isActive: pair.0.isActive,
                            isWorkRequest: pair.0.isWorkRequest,
                            dueMeter: false,
                            overdueMeter: false
                        )
                    }
                )
                let overdueTasks = bucket.overdue.map(\.0)
                let weekSections = bucket.weeks.map { week, pairs in
                    (week: week, tasks: pairs.map(\.0))
                }

                weekSection(title: "Overdue", tasks: overdueTasks)
                ForEach(Array(weekSections.enumerated()), id: \.offset) { _, section in
                    weekSection(title: section.week.label, tasks: section.tasks)
                }
            }
        }
    }

    @ViewBuilder
    private func weekSection(title: String, tasks: [RanchOSPropertyLiveTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(RanchOSTheme.ink)
            if tasks.isEmpty {
                Text("None")
                    .font(.subheadline)
                    .foregroundStyle(RanchOSTheme.mutedInk)
            } else {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RanchOSTheme.ink)
                        Text(task.detail)
                            .font(.caption)
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 4)
    }
}
