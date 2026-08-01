import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PropertyStore

    var body: some View {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Image(systemName: "hammer.fill")
                Text("PROPERTY MANAGER — DEVELOPMENT")
                    .fontWeight(.bold)
                Spacer()
                Text("DEV DATA")
                    .font(.caption.bold())
            }
            .font(.caption)
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Property Manager development environment")
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
