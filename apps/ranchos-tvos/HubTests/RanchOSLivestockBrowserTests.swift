import XCTest

final class RanchOSLivestockBrowserTests: XCTestCase {
    @MainActor
    func testSearchFiltersByDisplayName() {
        let model = RanchOSLivestockBrowserModel()

        model.searchText = "maple"

        XCTAssertEqual(model.visibleAnimals.map(\.id), ["sample-animal-cattle-angus-001"])
        XCTAssertEqual(model.visibleAnimals.first?.displayName, "Maple")
        if case .results(let animals) = model.listState {
            XCTAssertEqual(animals.map(\.displayName), ["Maple"])
        } else {
            XCTFail("Expected name search to produce results")
        }
    }

    @MainActor
    func testSearchFiltersByIdentifier() {
        let model = RanchOSLivestockBrowserModel()

        model.searchText = "SA-221"

        XCTAssertEqual(model.visibleAnimals.map(\.id), ["sample-animal-cattle-hereford-002"])
        XCTAssertEqual(model.visibleAnimals.first?.identifier?.value, "SA-221")
    }

    @MainActor
    func testCombinedSpeciesAndSearchFilters() {
        let model = RanchOSLivestockBrowserModel()
        model.searchText = "tag"
        model.speciesFilter = .species(.cattle)

        let ids = model.visibleAnimals.map(\.id)
        XCTAssertEqual(ids, [
            "sample-animal-cattle-angus-001",
            "sample-animal-cattle-hereford-002",
        ])
        XCTAssertTrue(model.visibleAnimals.allSatisfy { $0.species == .cattle })
        XCTAssertTrue(model.visibleAnimals.allSatisfy { $0.identifier != nil })
    }

    @MainActor
    func testEmptyCatalogUsesEmptyState() {
        let model = RanchOSLivestockBrowserModel(animals: [])

        XCTAssertEqual(model.listState, .emptyCatalog)
        XCTAssertTrue(model.visibleAnimals.isEmpty)
        XCTAssertNil(model.selectedAnimal)
    }

    @MainActor
    func testNoMatchStateKeepsCatalogButClearsVisibleAnimals() {
        let model = RanchOSLivestockBrowserModel()
        XCTAssertFalse(model.animals.isEmpty)

        model.searchText = "no-such-sample-animal"

        XCTAssertEqual(model.listState, .noMatches)
        XCTAssertTrue(model.visibleAnimals.isEmpty)
        XCTAssertFalse(model.animals.isEmpty)
    }

    @MainActor
    func testFilteringClearsSelectionThatIsNoLongerVisible() {
        let model = RanchOSLivestockBrowserModel()
        model.selectAnimal(id: "sample-animal-cattle-angus-001")
        XCTAssertEqual(model.selectedAnimal?.displayName, "Maple")

        model.speciesFilter = .species(.chicken)

        XCTAssertNil(model.selectedAnimalID)
        XCTAssertNil(model.selectedAnimal)
        XCTAssertEqual(model.visibleAnimals.map(\.id), ["sample-animal-chicken-rir-007"])
    }

    @MainActor
    func testReplacingSampleDataClearsInvalidSelection() {
        let model = RanchOSLivestockBrowserModel()
        model.selectAnimal(id: "sample-animal-goat-boer-005")
        XCTAssertEqual(model.selectedAnimal?.displayName, "Willow")

        let replacement = RanchOSLivestockSampleCatalog.developmentSamples.filter { $0.species == .horse }
        model.replaceSampleData(replacement)

        XCTAssertNil(model.selectedAnimalID)
        XCTAssertEqual(model.visibleAnimals.map(\.id), ["sample-animal-horse-qh-009"])
        XCTAssertEqual(model.listState, .results(replacement))
    }

    @MainActor
    func testOptionalIdentifiersArePresentOrExplicitlyAbsent() {
        let samples = RanchOSLivestockSampleCatalog.developmentSamples
        let identified = samples.filter { $0.identifier != nil }
        let unidentified = samples.filter { $0.identifier == nil }

        XCTAssertFalse(identified.isEmpty)
        XCTAssertFalse(unidentified.isEmpty)
        XCTAssertTrue(identified.allSatisfy { $0.identifier?.value.isEmpty == false })
        XCTAssertEqual(
            unidentified.map(\.id),
            [
                "sample-animal-cattle-breeding-003",
                "sample-animal-goat-boer-005",
                "sample-animal-pig-yorkshire-008",
                "sample-animal-pet-010",
            ])
    }

    func testDevelopmentSamplesUseValidReadContractCombinations() {
        let samples = RanchOSLivestockSampleCatalog.developmentSamples
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(Set(samples.map(\.id)).count, samples.count)

        for animal in samples {
            XCTAssertTrue(
                RanchOSLivestockSampleCatalog.accepts(animal),
                "Invalid catalog combination for \(animal.id)")
            XCTAssertTrue(RanchOSLivestockSpecies.allCases.contains(animal.species))
            XCTAssertTrue(
                RanchOSLivestockSampleCatalog.productionTypesBySpecies[animal.species]?
                    .contains(animal.productionType) == true)
            if let breed = animal.breed {
                XCTAssertEqual(breed.species, animal.species)
                XCTAssertEqual(RanchOSLivestockSampleCatalog.breedSpecies[breed.code], animal.species)
            }
            XCTAssertTrue(animal.provenance.isSynthetic)
            XCTAssertEqual(animal.provenance.sourceType, "synthetic_dev_fixture")
            XCTAssertEqual(animal.provenance.sourceID, animal.id)
        }

        XCTAssertTrue(samples.contains { $0.lifecycleStatus == .active && $0.factFreshness != .current })
        XCTAssertTrue(samples.contains { $0.lifecycleStatus == .archived && $0.factFreshness == .current })
        XCTAssertFalse(samples.contains { $0.species.rawValue == "rabbit" })
        XCTAssertFalse(samples.contains { $0.species.rawValue == "other" })
    }

    func testBrowsingIsEligibleOnlyInFixtureStateIncludingRetryable() {
        let liveDashboard = RanchOSLivestockDashboard(
            ranchName: "Authorized read",
            herdCount: 1,
            summaries: [
                RanchOSLivestockSummary(
                    id: "authorized",
                    title: "Authorized herd",
                    detail: "Read only",
                    status: .current),
            ])

        XCTAssertTrue(
            RanchOSLivestockBrowserModel.isBrowsingEligible(.fixture(.developmentFixture)))
        XCTAssertFalse(RanchOSLivestockBrowserModel.isBrowsingEligible(.loading))
        XCTAssertFalse(RanchOSLivestockBrowserModel.isBrowsingEligible(.available(liveDashboard)))
        XCTAssertFalse(
            RanchOSLivestockBrowserModel.isBrowsingEligible(
                .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage)))
        XCTAssertFalse(RanchOSLivestockBrowserModel.isBrowsingEligible(.retryable))
    }
}
