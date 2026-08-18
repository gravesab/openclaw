import SwiftUI

struct MacAssetsPanel: View {
    @ObservedObject var store: MaintenanceStore
    @State private var showingNewAsset = false

    private var groupedAssets: [[MacRanchAsset]] {
        Dictionary(grouping: store.assets) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        .values
        .map { Array($0) }
    }

    private var displayAssets: [MacRanchAsset] {
        groupedAssets.compactMap { group in
            group.sorted { lhs, rhs in
                let lhsScore = (lhs.tasks?.count ?? 0) + (lhs.meterActivatedAt == nil ? 0 : 10)
                let rhsScore = (rhs.tasks?.count ?? 0) + (rhs.meterActivatedAt == nil ? 0 : 10)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.externalId < rhs.externalId
            }.first
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hiddenDuplicateCount: Int { store.assets.count - displayAssets.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assets")
                    .font(.title2.bold())
                Spacer()
                Button {
                    showingNewAsset = true
                } label: {
                    Label("New Asset", systemImage: "plus")
                }
                Button {
                    Task { await store.refreshAssets() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding()

            if store.assets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(store.assetLoadError ?? "No active assets were returned by DEV PostgreSQL.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await store.refreshAssets() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                if hiddenDuplicateCount > 0 {
                    Text("\(hiddenDuplicateCount) duplicate asset record(s) hidden. History and task links are preserved pending safe reconciliation.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                HStack(spacing: 0) {
                    List(selection: $store.selectedTaskAssetId) {
                        ForEach(displayAssets) { asset in
                            VStack(alignment: .leading) {
                                Text(asset.name).font(.headline)
                                if asset.meterNeedsActivation {
                                    Text("Meter proposed — activate")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else if let meter = asset.meter {
                                    if meter.hasMeter {
                                        Text("\(format(meter.currentValue)) \(meter.unit)")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No operating meter")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .tag(asset.id as UUID?)
                        }
                    }
                    .frame(minWidth: 340, idealWidth: 420, maxWidth: 480)

                    Divider()

                    if let asset = displayAssets.first(where: { $0.id == store.selectedTaskAssetId }) {
                        MacAssetDetailPanel(asset: asset, store: store) {
                            store.selectedTaskAssetId = nil
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text("Select an Asset")
                                .font(.title2.bold())
                            Text("Choose an asset to review its details and linked maintenance tasks.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task { await store.refreshAssets() }
        .sheet(isPresented: $showingNewAsset) {
            NewAssetSheet(
                categories: store.categories.map(\.name),
                existingNames: Set(store.assets.map {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }),
                createAction: { draft in
                    let created = try await store.apiClient.createAsset(
                        name: draft.name,
                        category: draft.category,
                        manufacturer: draft.manufacturer,
                        model: draft.model,
                        location: draft.location,
                        proposedMeterType: draft.meterType
                    )
                    await store.refreshAssets()
                    store.selectedTaskAssetId = created.id
                }
            )
        }
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

private struct NewAssetDraft {
    var name = ""
    var category = "Equipment"
    var manufacturer = ""
    var model = ""
    var location = ""
    var meterType = "none"
}

private struct NewAssetSheet: View {
    let categories: [String]
    let existingNames: Set<String>
    let createAction: (NewAssetDraft) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewAssetDraft()
    @State private var errorText: String?
    @State private var saving = false

    private var normalizedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var categoryChoices: [String] {
        let values = Set(categories + ["Equipment", "Vehicle", "House", "Property"])
        return values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Asset").font(.title2.bold())
            Text("Create the asset once, then link its maintenance tasks from each task's Linked Asset field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Asset name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            Picker("Category", selection: $draft.category) {
                ForEach(categoryChoices, id: \.self) { Text($0).tag($0) }
            }

            HStack {
                TextField("Manufacturer", text: $draft.manufacturer)
                TextField("Model", text: $draft.model)
            }
            HStack {
                TextField("Location", text: $draft.location)
                Picker("Operating meter", selection: $draft.meterType) {
                    Text("Runtime hours").tag("runtime_hours")
                    Text("Mileage").tag("mileage")
                    Text("Cycles").tag("cycles")
                    Text("None").tag("none")
                }
            }

            Text("Choose the operating meter independently of category. Any asset may use runtime hours, mileage, cycles, or no meter.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if existingNames.contains(normalizedName), !normalizedName.isEmpty {
                Text("An asset with this name already exists. Asset names must be unique.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create Asset") {
                    Task { await create() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    saving || normalizedName.isEmpty || existingNames.contains(normalizedName)
                )
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 560)
    }

    private func create() async {
        saving = true
        errorText = nil
        defer { saving = false }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await createAction(draft)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct MacAssetDetailPanel: View {
    let asset: MacRanchAsset
    @ObservedObject var store: MaintenanceStore
    var onDeactivated: (() -> Void)? = nil
    @State private var entryMode: MacMeterEntryMode = .absolute
    @State private var valueText = ""
    @State private var note = ""
    @State private var pendingPreview: MacLowerReadingPreview?
    @State private var correctionReason = "correction"
    @State private var readings: [MacMeterReading] = []
    @State private var message: String?
    @State private var isActivating = false
    @State private var isDeactivating = false
    @State private var showDeactivateConfirm = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isSavingName = false

    private var linkedTasks: [MaintenanceTask] {
        store.tasks
            .filter { $0.assetId == asset.id }
            .sorted { lhs, rhs in
                TaskTitle.displayItemTitle(item: lhs.item, group: asset.name)
                    .localizedCaseInsensitiveCompare(
                        TaskTitle.displayItemTitle(item: rhs.item, group: asset.name)
                    ) == .orderedAscending
            }
    }

    private enum MacMeterEntryMode: String, CaseIterable, Identifiable {
        case absolute
        case add

        var id: String { rawValue }

        func title(for meterType: String?) -> String {
            switch self {
            case .absolute: return "Absolute"
            case .add:
                switch meterType {
                case "mileage": return "Add miles"
                case "cycles": return "Add cycles"
                default: return "Add hours"
                }
            }
        }

        func fieldLabel(for meterType: String?) -> String {
            switch self {
            case .absolute: return "Meter reading"
            case .add:
                switch meterType {
                case "mileage": return "Miles since last"
                case "cycles": return "Cycles since last"
                default: return "Hours since last"
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    if isRenaming {
                        TextField("Asset name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3.bold())
                            .onSubmit { Task { await saveName() } }
                    } else {
                        Text(asset.name).font(.title3.bold())
                    }
                    Spacer()
                    if isRenaming {
                        Button("Cancel") {
                            renameText = asset.name
                            isRenaming = false
                            message = nil
                        }
                        Button("Save Name") {
                            Task { await saveName() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSavingName || normalizedRename.isEmpty || renameIsDuplicate)
                    } else {
                        Button {
                            renameText = asset.name
                            isRenaming = true
                            message = nil
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                    Button("Deactivate", role: .destructive) {
                        showDeactivateConfirm = true
                    }
                    .disabled(isDeactivating)
                }

                if isRenaming, renameIsDuplicate {
                    Text("Another asset already uses this name.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if asset.meterNeedsActivation {
                    GroupBox("Proposed meter") {
                        if let proposed = asset.proposedMeter {
                            Text("Type: \(proposed.meterType ?? "none"), unit: \(proposed.unit ?? "—")")
                        }
                        Button("Activate meter") {
                            Task { await activateMeter() }
                        }
                        .disabled(isActivating)
                    }
                }

                if let meter = asset.meter, meter.hasMeter {
                    Text("\(format(meter.currentValue)) \(meter.unit)")
                        .font(.system(size: 36, weight: .bold))
                    Text("Current total (cumulative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if asset.meter?.hasMeter == true {
                    GroupBox("New reading") {
                        Picker("Mode", selection: $entryMode) {
                            ForEach(MacMeterEntryMode.allCases) { mode in
                                Text(mode.title(for: asset.meter?.meterType)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(pendingPreview != nil)
                        TextField(entryMode.fieldLabel(for: asset.meter?.meterType), text: $valueText)
                        TextField("Note", text: $note)
                        if let preview = pendingPreview {
                            if let prev = preview.previousValue, let proposed = preview.proposedValue {
                                Text("Previous: \(prev) → Proposed: \(proposed)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Picker("Reason", selection: $correctionReason) {
                                ForEach(preview.options ?? ["correction", "replacement", "rollover"], id: \.self) { opt in
                                    Text(opt.capitalized).tag(opt)
                                }
                            }
                        }
                        Button(pendingPreview == nil ? "Save reading" : "Confirm reading") {
                            Task { await saveReading() }
                        }
                        .disabled(valueText.isEmpty)
                    }
                } else {
                    GroupBox("Operating meter") {
                        Text("This asset does not use an hours, mileage, or cycles meter.")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Maintenance tasks") {
                    if linkedTasks.isEmpty {
                        Text("No tasks are linked to this asset in DEV PostgreSQL.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(linkedTasks) { task in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(TaskTitle.displayItemTitle(item: task.item, group: asset.name))
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Text(task.origin == .manufacturer ? "Manufacturer" : "Owner-added")
                                            .font(.caption)
                                            .foregroundStyle(task.origin == .manufacturer ? .blue : .orange)
                                    }
                                    HStack(spacing: 8) {
                                        Text(scheduleSummary(for: task))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if task.overdueMeter == true {
                                            Text("Overdue")
                                                .font(.caption.bold())
                                                .foregroundStyle(.red)
                                        } else if let remaining = task.remainingMeter {
                                            Text("\(NSDecimalNumber(decimal: remaining).stringValue) \(task.meterIntervalUnit ?? asset.meter?.unit ?? "units") left")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if task.id != linkedTasks.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                if let message {
                    Text(message).foregroundStyle(.secondary).font(.caption)
                }
            }
            .padding()
        }
        .confirmationDialog(
            "Deactivate \(asset.name)?",
            isPresented: $showDeactivateConfirm,
            titleVisibility: .visible
        ) {
            Button("Deactivate", role: .destructive) {
                Task { await deactivate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This hides the asset from lists. Meter history is kept and it can be reactivated later from the API or a future Reactivate UI.")
        }
        .task { await loadReadings() }
    }

    private var normalizedRename: String {
        renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var renameIsDuplicate: Bool {
        let candidate = normalizedRename.lowercased()
        guard !candidate.isEmpty else { return false }
        return store.assets.contains {
            $0.id != asset.id &&
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate
        }
    }

    private func saveName() async {
        let candidate = normalizedRename
        guard !candidate.isEmpty else {
            message = "Asset name cannot be blank."
            return
        }
        guard !renameIsDuplicate else {
            message = "Another asset already uses this name."
            return
        }
        guard candidate != asset.name else {
            isRenaming = false
            return
        }
        isSavingName = true
        defer { isSavingName = false }
        do {
            _ = try await store.apiClient.renameAsset(id: asset.id, name: candidate)
            await store.refreshAssets()
            renameText = candidate
            isRenaming = false
            message = "Asset renamed. Linked tasks and history were preserved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadReadings() async {
        do {
            readings = try await store.apiClient.fetchMeterReadings(assetId: asset.id)
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveReading() async {
        guard let amount = Double(valueText.replacingOccurrences(of: ",", with: ".")) else { return }
        if entryMode == .add, amount <= 0 {
            message = "Enter a positive amount since last reading."
            return
        }
        do {
            if let preview = pendingPreview {
                _ = try await store.apiClient.confirmMeterReading(
                    assetId: asset.id,
                    preview: preview,
                    correctionReason: correctionReason,
                    note: note.isEmpty ? nil : note
                )
                message = "Confirmed."
                pendingPreview = nil
            } else if entryMode == .add {
                _ = try await store.apiClient.submitMeterReading(
                    assetId: asset.id,
                    delta: amount,
                    note: note.isEmpty ? nil : note
                )
                message = "Added \(format(amount))."
            } else {
                _ = try await store.apiClient.submitMeterReading(
                    assetId: asset.id,
                    value: amount,
                    note: note.isEmpty ? nil : note
                )
                message = "Saved."
            }
            await store.refreshAssets()
            await loadReadings()
        } catch MacMeterError.lowerReadingConfirmation(let preview) {
            pendingPreview = preview
            message = "Lower than current — choose reason and confirm."
        } catch {
            message = error.localizedDescription
        }
    }

    private func activateMeter() async {
        isActivating = true
        defer { isActivating = false }
        do {
            _ = try await store.apiClient.activateMeter(assetId: asset.id)
            message = "Meter activated."
            await store.refreshAssets()
        } catch {
            message = error.localizedDescription
        }
    }

    private func deactivate() async {
        isDeactivating = true
        defer { isDeactivating = false }
        do {
            try await store.apiClient.deactivateAsset(id: asset.id)
            message = "Deactivated."
            await store.refreshAssets()
            onDeactivated?()
        } catch {
            message = error.localizedDescription
        }
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func scheduleSummary(for task: MaintenanceTask) -> String {
        let kind = task.scheduleKind.lowercased()
        let meterType = asset.meter?.meterType ?? "none"
        let meterLabel: String
        switch meterType {
        case "runtime_hours": meterLabel = "Runtime hours"
        case "mileage": meterLabel = "Mileage"
        case "cycles": meterLabel = "Cycles"
        default: meterLabel = "Meter"
        }

        switch kind {
        case "meter": return meterLabel
        case "both": return "\(task.frequency.rawValue) + \(meterLabel)"
        default: return task.frequency.rawValue
        }
    }
}
