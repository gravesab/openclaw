import SwiftUI

struct AssetDetailView: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss
    let assetId: UUID

    @State private var asset: RanchAsset?
    @State private var readings: [MeterReading] = []
    @State private var showMeterSheet = false
    @State private var showVoiceSheet = false
    @State private var editingTask: AssetTaskSummary?
    @State private var isActivating = false
    @State private var isDeactivating = false
    @State private var showDeactivateConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let asset {
                    if asset.meterNeedsActivation {
                        proposedMeterBanner(asset)
                    }
                    meterCard(asset)
                    serviceCard(asset)
                    historyCard
                    deactivateCard
                } else {
                    ProgressView()
                }
            }
            .padding()
        }
        .navigationTitle(asset?.name ?? "Asset")
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                if asset != nil {
                    Button("Deactivate", role: .destructive) {
                        showDeactivateConfirm = true
                    }
                    .disabled(isDeactivating)
                }
            }
            if asset?.meter?.hasMeter == true {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showVoiceSheet = true
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    Button(asset?.meter?.updateButtonTitle ?? "Update Meter") {
                        showMeterSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showMeterSheet) {
            if let asset {
                MeterEntrySheet(asset: asset) { updated in
                    self.asset = updated
                    Task { await loadReadings() }
                }
            }
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceMeterEntrySheet { updated in
                self.asset = updated
                Task { await loadReadings() }
            }
        }
        .confirmationDialog(
            "Deactivate \(asset?.name ?? "asset")?",
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
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await loadAsset()
        }
    }

    @ViewBuilder
    private var deactivateCard: some View {
        Button(role: .destructive) {
            showDeactivateConfirm = true
        } label: {
            if isDeactivating {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Remove from list")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isDeactivating)
    }

    @ViewBuilder
    private func proposedMeterBanner(_ asset: RanchAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meter proposed — review and activate")
                .font(.headline)
            if let proposed = asset.proposedMeter {
                Text("Type: \(proposed.meterType ?? "none"), unit: \(proposed.unit ?? "—")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await activateMeter() }
            } label: {
                if isActivating {
                    ProgressView()
                } else {
                    Text("Activate meter")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isActivating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func meterCard(_ asset: RanchAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current reading")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(formatValue(asset.meter?.currentValue))
                    .font(.system(size: 44, weight: .bold))
                Text(asset.meter?.unit ?? "")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            if asset.meter?.hasMeter == true {
                Button(asset.meter?.updateButtonTitle ?? "Update Meter") {
                    showMeterSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func serviceCard(_ asset: RanchAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming service")
                .font(.headline)
            let linked = asset.tasks ?? []
            if linked.isEmpty {
                Text("No service tasks linked yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(linked) { task in
                    Button {
                        editingTask = task
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.item)
                                    .foregroundStyle(.primary)
                                if let badge = task.runHoursBadge {
                                    Text(badge)
                                        .font(.caption)
                                        .foregroundStyle(
                                            task.overdueMeter == true
                                                ? Color.red
                                                : (task.dueMeter == true ? Color.orange : Color.secondary)
                                        )
                                } else if let trigger = task.nextDueMeterValue {
                                    Text("Due at \(formatDecimal(trigger)) hrs")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if asset.meter?.meterType == "runtime_hours", asset.meterActivatedAt != nil {
                                    Text("Tap to set hour trigger")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(item: $editingTask) { task in
            let full = store.tasks.first(where: { $0.id == task.id })
            RunHoursTriggerSheet(
                taskID: task.id,
                taskTitle: task.item,
                assetID: full?.assetId ?? asset.id,
                currentScheduleKind: full?.scheduleKind ?? task.scheduleKind,
                calendarIsMeaningful: full.map { $0.warningDays > 0 } ?? true,
                initialTrigger: full?.nextDueMeterValue ?? task.nextDueMeterValue,
                initialInterval: full?.meterIntervalValue ?? task.meterIntervalValue
            )
            .environmentObject(store)
            .onDisappear {
                Task { await loadAsset() }
            }
        }
    }

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading history")
                .font(.headline)
            if readings.isEmpty {
                Text("No readings yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(readings.prefix(10)) { reading in
                    HStack {
                        Text(formatValue(reading.value))
                        Spacer()
                        Text(reading.readingAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let usage = reading.usageSincePrevious {
                        Text("+\(formatValue(usage)) since previous")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadAsset() async {
        do {
            asset = try await store.client.fetchAsset(id: assetId)
            await loadReadings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadReadings() async {
        do {
            readings = try await store.client.fetchMeterReadings(assetId: assetId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func activateMeter() async {
        isActivating = true
        defer { isActivating = false }
        do {
            let updated = try await store.client.activateMeter(assetId: assetId)
            asset = updated
            await store.refreshAssets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deactivate() async {
        isDeactivating = true
        defer { isDeactivating = false }
        let ok = await store.deactivateAsset(id: assetId)
        if ok {
            await store.refreshAssets()
            dismiss()
        } else if let message = store.errorMessage {
            errorMessage = message
        }
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func formatDecimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
