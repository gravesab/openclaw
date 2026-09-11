import XCTest
@testable import RanchOSLivestock

final class LivestockFoundationTests: XCTestCase {
    func testCatalogSelectionIsControlledAndSpeciesChangeClearsIncompatibleValues() {
        var draft = AddAnimalDraft(); draft.selectSpecies(.cattle); draft.selectProductionType(.beef); draft.selectBreed(LivestockCatalog.breeds.first { $0.code == "angus" })
        XCTAssertTrue(draft.isValidCatalogSelection)
        draft.selectSpecies(.chicken)
        XCTAssertNil(draft.productionType); XCTAssertNil(draft.breed); XCTAssertFalse(draft.isValidCatalogSelection)
        XCTAssertTrue(Species.allCases.contains(.rabbit))
        XCTAssertTrue(Species.allCases.contains(.pet))
        XCTAssertTrue(Species.allCases.contains(.other))
        XCTAssertTrue(LivestockCatalog.accepts(species: .rabbit, production: .companion, breed: nil))
        XCTAssertTrue(LivestockCatalog.accepts(species: .pet, production: .companion, breed: nil))
        XCTAssertEqual(
            Species.pickerChoices.map(\.label),
            ["Beef cattle", "Bison", "Chickens", "Goats", "Horses", "Pets", "Pigs", "Rabbits", "Sheep", "Other"]
        )
        XCTAssertEqual(LivestockCatalog.productionTypes(for: .cattle).map(\.label), ["Beef", "Breeding", "Dairy"])

        draft.selectSpecies(.other)
        draft.selectProductionType(.companion)
        XCTAssertFalse(draft.isValidCatalogSelection)
        draft.otherSpeciesDescription = "Alpaca"
        XCTAssertTrue(draft.isValidCatalogSelection)
        draft.selectSpecies(.rabbit)
        XCTAssertEqual(draft.otherSpeciesDescription, "")
    }
    func testRabbitPickerChoiceIsFixtureOnlyAndNotADurableCatalogValue() {
        XCTAssertTrue(Species.rabbit.isFixtureOnlyPickerSpecies)
        XCTAssertTrue(Species.other.isFixtureOnlyPickerSpecies)
        XCTAssertFalse(Species.cattle.isFixtureOnlyPickerSpecies)
        XCTAssertTrue(LivestockCatalog.accepts(species: .rabbit, production: .companion, breed: nil))
        XCTAssertTrue(FixturePresentationBoundary.rabbitSpeciesBoundary.contains("fixture-only"))
        XCTAssertTrue(FixturePresentationBoundary.rabbitSpeciesBoundary.contains("not accepted by the durable catalog"))
        let rabbitDraft = AddAnimalDraft(displayName: "Clover", species: .rabbit, productionType: .companion, breed: nil)
        XCTAssertTrue(rabbitDraft.isValidCatalogSelection)
        XCTAssertEqual(rabbitDraft.submitFixturePresentation(), FixturePresentationBoundary.addAnimalBoundary)
    }
    func testFixturePresentationContextAndBoundaryAreVisible() {
        XCTAssertEqual(FixturePresentationContext.preview.environment, "DEV fixture"); XCTAssertEqual(FixturePresentationContext.preview.statusLabel, "No authenticated tenant session")
        XCTAssertTrue(FixturePresentationBoundary.tenantDisclosure.contains("live tenant data is not connected"))
    }
    func testNavigationAndEssentialFixtureStatesAreDefined() {
        XCTAssertEqual(LivestockDestination.allCases.map(\.label), ["Herd overview", "Animals", "Care", "Feed and supplies", "Costs"])
        XCTAssertEqual(FixtureLoadState.empty(message: "Nothing here").message, "Nothing here"); XCTAssertEqual(FixtureLoadState.error(message: "Read failed").message, "Read failed"); XCTAssertEqual(FixtureLoadState.loading.message, "Loading fixture presentation…")
    }
    func testAppearanceChoicesIncludeSystemLightAndDark() {
        XCTAssertEqual(AppearanceChoice.allCases.map(\.label), ["System", "Light", "Dark"])
        XCTAssertNil(AppearanceChoice.system.colorScheme)
        XCTAssertEqual(AppearanceChoice.light.colorScheme, .light)
        XCTAssertEqual(AppearanceChoice.dark.colorScheme, .dark)
    }
    func testAddAnimalFlowIsInMemoryFixturePresentationOnly() {
        let draft = AddAnimalDraft(displayName: "Juniper", species: .cattle, productionType: .beef, breed: nil); let result = draft.submitFixturePresentation()
        XCTAssertEqual(result, FixturePresentationBoundary.addAnimalBoundary); XCTAssertEqual(draft.displayName, "Juniper"); XCTAssertTrue(result.contains("does not write to a database or disk"))
    }
    func testCareAndCostLabelsPreserveHealthAndFinanceBoundaries() {
        XCTAssertTrue(FixturePresentationBoundary.careOwnership.contains("Ranch Health remains human-only")); XCTAssertTrue(FixturePresentationBoundary.financeOwnership.contains("Ranch Finance remains the canonical ledger")); XCTAssertTrue(FixturePresentationBoundary.financeOwnership.contains("no posting or editing"))
    }
    func testEveryFixtureAnimalHasCareFeedAndDisplayOnlyCostAttribution() async throws {
        let animals = try await FixtureLivestockReadModel().animals(context: .preview)
        XCTAssertFalse(animals.isEmpty)
        for animal in animals {
            XCTAssertFalse(animal.care.nextCheckLabel.isEmpty)
            XCTAssertFalse(animal.care.summary.isEmpty)
            XCTAssertFalse(animal.feed.rationLabel.isEmpty)
            XCTAssertFalse(animal.feed.dailyAmountLabel.isEmpty)
            XCTAssertFalse(animal.operationalCostAttribution.categoryLabel.isEmpty)
            XCTAssertFalse(animal.operationalCostAttribution.amountLabel.isEmpty)
        }
    }
    @MainActor
    func testFixtureAnimalPickerUsesEveryLoadedModelAnimal() async {
        let store = LivestockStore()
        await store.loadFixtures()
        XCTAssertEqual(store.selectedAnimalID, store.animals.first?.id)
        XCTAssertEqual(store.animals.map(\.displayName), ["Juniper", "Cedar"])
        XCTAssertTrue(store.animals.allSatisfy { !$0.care.summary.isEmpty && !$0.feed.rationLabel.isEmpty && !$0.operationalCostAttribution.amountLabel.isEmpty })
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
