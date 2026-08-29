import XCTest
@testable import RanchOSLivestock

final class LivestockFoundationTests: XCTestCase {
    func testCatalogSelectionIsControlledAndSpeciesChangeClearsIncompatibleValues() {
        var draft = AddAnimalDraft(); draft.selectSpecies(.cattle); draft.selectProductionType(.beef); draft.selectBreed(LivestockCatalog.breeds.first { $0.code == "angus" })
        XCTAssertTrue(draft.isValidCatalogSelection)
        draft.selectSpecies(.chicken)
        XCTAssertNil(draft.productionType); XCTAssertNil(draft.breed); XCTAssertFalse(draft.isValidCatalogSelection)
        XCTAssertFalse(Species.allCases.map(\.rawValue).contains("other"))
    }
    func testFixturePresentationContextAndBoundaryAreVisible() {
        XCTAssertEqual(FixturePresentationContext.preview.environment, "DEV fixture"); XCTAssertEqual(FixturePresentationContext.preview.statusLabel, "No authenticated tenant session")
        XCTAssertTrue(FixturePresentationBoundary.tenantDisclosure.contains("live tenant data is not connected"))
    }
    func testNavigationAndEssentialFixtureStatesAreDefined() {
        XCTAssertEqual(LivestockDestination.allCases.map(\.label), ["Herd overview", "Animals", "Care", "Feed and supplies", "Costs"])
        XCTAssertEqual(FixtureLoadState.empty(message: "Nothing here").message, "Nothing here"); XCTAssertEqual(FixtureLoadState.error(message: "Read failed").message, "Read failed"); XCTAssertEqual(FixtureLoadState.loading.message, "Loading fixture presentation…")
    }
    func testAddAnimalFlowIsInMemoryFixturePresentationOnly() {
        let draft = AddAnimalDraft(displayName: "Juniper", species: .cattle, productionType: .beef, breed: nil); let result = draft.submitFixturePresentation()
        XCTAssertEqual(result, FixturePresentationBoundary.addAnimalBoundary); XCTAssertEqual(draft.displayName, "Juniper"); XCTAssertTrue(result.contains("does not write to a database or disk"))
    }
    func testCareAndCostLabelsPreserveHealthAndFinanceBoundaries() {
        XCTAssertTrue(FixturePresentationBoundary.careOwnership.contains("Ranch Health remains human-only")); XCTAssertTrue(FixturePresentationBoundary.financeOwnership.contains("Ranch Finance remains the canonical ledger")); XCTAssertTrue(FixturePresentationBoundary.financeOwnership.contains("no posting or editing"))
    }
    func testFutureIdentityProviderIsExplicitlyUnavailableWithoutFallback() async {
        let provider = UnavailableVerifiedPrincipalProvider()
        do {
            _ = try await provider.verifiedPrincipal()
            XCTFail("A live principal must not be fabricated for the fixture app")
        } catch let error as FutureLiveIntegrationError {
            XCTAssertEqual(error.errorDescription, "Live tenant integration is not deployed. DEV fixture data remains local presentation only.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
