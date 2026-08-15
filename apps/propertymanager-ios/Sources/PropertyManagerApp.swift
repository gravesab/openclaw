import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func from(storageValue: String) -> AppAppearance {
        AppAppearance(rawValue: storageValue) ?? .system
    }
}

@main
struct PropertyManagerApp: App {
    @StateObject private var store = PropertyStore()
    @AppStorage(PropertyManagerBuildEnvironment.appearanceKey)
    private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(AppAppearance.from(storageValue: appearanceRaw).colorScheme)
        }
    }
}
