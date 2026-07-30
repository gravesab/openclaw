import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PropertyStore
    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @State private var categoryPendingDelete: MaintenanceCategory?
    @State private var showDeleteConfirm = false
    @State private var showReassignSheet = false
    @State private var connectionBusy = false
    @State private var showResultAlert = false
    @State private var resultAlertTitle = ""
    @State private var resultAlertMessage = ""

    private var deletableCategories: [MaintenanceCategory] {
        store.categories
            .filter { $0.name.caseInsensitiveCompare("House") != .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                TextField("API Base URL", text: $store.apiBaseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textContentType(.URL)

                Text("Use your Intel Mini Tailscale or LAN address, for example http://100.85.36.72:5062")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("PropertyManager API")
            }

            Section("Authentication") {
                SecureField("API Key", text: $store.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                SecureField("Operator PIN (optional)", text: $store.operatorPIN)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                TextField("Operator identity", text: $store.operatorIdentity)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Paste the API key here on the phone. Do not put secrets in Xcode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                Button {
                    Task { await runConnectionAction(.test) }
                } label: {
                    connectionRow(title: "Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(connectionBusy)

                Button {
                    Task { await runConnectionAction(.refreshTasks) }
                } label: {
                    connectionRow(title: "Refresh Tasks", systemImage: "arrow.clockwise")
                }
                .disabled(connectionBusy)

                Button {
                    Task { await runConnectionAction(.refreshAssets) }
                } label: {
                    connectionRow(title: "Refresh Assets", systemImage: "wrench.and.screwdriver")
                }
                .disabled(connectionBusy)

                if connectionBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Working…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let status = store.statusMessage, !connectionBusy {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = store.errorMessage, !connectionBusy {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Asset and meter endpoints use /v1/. Task endpoints use the root API path.")
            }
            .buttonStyle(.borderless)

            Section {
                if deletableCategories.isEmpty {
                    Text("No removable categories")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(deletableCategories) { category in
                        HStack {
                            Image(systemName: category.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                if category.isBuiltIn {
                                    Text("Built-in")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            let count = store.activeTaskCount(inCategoryNamed: category.name)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                categoryPendingDelete = category
                                switch CategoryDeleteRouting.nextStep(for: category, store: store) {
                                case .emptyConfirm:
                                    showDeleteConfirm = true
                                case .reassignSheet:
                                    showReassignSheet = true
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Swipe left to delete. If the category has active tasks, choose where to move them first. House cannot be deleted.")
            }

            Section("On this phone") {
                LabeledContent("Tasks loaded", value: "\(store.tasks.count)")
                LabeledContent("Assets loaded", value: "\(store.assets.count)")
                LabeledContent("Categories", value: "\(store.categories.count)")
                LabeledContent("Overdue", value: "\(store.overdueCount)")
            }
        }
        .navigationTitle("Settings")
        .alert(resultAlertTitle, isPresented: $showResultAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultAlertMessage)
        }
        .categoryDeleteFlow(
            categoryPendingDelete: $categoryPendingDelete,
            showEmptyConfirm: $showDeleteConfirm,
            showReassignSheet: $showReassignSheet
        )
    }

    private func connectionRow(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private enum ConnectionAction {
        case test
        case refreshTasks
        case refreshAssets
    }

    @MainActor
    private func runConnectionAction(_ action: ConnectionAction) async {
        connectionBusy = true
        defer { connectionBusy = false }

        switch action {
        case .test:
            await store.testConnection()
        case .refreshTasks:
            await store.refresh()
        case .refreshAssets:
            await store.refreshAssets()
        }

        if let error = store.errorMessage {
            resultAlertTitle = "Failed"
            resultAlertMessage = error
        } else {
            switch action {
            case .test:
                resultAlertTitle = "Online"
            case .refreshTasks:
                resultAlertTitle = "Tasks refreshed"
            case .refreshAssets:
                resultAlertTitle = "Assets refreshed"
            }
            resultAlertMessage = store.statusMessage ?? "Success"
        }
        showResultAlert = true
    }
}
