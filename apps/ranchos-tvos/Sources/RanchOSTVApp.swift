import SwiftUI

@main
struct RanchOSTVApp: App {
    var body: some Scene {
        WindowGroup {
            TodayView(dashboard: .developmentFixture)
        }
    }
}
