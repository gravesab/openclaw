import SwiftUI

struct AssetListView: View {
    @EnvironmentObject private var store: PropertyStore
    @State private var selectedAsset: RanchAsset?
    @State private var assetPendingDeactivate: RanchAsset?
    @State private var showDeactivateConfirm = false
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
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Filter assets or tasks (any word)"
        )
        .navigationDestination(for: UUID.self) { assetId in
            AssetDetailView(assetId: assetId)
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
            Text(asset.name)
                .font(.headline)
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
        .padding(.vertical, 4)
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
