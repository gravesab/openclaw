import XCTest
@testable import PropertyManagerApp

final class ManualLibraryPresentationTests: XCTestCase {
    func testInitialAssetPrefersSelectedTaskAsset() {
        let assetID = UUID()
        XCTAssertEqual(
            ManualLibraryAssetSelection.initialAssetID(
                selectedTaskAssetID: assetID,
                knownAssetIDs: [assetID, UUID()]
            ),
            assetID
        )
    }

    func testInitialAssetRequiresExplicitSelectionWithoutTaskAsset() {
        let catalog = [UUID()]
        XCTAssertNil(
            ManualLibraryAssetSelection.initialAssetID(
                selectedTaskAssetID: nil,
                knownAssetIDs: catalog
            )
        )
    }

    func testInitialAssetIgnoresUnknownTaskAsset() {
        XCTAssertNil(
            ManualLibraryAssetSelection.initialAssetID(
                selectedTaskAssetID: UUID(),
                knownAssetIDs: [UUID()]
            )
        )
    }

    func testListStateDistinguishesSelectionLoadingErrorAndEmpty() {
        let assetID = UUID()
        XCTAssertEqual(
            ManualLibraryListState.resolve(selectedAssetID: nil, isLoading: false, hasRequestError: false, manualCount: 0),
            .needsSelection
        )
        XCTAssertEqual(
            ManualLibraryListState.resolve(selectedAssetID: assetID, isLoading: true, hasRequestError: false, manualCount: 0),
            .loading
        )
        XCTAssertEqual(
            ManualLibraryListState.resolve(selectedAssetID: assetID, isLoading: false, hasRequestError: true, manualCount: 0),
            .requestError
        )
        XCTAssertEqual(
            ManualLibraryListState.resolve(selectedAssetID: assetID, isLoading: false, hasRequestError: false, manualCount: 0),
            .empty
        )
        XCTAssertEqual(
            ManualLibraryListState.resolve(selectedAssetID: assetID, isLoading: false, hasRequestError: false, manualCount: 2),
            .populated
        )
    }

    func testLoadingHidesAnEarlierErrorAndEmptyResult() {
        let assetID = UUID()
        XCTAssertEqual(
            ManualLibraryListState.resolve(selectedAssetID: assetID, isLoading: true, hasRequestError: true, manualCount: 0),
            .loading
        )
    }
}
