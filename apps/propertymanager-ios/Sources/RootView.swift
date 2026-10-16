import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: PropertyStore
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
                QuitAppButton()
                    .padding(.trailing, 4)
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

/// Mac-style window dots. Only red works: iOS has no minimize or zoom for apps.
private struct QuitAppButton: View {
    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isConfirming = true
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                    .frame(width: 14, height: 14)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(-8)
            .accessibilityLabel("Quit Property Manager")
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 14, height: 14)
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 14, height: 14)
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog("Quit Property Manager?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Quit", role: .destructive) { quit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved changes are kept. Open Property Manager again from the Home Screen.")
        }
    }

    /// Destroy the scene session so iOS removes the card from the App Switcher.
    /// Do not call exit() on the happy path: killing the process early leaves a stale snapshot.
    private func quit() {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        else {
            exit(0)
            return
        }
        let options = UIWindowSceneDestructionRequestOptions()
        options.windowDismissalAnimation = .standard
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: options) { _ in
            // Destruction failed; ending the process is the only remaining option.
            exit(0)
        }
    }
}
