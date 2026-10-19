import SwiftUI

enum RanchOSAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct RanchOSApp: App {
    private let dashboard = RanchOSHubDashboard.developmentFixture
    @State private var appearance: RanchOSAppearance = .system
    @State private var liveSession = RanchOSLiveSession()
    @State private var propertyStore = RanchOSPropertyLiveStore()
    @State private var livestockStore = RanchOSLivestockStore()
    @State private var peopleDirectory = RanchOSPeopleDirectory.developmentOwner()

    var body: some Scene {
        WindowGroup(RanchOSBuildInfo.display(for: liveSession.environment)) {
            Group {
                #if os(tvOS)
                RanchOSTVHomeView(
                    dashboard: dashboard,
                    liveSession: liveSession,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    appearance: $appearance)
                #else
                RanchOSHomeView(
                    dashboard: dashboard,
                    liveSession: liveSession,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    peopleDirectory: peopleDirectory,
                    appearance: $appearance)
                #endif
            }
            .environment(\.ranchOSRuntimeEnvironment, liveSession.environment)
            .preferredColorScheme(appearance.colorScheme)
            .onChange(of: liveSession.environment) { _, environment in
                Task { await propertyStore.useEnvironment(environment) }
            }
        }
    }
}
