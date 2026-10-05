import SwiftUI

struct TaskListView: View {
    @EnvironmentObject private var store: PropertyStore
    @State private var completingTask: MaintenanceTask?
    @State private var bypassRequest: TaskBypassRequest?
    @State private var showManualLibrary = false

    var body: some View {
        List {
            if store.isLoading {
                ProgressView("Loading tasks…")
            }
            if let asset = store.selectedTaskAsset {
                Section {
                    HStack {
                        Label(asset.name, systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("All Assets") {
                            store.selectedTaskAssetId = nil
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Showing tasks for")
                }
            }
            ForEach(store.groupedTasks) { section in
                Section(section.name) {
                    ForEach(section.tasks) { task in
                        TaskRowView(
                            task: task,
                            groupName: section.name,
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
            }
        }
        .navigationDestination(for: UUID.self) { taskID in
            TaskDetailView(taskID: taskID)
        }
        .navigationTitle("Tasks")
        .searchable(
            text: $store.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Filter assets or tasks (any word)"
        )
        .refreshable { await store.refresh() }
        .safeAreaInset(edge: .top) {
            Picker("Origin", selection: $store.originFilter) {
                ForEach(OriginFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showManualLibrary = true
                } label: {
                    Label("Manual Library", systemImage: "books.vertical")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $store.filter) {
                    ForEach(TaskFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
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
        .sheet(isPresented: $showManualLibrary) {
            NavigationStack {
                ManualLibraryView(initialAssetID: store.selectedTaskAssetId)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showManualLibrary = false }
                        }
                    }
            }
            .environmentObject(store)
        }
    }
}

struct TaskRowView: View {
    let task: MaintenanceTask
    let groupName: String
    let onComplete: () -> Void
    let onBypass: (TaskBypassAction) -> Void

    var body: some View {
        let title = TaskTitle.displayItemTitle(item: task.item, group: groupName)
        HStack(alignment: .top, spacing: 12) {
            // Whole row navigates to detail; Done stays outside the link.
            NavigationLink(value: task.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let eta = TaskTitle.estimatedTimeLabel(minutes: task.estimatedMinutes) {
                        Text(eta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(TaskTitle.dueDateLabel(date: task.nextDue))
                        .font(.caption)
                        .foregroundStyle(dueDateColor)
                    if let badge = task.runHoursBadge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(
                                task.overdueMeter == true
                                    ? Color.red
                                    : (task.dueMeter == true ? Color.orange : Color.secondary)
                            )
                    } else if task.requiresMeterOnComplete {
                        Label("Meter schedule", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            VStack(alignment: .trailing, spacing: 8) {
                TaskOriginBadge(origin: task.origin)
                Button("Done", action: onComplete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                TaskBypassMenu(task: task, onSelect: onBypass) {
                    Text("Bypass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.indigo)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
    }

    private var dueDateColor: Color {
        switch task.dueStatus {
        case .critical, .overdue:
            return .red
        case .dueSoon:
            return .orange
        case .ok:
            return .secondary
        }
    }
}

struct TaskOriginBadge: View {
    let origin: TaskOrigin

    var body: some View {
        Text(origin.label)
            .font(.caption2)
            .fontWeight(.bold)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(origin == .manufacturer ? Color.blue.opacity(0.16) : Color.orange.opacity(0.16))
            .foregroundStyle(origin == .manufacturer ? Color.blue : Color.orange)
            .clipShape(Capsule())
    }
}
