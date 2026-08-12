import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PropertyStore
    @AppStorage(PropertyManagerBuildEnvironment.appearanceKey)
    private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if PropertyManagerBuildEnvironment.isDevelopment {
                Text("PROPERTY MANAGER DEV · DEV DATA")
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .foregroundStyle(.black)
                    .background(Color.orange)
                    .accessibilityLabel("Property Manager Development using development data")
            }

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
