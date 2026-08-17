import SwiftUI

struct TaskListView: View {
    @EnvironmentObject private var store: PropertyStore
    @Binding var taskNavigationPath: NavigationPath
    @State private var completingTask: MaintenanceTask?
    @State private var completionNote = ""
    @State private var meterConfirmValue = ""
    @State private var confirmCurrentMeter = false
    @State private var linkedAsset: RanchAsset?
    @State private var completionReceipt: TaskCompletionReceipt?
    @State private var isProcessingCompletionReceipt = false

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
                            groupName: section.name
                        ) {
                            completingTask = task
                            completionNote = ""
                            meterConfirmValue = ""
                            confirmCurrentMeter = false
                            if task.requiresMeterOnComplete, let assetId = task.assetId {
                                Task { await loadAssetForCompletion(assetId) }
                            }
                        }
                    }
                }
            }
        }
        .navigationDestination(for: UUID.self) { taskID in
            TaskDetailView(
                taskID: taskID,
                onReturnToTasks: {
                    taskNavigationPath = NavigationPath()
                }
            )
        }
        .navigationTitle("Tasks")
        .searchable(text: $store.searchText)
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
            completionSheet(task)
        }
        .sheet(item: $completionReceipt) { receipt in
            completionResultSheet(receipt)
        }
    }

    @ViewBuilder
    private func completionSheet(_ task: MaintenanceTask) -> some View {
        let group = TaskTitle.displayAssetName(task: task, assets: store.assets)
        let title = TaskTitle.displayItemTitle(item: task.item, group: group)
        NavigationStack {
            Form {
                Section("Task") {
                    Text("\(group) / \(title)")
                    if let eta = TaskTitle.estimatedTimeLabel(minutes: task.estimatedMinutes) {
                        Text(eta)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Note") {
                    TextField("Completion note", text: $completionNote)
                }
                if task.requiresMeterOnComplete {
                    Section("Meter at completion") {
                        if let asset = linkedAsset, let meter = asset.meter {
                            Text("Current: \(formatValue(meter.currentValue)) \(meter.unit)")
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Confirm current meter reading", isOn: $confirmCurrentMeter)
                            .onChange(of: confirmCurrentMeter) { _, on in
                                if on { meterConfirmValue = "" }
                            }
                        if !confirmCurrentMeter {
                            TextField("Enter new meter value", text: $meterConfirmValue)
                                .keyboardType(.decimalPad)
                        }
                    }
                }
            }
            .navigationTitle("Complete task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { completingTask = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await complete(task) }
                    }
                    .disabled(store.isCompleting || !meterInputValid(task))
                }
            }
        }
    }

    private func meterInputValid(_ task: MaintenanceTask) -> Bool {
        guard task.requiresMeterOnComplete else { return true }
        if confirmCurrentMeter { return true }
        return Double(meterConfirmValue.replacingOccurrences(of: ",", with: ".")) != nil
    }

    private func complete(_ task: MaintenanceTask) async {
        var meterValue: Double?
        if task.requiresMeterOnComplete, !confirmCurrentMeter {
            meterValue = Double(meterConfirmValue.replacingOccurrences(of: ",", with: "."))
        }
        let receipt = await store.completeWithReceipt(
            task: task,
            note: completionNote.isEmpty ? nil : completionNote,
            meterValue: meterValue,
            confirmCurrentMeter: confirmCurrentMeter
        )

        if let receipt {
            completingTask = nil
            completionReceipt = receipt
        }
    }

    @ViewBuilder
    private func completionResultSheet(_ receipt: TaskCompletionReceipt) -> some View {
        let group = TaskTitle.displayAssetName(task: receipt.task, assets: store.assets)
        let title = TaskTitle.displayItemTitle(item: receipt.task.item, group: group)

        NavigationStack {
            Form {
                Section {
                    Label("Task Completed", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))

                    Text("\(group) / \(title)")
                        .font(.headline)
                }

                Section("Completion") {
                    LabeledContent("Completed by", value: receipt.completedBy)
                    LabeledContent("Device", value: receipt.deviceLabel)
                    LabeledContent(
                        "Completed",
                        value: completionTimestamp(receipt.completedAt)
                    )
                }

                Section {
                    Text(
                        "Undo restores the task to its exact pre-completion state. "
                        + "Continue accepts this completion and removes it from the current active display."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Task Completed")
            .interactiveDismissDisabled(isProcessingCompletionReceipt)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Undo") {
                        Task { await undo(receipt) }
                    }
                    .disabled(isProcessingCompletionReceipt)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        Task { await continueCompletion(receipt) }
                    }
                    .disabled(isProcessingCompletionReceipt)
                }
            }
        }
    }

    private func undo(_ receipt: TaskCompletionReceipt) async {
        isProcessingCompletionReceipt = true
        defer { isProcessingCompletionReceipt = false }

        let ok = await store.undoCompletion(
            taskID: receipt.task.id,
            completionID: receipt.completionID
        )

        if ok {
            completionReceipt = nil
        }
    }

    private func continueCompletion(_ receipt: TaskCompletionReceipt) async {
        isProcessingCompletionReceipt = true
        defer { isProcessingCompletionReceipt = false }

        let ok = await store.acknowledgeCompletion(
            taskID: receipt.task.id,
            completionID: receipt.completionID
        )

        if ok {
            store.removeCompletedTaskFromCurrentDisplay(taskID: receipt.task.id)
            completionReceipt = nil
        }
    }

    private func completionTimestamp(_ raw: String) -> String {
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

    private func loadAssetForCompletion(_ assetId: UUID) async {
        do {
            linkedAsset = try await store.client.fetchAsset(id: assetId)
            if let current = linkedAsset?.meter?.currentValue {
                meterConfirmValue = formatValue(current)
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

struct TaskRowView: View {
    let task: MaintenanceTask
    let groupName: String
    let onComplete: () -> Void

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
