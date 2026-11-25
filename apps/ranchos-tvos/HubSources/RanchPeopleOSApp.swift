import SwiftUI

enum RanchPeopleOSAppearance: String, CaseIterable, Identifiable {
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

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct RanchPeopleOSApp: App {
    @State private var peopleStore = RanchOSPeopleStore()
    @State private var appearance = RanchPeopleOSAppearance.system

    var body: some Scene {
        WindowGroup(RanchPeopleOSTitle.full) {
            NavigationStack {
                RanchOSPeopleView(store: peopleStore)
            }
            .preferredColorScheme(appearance.scheme)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(RanchPeopleOSAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                }
            }
        }
    }
}
