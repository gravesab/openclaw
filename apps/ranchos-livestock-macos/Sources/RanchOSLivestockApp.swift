import Observation
import SwiftUI

@main
struct RanchOSLivestockApp: App {
    private static let records = LivestockDevLoopbackRead.load()
    @State private var store = LivestockStore(
        connection: LivestockReadConnection(authorizedProvider: RanchOSLivestockApp.records),
        liveRecords: RanchOSLivestockApp.records
    )

    var body: some Scene {
        WindowGroup("Livestock Management") {
            LivestockRootView(store: store)
                .task { await store.loadAuthorizedRead() }
        }
        .defaultSize(width: 1_250, height: 780)
    }
}
