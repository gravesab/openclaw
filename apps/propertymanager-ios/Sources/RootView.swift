import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PropertyStore
    @AppStorage(PropertyManagerBuildEnvironment.appearanceKey)
    private var appearanceRaw: String = AppAppearance.system.rawValue
    @State private var taskNavigationPath = NavigationPath()

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
                NavigationStack(path: $taskNavigationPath) {
                    TaskListView(taskNavigationPath: $taskNavigationPath)
                }
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }

                NavigationStack {
                    AssetListView()
                }
                .tabItem {
                    Label("Assets", systemImage: "wrench.and.screwdriver")
                }

                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task {
            await store.refresh()
            await store.refreshAssets()
        }
        .onOpenURL { url in
            store.handleDeepLink(url)
        }
    }
}
