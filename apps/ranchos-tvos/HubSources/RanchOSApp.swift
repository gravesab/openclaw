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
    @State private var propertyStore = RanchOSPropertyLiveStore(mode: RanchOSLaunchMode.resolve())
    @State private var livestockStore = RanchOSLivestockStore()

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(tvOS)
                RanchOSTVHomeView(
                    dashboard: dashboard,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    appearance: $appearance)
                #else
                RanchOSHomeView(
                    dashboard: dashboard,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    appearance: $appearance)
                #endif
            }
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}
