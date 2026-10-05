import Foundation

enum ManualLibraryAssetSelection {
    /// Use the open task's asset only when that asset is in the catalog.
    /// A missing task, a task with no asset, or an unknown id stays unselected.
    static func initialAssetID(selectedTaskAssetID: UUID?, knownAssetIDs: some Sequence<UUID>) -> UUID? {
        guard let selectedTaskAssetID else { return nil }
        return knownAssetIDs.contains(selectedTaskAssetID) ? selectedTaskAssetID : nil
    }
}

enum ManualLibraryListState: Equatable {
    case needsSelection
    case loading
    case requestError
    case empty
    case populated

    static func resolve(
        selectedAssetID: UUID?,
        isLoading: Bool,
        hasRequestError: Bool,
        manualCount: Int
    ) -> ManualLibraryListState {
        guard selectedAssetID != nil else { return .needsSelection }
        if isLoading { return .loading }
        if hasRequestError { return .requestError }
        if manualCount == 0 { return .empty }
        return .populated
    }
}
