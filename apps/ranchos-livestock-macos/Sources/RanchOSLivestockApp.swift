import Observation
import SwiftUI

@main
struct RanchOSLivestockApp: App {
    @State private var store = LivestockStore()

    var body: some Scene {
        WindowGroup("Ranch OS Livestock") {
            LivestockRootView(store: store)
                .task { await store.loadFixtures() }
        }
        .defaultSize(width: 1_250, height: 780)
    }
}
