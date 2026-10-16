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
        WindowGroup(LivestockBuildStamp.current.name) {
            LivestockRootView(store: store)
                .task { await store.loadAuthorizedRead() }
        }
        #if os(macOS)
        .defaultSize(width: 1_250, height: 780)
        #endif
    }
}
