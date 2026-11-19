import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PropertyManagerBuildEnvironment.appearanceKey)
    private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Text(PropertyManagerBuildIdentity.label)
                .font(.caption2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .foregroundStyle(.black)
                .background(PropertyManagerBuildEnvironment.isDevelopment ? Color.orange : Color.green)
                .accessibilityLabel(
                    "Property Manager \(PropertyManagerBuildIdentity.environment) version "
                        + PropertyManagerBuildIdentity.version)

            HStack(spacing: 8) {
                Text("Appearance")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            TabView {
                NavigationStack {
                    TaskListView()
                }
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }

                NavigationStack {
                    WeekHorizonView()
                }
                .tabItem {
                    Label("Weeks", systemImage: "calendar")
                }

                NavigationStack {
                    AssetListView()
                }
                .tabItem {
                    Label("Assets", systemImage: "wrench.and.screwdriver")
                }

                NavigationStack {
                    WorkRequestIntakeView()
                }
                .tabItem {
                    Label("Request", systemImage: "square.and.pencil")
                }

                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .fullWritingTools()
        .onAppear { SpellChecking.install() }
        // Let the system Home gesture suspend the app cleanly: release the mic/session.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                FieldDictation.shared.stop()
            }
        }
        .task {
            await store.refresh()
            await store.refreshAssets()
        }
        .onOpenURL { url in
            store.handleDeepLink(url)
        }
        .alert(
            "Property Manager Error",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "Unknown error.")
        }
    }
}
