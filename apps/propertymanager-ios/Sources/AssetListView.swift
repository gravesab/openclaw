import SwiftUI

struct AssetListView: View {
    @EnvironmentObject private var store: PropertyStore
    @State private var selectedAsset: RanchAsset?
    @State private var assetPendingDeactivate: RanchAsset?
    @State private var showDeactivateConfirm = false
    @State private var showNewGroup = false
    @State private var searchText = ""

    var body: some View {
        List {
            if store.isLoadingAssets {
                ProgressView("Loading assets…")
            }
            ForEach(store.assetMatches(for: searchText)) { match in
                let asset = match.asset
                NavigationLink(value: asset.id) {
                    AssetRowView(asset: asset, matchingTaskTitles: match.matchingTaskTitles)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    store.selectedTaskAssetId = asset.id
                })
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Deactivate", role: .destructive) {
                        assetPendingDeactivate = asset
                        showDeactivateConfirm = true
                    }
                }
            }
        }
        .navigationTitle("Assets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewGroup = true
                } label: {
                    Label("New Pseudo Asset", systemImage: "square.stack.3d.up")
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Filter assets or tasks (any word)"
        )
        .navigationDestination(for: UUID.self) { assetId in
            AssetDetailView(assetId: assetId)
        }
        .sheet(isPresented: $showNewGroup) {
            NewPseudoGroupSheet()
        }
        .confirmationDialog(
            assetPendingDeactivate.map { "Deactivate \($0.name)?" } ?? "Deactivate asset?",
            isPresented: $showDeactivateConfirm,
            titleVisibility: .visible
        ) {
            Button("Deactivate", role: .destructive) {
                guard let asset = assetPendingDeactivate else { return }
                Task {
                    _ = await store.deactivateAsset(id: asset.id)
                    await store.refreshAssets()
                    assetPendingDeactivate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                assetPendingDeactivate = nil
            }
        } message: {
            Text("This hides the asset from lists. Meter history is kept and it can be reactivated later from the API or a future Reactivate UI.")
        }
        .refreshable {
            await store.refreshAssets()
        }
        .task {
            await store.refreshAssets()
        }
    }
}

struct AssetRowView: View {
    let asset: RanchAsset
    var matchingTaskTitles: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(asset.name)
                    .font(.headline)
                if asset.isPseudo {
                    Text("Group")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            if asset.isPseudo {
                let count = asset.attachments?.count ?? 0
                Text(count == 1 ? "1 asset" : "\(count) assets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let hostName = asset.host?.name {
                Text("Attached to \(hostName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(matchingTaskTitles.prefix(3), id: \.self) { title in
                Label(title, systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(2)
            }
            if matchingTaskTitles.count > 3 {
                Text("+\(matchingTaskTitles.count - 3) more matching tasks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !asset.isPseudo {
                if let meter = asset.meter, meter.hasMeter {
                    Text("\(formatValue(meter.currentValue)) \(meter.unit)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Frequency-based maintenance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let overdue = asset.pmSummary?.overdueMeterCount, overdue > 0 {
                    Text("\(overdue) overdue service\(overdue == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

struct NewPseudoGroupSheet: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = "Equipment"
    @State private var errorText: String?
    @State private var saving = false

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var existingNames: Set<String> {
        Set(store.assets.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    private var categoryChoices: [String] {
        let values = Set(store.assets.compactMap(\.category) + ["Equipment", "Vehicle", "House", "Property"])
        return values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(categoryChoices, id: \.self) { Text($0).tag($0) }
                    }
                } footer: {
                    Text("A pseudo asset is a display group (for example Mowers). Only name and category are required. Attach real assets with Attached to. No meter, manufacturer, or tasks.")
                }
                if existingNames.contains(normalizedName), !normalizedName.isEmpty {
                    Text("An asset with this name already exists.")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Pseudo Asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(
                        saving || normalizedName.isEmpty || existingNames.contains(normalizedName)
                    )
                }
            }
        }
    }

    private func create() async {
        saving = true
        errorText = nil
        defer { saving = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await store.client.createPseudoGroup(name: trimmed, category: category)
            await store.refreshAssets()
            store.selectedTaskAssetId = created.id
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
