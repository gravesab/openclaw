import XCTest
@testable import RanchOSLivestock

final class LivestockFoundationTests: XCTestCase {
    // Active and retired come from the DEV database retirement record.
    func testCatalogSelectionIsControlledAndSpeciesChangeClearsIncompatibleValues() {
        var draft = AddAnimalDraft()
        draft.selectSpecies(.cattle)
        draft.selectProductionType(.dairy)
        draft.selectBreed(LivestockCatalog.breeds.first { $0.code == "angus" })
        XCTAssertTrue(draft.isValidCatalogSelection)
        draft.selectSpecies(.chicken)
        XCTAssertNil(draft.productionType)
        XCTAssertNil(draft.breed)
        XCTAssertFalse(draft.isValidCatalogSelection)
        XCTAssertTrue(Species.allCases.contains(.pet))
        XCTAssertTrue(LivestockCatalog.dogBreeds.contains("Labrador Retriever"))
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.code == "charolais" && $0.species == .cattle })
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.code == "holstein" && $0.species == .cattle })
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.label == "Thoroughbred" && $0.species == .horse })
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.code == "nubian" && $0.species == .goat })
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.label == "Marans" && $0.species == .chicken })
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.label == "Jersey Giant" && $0.species == .chicken })
        XCTAssertTrue(LivestockCatalog.breeds.contains { $0.label == "Delaware" && $0.species == .chicken })
        XCTAssertEqual(LivestockCatalog.breeds(for: .chicken).count, 52)
        XCTAssertFalse(Species.allCases.contains { $0.rawValue == "rabbit" })
        XCTAssertFalse(Species.allCases.contains { $0.rawValue == "other" })
        XCTAssertTrue(LivestockCatalog.accepts(species: .pet, production: .companion, breed: nil))
        XCTAssertEqual(
            Species.pickerChoices.map(\.label),
            ["Beef cattle", "Dairy cow", "Bison", "Chickens", "Goats", "Horses", "Pigs", "Sheep"]
        )
        XCTAssertEqual(
            LivestockCatalog.productionTypes(for: .cattle).map(\.label),
            ["Breeding", "Dairy", "For sale", "Personal meat production"]
        )
        XCTAssertEqual(
            LivestockCatalog.productionTypes(for: .dairyCow).map(\.label),
            LivestockCatalog.productionTypes(for: .cattle).map(\.label)
        )
        XCTAssertTrue(LivestockCatalog.productionTypes(for: .goat).contains(.dairy))
        XCTAssertEqual(
            LivestockCatalog.breeds(for: .dairyCow).map(\.label),
            [
                "Ayrshire", "Brown Swiss", "Canadienne", "Danish Red", "Dutch Belted", "Guernsey",
                "Holstein", "Illawarra", "Jersey", "Kerry", "Milking Shorthorn", "Montbéliarde",
                "Normande", "Norwegian Red", "Randall", "Swedish Red",
            ]
        )
        XCTAssertFalse(LivestockCatalog.breeds(for: .dairyCow).contains { $0.code == "angus" })
        XCTAssertTrue(LivestockCatalog.breeds(for: .cattle).contains { $0.code == "angus" })
        XCTAssertFalse(LivestockCatalog.productionTypes(for: .cattle).contains(.beef))
        XCTAssertTrue(LivestockCatalog.productionChoices(for: .cattle, including: .beef).contains(.beef))
        XCTAssertFalse(LivestockCatalog.productionChoices(for: .cattle, including: .dairy).contains(.beef))
        XCTAssertFalse(LivestockCatalog.productionTypes(for: .bison).contains(.beef))
        XCTAssertFalse(LivestockCatalog.productionTypes(for: .goat).contains(.beef))
        XCTAssertTrue(LivestockCatalog.accepts(species: .cattle, production: .beef, breed: nil))
        XCTAssertEqual(
            LivestockCatalog.productionTypes(for: .horse).map(\.label),
            ["Breeding", "Companion", "For sale", "Personal meat production"]
        )
        XCTAssertFalse(LivestockCatalog.productionTypes(for: .pet).contains(.forSale))
    }

    func testPetBreedCanBeListedTypedOrMixed() {
        var listed = AddAnimalDraft(category: .pets, displayName: "Moss")
        listed.selectPetKind(.dog)
        listed.petBreedChoice = "Labrador Retriever"
        XCTAssertEqual(listed.recordedPetBreed, "Labrador Retriever")
        XCTAssertNil(listed.petFormProblem)
        XCTAssertTrue(LivestockCatalog.petBreeds(for: .cat).contains("Siamese"))
        XCTAssertTrue(LivestockCatalog.petBreeds(for: .bird).contains("Cockatiel"))
        XCTAssertTrue(LivestockCatalog.petBreeds(for: .reptile).contains("Bearded Dragon"))

        var typed = AddAnimalDraft(category: .pets, displayName: "Moss")
        typed.selectPetKind(.cat)
        typed.petBreedChoice = "typed"
        XCTAssertEqual(typed.petBreedProblem, "Type a breed, or choose one from the list.")
        typed.typedBreed = "Ranch Collie"
        XCTAssertEqual(typed.recordedPetBreed, "Ranch Collie")

        var mixed = AddAnimalDraft(category: .pets, displayName: "Moss")
        mixed.selectPetKind(.dog)
        mixed.petBreedChoice = "mixed"
        mixed.mixBreedOne = "Labrador Retriever"
        XCTAssertEqual(mixed.petBreedProblem, "Enter both breeds in the mix.")
        mixed.mixBreedTwo = "Poodle"
        XCTAssertNil(mixed.petBreedProblem)
        var other = AddAnimalDraft(category: .pets, displayName: "Moss")
        other.selectPetKind(.other)
        XCTAssertEqual(other.petFormProblem, "Enter the species.")
        other.petSpeciesOther = "Ferret"
        other.typedBreed = "Silver"
        XCTAssertNil(other.petFormProblem)
        XCTAssertEqual(other.recordedPetBreed, "Silver")

        let animal = Animal(
            id: UUID(),
            displayName: "Moss",
            species: .pet,
            productionType: .companion,
            breed: nil,
            identifiers: [],
            recordedBreed: "mixed",
            mixBreedOne: "Labrador Retriever",
            mixBreedTwo: "Poodle",
            petKind: .dog,
            status: "Active"
        )
        XCTAssertEqual(animal.breedDisplay, "Labrador Retriever × Poodle")
        XCTAssertEqual(animal.speciesDisplay, "Dog")
    }

    func testDurableCatalogRejectsSpeciesOutsideTheCatalog() {
        XCTAssertEqual(
            LivestockCatalog.durableSpeciesCodes,
            ["bison", "cattle", "chicken", "dairy_cow", "goat", "horse", "pet", "pig", "sheep"]
        )
        XCTAssertTrue(LivestockCatalog.acceptsSpeciesCode("cattle"))
        XCTAssertFalse(LivestockCatalog.acceptsSpeciesCode("rabbit"))
        XCTAssertFalse(LivestockCatalog.acceptsSpeciesCode("other"))
        XCTAssertFalse(LivestockCatalog.acceptsSpeciesCode(""))
        XCTAssertTrue(FixturePresentationBoundary.rejectedSpeciesBoundary.contains("not accepted by the durable catalog"))
    }

    func testFixturePresentationContextAndBoundaryAreVisible() {
        XCTAssertEqual(FixturePresentationContext.preview.environment, "DEV fixture")
        XCTAssertEqual(FixturePresentationContext.preview.statusLabel, "No authenticated tenant session")
        XCTAssertTrue(FixturePresentationBoundary.tenantDisclosure.contains("live tenant data is not connected"))
        XCTAssertTrue(FixturePresentationBoundary.deferredSliceDisclosure.contains("Finance posting"))
        XCTAssertTrue(FixturePresentationBoundary.careRecordBoundary.contains("Ranch Health remains human-only"))
        XCTAssertTrue(FixturePresentationBoundary.costRecordBoundary.contains("does not post"))
    }

    func testBuildStampShowsDevVersionAndBuild() {
        let stamp = LivestockBuildStamp(name: "Livestock Management", environment: "DEV", version: "0.1.0", build: "1")
        XCTAssertEqual(stamp.name, "Livestock Management")
        XCTAssertEqual(stamp.headerDetail, "Version 0.1.0 · Build 1")
        XCTAssertEqual(LivestockBuildStamp.current.name, "Livestock Management")
        XCTAssertEqual(LivestockBuildStamp.current.environment, "DEV")
        XCTAssertFalse(LivestockBuildStamp.current.version.isEmpty)
        XCTAssertFalse(LivestockBuildStamp.current.build.isEmpty)
    }

    @MainActor
    func testUnavailableReadCanOpenFixtureSessionAndSelectFirstAnimal() async {
        let store = LivestockStore()
        XCTAssertTrue(store.session.canOpenFixtureSession)
        XCTAssertNil(store.selectedAnimalID)
        await store.loadFixtures()
        XCTAssertFalse(store.session.canOpenFixtureSession)
        XCTAssertEqual(store.selectedAnimalID, store.animals.first?.id)
        XCTAssertEqual(store.animals.first?.displayName, "Juniper")
        store.selectedAnimalID = store.animals.last?.id
        XCTAssertEqual(store.animals.first { $0.id == store.selectedAnimalID }?.displayName, "Cedar")
    }

    func testNavigationKeepsFirstSliceScreensOnly() {
        XCTAssertEqual(
            LivestockDestination.allCases.map(\.label),
            ["Herd overview", "Create herd", "Herds that have been retired", "Current livestock", "Live stock that have been retired", "Current pets", "Pets that have been retired"]
        )
        XCTAssertTrue(AnimalCategory.liveStock.includes(.cattle))
        XCTAssertFalse(AnimalCategory.liveStock.includes(.pet))
        XCTAssertTrue(AnimalCategory.pets.includes(.pet))
        XCTAssertFalse(AnimalCategory.pets.includes(.goat))
        let labels = LivestockDestination.allCases.map(\.label)
        XCTAssertFalse(labels.contains("Care"))
        XCTAssertFalse(labels.contains("Feed and supplies"))
        XCTAssertFalse(labels.contains("Costs"))
        XCTAssertEqual(FixtureLoadState.empty(message: "Nothing here").message, "Nothing here")
        XCTAssertEqual(FixtureLoadState.error(message: "Read failed").message, "Read failed")
        XCTAssertEqual(FixtureLoadState.loading.message, "Loading fixture presentation…")
    }

    func testAppearanceChoicesIncludeSystemLightAndDark() {
        XCTAssertEqual(AppearanceChoice.allCases.map(\.label), ["System", "Light", "Dark"])
        XCTAssertNil(AppearanceChoice.system.colorScheme)
        XCTAssertEqual(AppearanceChoice.light.colorScheme, .light)
        XCTAssertEqual(AppearanceChoice.dark.colorScheme, .dark)
    }

    func testAddAnimalFlowIsInMemoryFixturePresentationOnly() {
        let draft = AddAnimalDraft(displayName: "Juniper", species: .cattle, productionType: .beef, breed: nil)
        let result = draft.submitFixturePresentation()
        XCTAssertEqual(result, FixturePresentationBoundary.addAnimalBoundary)
        XCTAssertEqual(draft.displayName, "Juniper")
        XCTAssertTrue(result.contains("does not write to a database or disk"))
    }

    func testCareAndCostLabelsPreserveHealthAndFinanceBoundaries() {
        XCTAssertTrue(FixturePresentationBoundary.careOwnership.contains("Ranch Health remains human-only"))
        XCTAssertTrue(FixturePresentationBoundary.financeOwnership.contains("Ranch Finance remains the canonical ledger"))
        XCTAssertTrue(FixturePresentationBoundary.financeOwnership.contains("no posting or editing"))
    }

    func testFixtureOverviewCountsSampleAnimalsAndOmitsDeferredFacts() async throws {
        let model = FixtureLivestockReadModel()
        let animals = try await model.animals(context: .preview)
        let overview = try await model.herdOverview(context: .preview)
        XCTAssertEqual(animals.map(\.displayName), ["Juniper", "Cedar"])
        XCTAssertEqual(overview.animalCount, animals.count)
        XCTAssertEqual(overview.animalCount, 2)
        XCTAssertEqual(overview.currentLivestock, 2)
        XCTAssertEqual(overview.retiredLivestock, 0)
        XCTAssertEqual(overview.currentPets, 0)
        XCTAssertEqual(overview.retiredPets, 0)
        XCTAssertEqual(overview.totalCost, 0)
        for animal in animals {
            XCTAssertFalse(animal.displayName.isEmpty)
            XCTAssertFalse(animal.identifiers.filter(\.isActive).isEmpty)
            XCTAssertEqual(animal.identifierSummary, "Ear tag \(animal.identifiers[0].value)")
            XCTAssertTrue(LivestockCatalog.acceptsSpeciesCode(animal.species.rawValue))
            XCTAssertTrue(LivestockCatalog.accepts(species: animal.species, production: animal.productionType, breed: animal.breed))
        }
    }

    @MainActor
    func testFixtureStoreKeepsOverviewCountAlignedWithLoadedAnimals() async {
        let store = LivestockStore()
        await store.loadFixtures()
        XCTAssertEqual(store.selectedAnimalID, store.animals.first?.id)
        XCTAssertEqual(store.animals.map(\.displayName), ["Juniper", "Cedar"])
        XCTAssertEqual(store.overview?.animalCount, store.animals.count)
        XCTAssertEqual(store.overview?.currentLivestock, 2)
        XCTAssertFalse(store.session.isLive)
        XCTAssertEqual(store.overviewState, .loaded)
        XCTAssertEqual(store.animalsState, .loaded)
    }

    func testReadConnectionAllowsGetAndHasNoWriteVerbs() {
        XCTAssertEqual(LivestockReadRequestMethod.allCases.map(\.rawValue), ["GET"])
        XCTAssertFalse(LivestockReadRequestMethod.allCases.contains { $0.isWrite })
        XCTAssertEqual(LivestockReadConnection.writeRequestMethods, [])
        for verb in LivestockReadConnection.prohibitedRequestMethods {
            XCTAssertFalse(LivestockReadRequestMethod.allCases.map(\.rawValue).contains(verb))
        }
    }

    @MainActor
    func testMissingAuthorizedReadStaysUnavailable() async {
        let session = await LivestockReadConnection().resolve()
        XCTAssertEqual(session, .unavailable(LivestockReadConnection.unavailableMessage))
        XCTAssertFalse(session.isLive)
        let store = LivestockStore()
        await store.loadAuthorizedRead()
        XCTAssertFalse(store.session.isLive)
        XCTAssertTrue(store.animals.isEmpty)
        XCTAssertNil(store.overview)
        XCTAssertEqual(store.animalsState, .error(message: LivestockReadConnection.unavailableMessage))
    }

    @MainActor
    func testAuthorizedLiveReadPresentsAnimalsWithoutWriteAccess() async {
        let animal = Animal(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: LivestockCatalog.breeds.first { $0.code == "dorper" },
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "SH-44")],
            status: "Active"
        )
        let connection = LivestockReadConnection(authorizedProvider: StaticAuthorizedRead(page: LivestockAuthorizedAnimalPage(origin: .live, animals: [animal])))
        let session = await connection.resolve()
        XCTAssertEqual(session, .readOnly([animal]))
        XCTAssertTrue(session.isLive)
        XCTAssertEqual(session.banner, LivestockReadConnection.liveReadOnlyLabel)
        XCTAssertEqual(session.statusTitle, "Live DEV read")
        XCTAssertTrue(session.statusDetail.contains("DEV database"))
        let store = LivestockStore(connection: connection)
        await store.loadAuthorizedRead()
        XCTAssertEqual(store.animals.map(\.displayName), ["Maple"])
        XCTAssertEqual(store.overview?.animalCount, 1)
        XCTAssertTrue(store.session.isLive)
    }

    func testFixturePageCannotBePresentedAsLiveRead() async {
        let page = LivestockAuthorizedAnimalPage(origin: .fixture, animals: FixtureLivestockReadModel.fixtureAnimals)
        let session = await LivestockReadConnection(authorizedProvider: StaticAuthorizedRead(page: page)).resolve()
        XCTAssertEqual(session, .unavailable(LivestockReadConnection.fixtureAsLiveMessage))
        XCTAssertFalse(session.isLive)
        let relabeled = LivestockAuthorizedAnimalPage(origin: .live, animals: FixtureLivestockReadModel.fixtureAnimals)
        let relabeledSession = await LivestockReadConnection(authorizedProvider: StaticAuthorizedRead(page: relabeled)).resolve()
        XCTAssertEqual(relabeledSession, .unavailable(LivestockReadConnection.fixtureAsLiveMessage))
    }

    @MainActor
    func testFixtureOwnerCreatesAnimalInSessionOnly() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let draft = AddAnimalDraft(displayName: "  Maple  ", species: .sheep, productionType: .breeding, breed: nil)
        guard case .created(let animal) = store.createFixtureAnimal(draft) else {
            return XCTFail("Owner create should append a fixture animal")
        }
        XCTAssertEqual(animal.displayName, "Maple")
        XCTAssertEqual(animal.identifierSummary, "No identifier")
        XCTAssertEqual(store.animals.map(\.displayName), ["Juniper", "Cedar", "Maple"])
        XCTAssertEqual(store.overview?.animalCount, 3)
        XCTAssertEqual(store.selectedAnimalID, animal.id)
        XCTAssertFalse(store.session.isLive)
        XCTAssertTrue(FixturePresentationBoundary.addAnimalBoundary.contains("does not write to a database or disk"))
    }

    @MainActor
    func testFixtureManagerCanCreateAndViewerCannot() async {
        let manager = LivestockStore(fixtureWriteRole: .manager)
        await manager.loadFixtures()
        let draft = AddAnimalDraft(displayName: "Clover", species: .goat, productionType: .dairy, breed: nil)
        guard case .created = manager.createFixtureAnimal(draft) else {
            return XCTFail("Manager create should append a fixture animal")
        }
        XCTAssertEqual(manager.animals.count, 3)
        guard case .assigned = manager.assignFixtureIdentifier(animalID: manager.animals[0].id, kind: .rfid, value: "840-9") else {
            return XCTFail("Manager should assign an identifier in the fixture session")
        }
        XCTAssertEqual(manager.animals[0].identifiers.last?.value, "840-9")

        let viewer = LivestockStore(fixtureWriteRole: .viewer)
        await viewer.loadFixtures()
        XCTAssertEqual(
            viewer.createFixtureAnimal(draft),
            .rejected(FixturePresentationBoundary.viewerCannotCreateBoundary)
        )
        XCTAssertEqual(viewer.animals.map(\.displayName), ["Juniper", "Cedar"])
    }

    @MainActor
    func testCreateAnimalRejectsBlankNameAndLiveSession() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let blank = AddAnimalDraft(displayName: "   ", species: .cattle, productionType: .beef, breed: nil)
        XCTAssertEqual(store.createFixtureAnimal(blank), .rejected(FixturePresentationBoundary.createNeedsNameBoundary))
        XCTAssertEqual(store.animals.count, 2)

        let animal = Animal(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: nil,
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "SH-44")],
            status: "Active"
        )
        let live = LivestockStore(
            connection: LivestockReadConnection(
                authorizedProvider: StaticAuthorizedRead(page: LivestockAuthorizedAnimalPage(origin: .live, animals: [animal]))
            )
        )
        await live.loadAuthorizedRead()
        let draft = AddAnimalDraft(displayName: "Birch", species: .cattle, productionType: .beef, breed: nil)
        XCTAssertEqual(live.createFixtureAnimal(draft), .rejected(FixturePresentationBoundary.createUnavailableBoundary))
        XCTAssertEqual(live.animals.map(\.displayName), ["Maple"])
    }

    @MainActor
    func testFixtureOwnerAssignsAndRetiresIdentifierInSessionOnly() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let juniper = store.animals[0]
        XCTAssertEqual(
            store.assignFixtureIdentifier(animalID: juniper.id, kind: .earTag, value: "  rb-104  "),
            .rejected(FixturePresentationBoundary.identifierActiveCollisionBoundary)
        )
        guard case .assigned(let brand) = store.assignFixtureIdentifier(animalID: juniper.id, kind: .brand, value: "  NR-7  ") else {
            return XCTFail("Owner should assign a brand in the fixture session")
        }
        XCTAssertEqual(brand.value, "NR-7")
        XCTAssertEqual(store.animals[0].identifierSummary, "Ear tag RB-104, Brand NR-7")
        XCTAssertFalse(store.session.isLive)
        XCTAssertTrue(FixturePresentationBoundary.identifierBoundary.contains("not written to a database or disk"))

        guard case .retired(let retired) = store.retireFixtureIdentifier(animalID: juniper.id, identifierID: juniper.identifiers[0].id, reason: .lost) else {
            return XCTFail("Owner should retire an active ear tag")
        }
        XCTAssertEqual(retired.retirementReason, .lost)
        XCTAssertEqual(
            store.retireFixtureIdentifier(animalID: juniper.id, identifierID: retired.id, reason: .lost),
            .rejected(FixturePresentationBoundary.identifierAlreadyRetiredBoundary)
        )
        guard case .assigned(let reused) = store.assignFixtureIdentifier(animalID: juniper.id, kind: .earTag, value: "RB-104") else {
            return XCTFail("A retired ear tag value can be assigned again")
        }
        XCTAssertEqual(reused.value, "RB-104")
        XCTAssertTrue(store.animals[0].identifiers.contains { $0.id == retired.id && !$0.isActive })
        XCTAssertEqual(store.animals[0].identifierSummary, "Brand NR-7, Ear tag RB-104")
    }

    @MainActor
    func testSaveWritesFilledFixtureFieldsAndSkipsBlankOnes() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let animal = store.animals[0]
        let before = animal.lifecycleEvents.count
        var draft = LivestockAnimalSaveDraft()
        draft.identifierKind = .brand
        draft.identifierValue = " NR-9 "
        draft.identifierCost = "0"
        draft.lifecycleType = .weightRecorded
        draft.lifecycleAt = Date().addingTimeInterval(3600)
        let saved = await store.saveAnimalRecords(animalID: animal.id, draft: draft)
        XCTAssertTrue(saved.savedIdentifier)
        XCTAssertTrue(saved.savedLifecycle)
        XCTAssertFalse(saved.savedCare)
        XCTAssertEqual(saved.message, "Saved in this sample session.")
        XCTAssertEqual(store.saveNotice?.animalID, animal.id)
        XCTAssertEqual(store.saveNotice?.succeeded, true)
        XCTAssertEqual(store.animals[0].lifecycleEvents.count, before + 1)
        XCTAssertTrue(store.animals[0].identifiers.contains { $0.kind == .brand && $0.value == "NR-9" })

        let empty = await store.saveAnimalRecords(animalID: animal.id, draft: LivestockAnimalSaveDraft())
        XCTAssertEqual(empty.message, FixturePresentationBoundary.saveNeedsEntryBoundary)
        XCTAssertTrue(FixturePresentationBoundary.saveConfirmsBoundary.contains("Saving confirms"))
    }

    func testActivityCostsAddIntoANonNegativeTotal() {
        var draft = LivestockAnimalSaveDraft()
        draft.identifierValue = "A-1"
        XCTAssertEqual(draft.costProblem(), "Identifier cost is required. Zero is allowed.")
        draft.identifierCost = "0"
        draft.careType = .observation
        draft.careCost = "4.50"
        draft.feedLines = [
            LivestockFeedEntry(inputType: .hay, quantity: "2", cost: "-1"),
        ]
        XCTAssertNil(draft.costProblem())
        XCTAssertEqual(draft.enteredTotal(), Decimal(string: "3.50", locale: Locale(identifier: "en_US_POSIX")))
        draft.feedLines[0].cost = "1.25"
        draft.costAmount = "10"
        XCTAssertNil(draft.costProblem())
        XCTAssertEqual(draft.enteredTotal(), Decimal(string: "15.75", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(
            LivestockMoney.total(recorded: 20, entered: draft.enteredTotal()),
            Decimal(string: "35.75", locale: Locale(identifier: "en_US_POSIX"))
        )
        XCTAssertEqual(LivestockMoney.total(recorded: -5, entered: 0), 0)
        XCTAssertEqual(LivestockMoney.positiveText("0"), nil)
        XCTAssertEqual(LivestockMoney.positiveText("8"), "8")
        var typedCosts = LivestockAnimalSaveDraft()
        typedCosts.identifierCost = "1"
        typedCosts.careCost = "1"
        typedCosts.feedLines = [
            LivestockFeedEntry(inputType: .feed, quantity: "1", frequency: .daily, cost: "2"),
            LivestockFeedEntry(inputType: .hay, quantity: "1", unit: .bag, frequency: .monthly, cost: "40"),
            LivestockFeedEntry(inputType: .supplement, quantity: "1", unit: .scoop, frequency: .weekly, cost: "5"),
        ]
        let summary = typedCosts.costSummary(recorded: [])
        XCTAssertEqual(summary.feedSubtotals.map(\.label), ["Feed · Daily", "Hay · Monthly", "Supplement · Weekly"])
        XCTAssertEqual(summary.feedTotal, 47)
        XCTAssertEqual(summary.other, 2)
        XCTAssertEqual(summary.total, 49)
        XCTAssertEqual(LivestockMoney.usd(summary.total), "$49.00")
        var correction = LivestockAnimalSaveDraft()
        correction.identifierCost = "3"
        correction.costAmount = "-8"
        XCTAssertNil(correction.costProblem())
        let corrected = correction.costSummary(recorded: [])
        XCTAssertEqual(corrected.other, -5)
        XCTAssertEqual(corrected.total, 0)
        XCTAssertEqual(LivestockMoney.usd(corrected.total), "$0.00")
        XCTAssertTrue(LivestockMoney.usdSigned(-5).contains("5.00"))
        correction.costAmount = "0"
        XCTAssertEqual(correction.costProblem(), "Cost must be a number other than zero.")
        XCTAssertEqual(LivestockIdentifierKind.choices(for: .pet).map(\.label), ["License", "Other"])
        XCTAssertEqual(
            LivestockIdentifierRetirementReason.choices(for: .pet).map(\.rawValue),
            ["rehomed", "deceased", "lost"]
        )
        XCTAssertEqual(
            LivestockIdentifierRetirementReason.choices(for: .pet).map(\.label),
            ["Rehomed", "Deceased", "Lost"]
        )
        XCTAssertEqual(
            LivestockIdentifierRetirementReason.choices(for: .cattle).map(\.label),
            ["Deceased", "Processed", "Sold"]
        )
        let living = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "AST-1")],
            status: "Active"
        )
        XCTAssertFalse(living.isRetired)
        XCTAssertEqual(living.retirementDisplay, "Currently active")
        let untagged = Animal(
            id: UUID(),
            displayName: "Test cow",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [],
            retirementReason: .processed,
            status: "Active"
        )
        XCTAssertTrue(untagged.isRetired)
        XCTAssertEqual(untagged.retirementDisplay, "Processed")
        XCTAssertFalse(LivestockDestination.liveStock.includesAnimal(untagged))
        XCTAssertTrue(LivestockDestination.liveStockInactive.includesAnimal(untagged))
        let rehomedPet = Animal(
            id: UUID(),
            displayName: "Moss",
            species: .pet,
            productionType: .companion,
            breed: nil,
            identifiers: [],
            retirementReason: .rehomed,
            status: "Active"
        )
        XCTAssertTrue(rehomedPet.isRetired)
        XCTAssertEqual(rehomedPet.retirementDisplay, "Rehomed")
        XCTAssertFalse(LivestockDestination.pets.includesAnimal(rehomedPet))
        XCTAssertTrue(LivestockDestination.petsInactive.includesAnimal(rehomedPet))
        let deceasedDog = Animal(
            id: UUID(),
            displayName: "Siri",
            species: .pet,
            productionType: .companion,
            breed: nil,
            identifiers: [],
            recordedBreed: "Labrador Retriever",
            petKind: .dog,
            retirementReason: .deceased,
            status: "Active"
        )
        XCTAssertTrue(deceasedDog.isRetired)
        XCTAssertEqual(deceasedDog.speciesDisplay, "Dog")
        XCTAssertTrue(LivestockDestination.petsInactive.includesAnimal(deceasedDog))
        XCTAssertFalse(LivestockDestination.pets.includesAnimal(deceasedDog))
        let retiredAgain = deceasedDog.retiring(reason: .lost, at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(retiredAgain.retirementReason, .lost)
        XCTAssertEqual(retiredAgain.petKind, .dog)
        let replaced = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "AST-1", retirementReason: .sold)],
            status: "Active"
        )
        XCTAssertTrue(replaced.isRetired)
        XCTAssertEqual(replaced.retirementDisplay, "Sold")
        XCTAssertTrue(LivestockDestination.liveStock.includesAnimal(living))
        XCTAssertFalse(LivestockDestination.liveStock.includesAnimal(replaced))
        XCTAssertTrue(LivestockDestination.liveStockInactive.includesAnimal(replaced))
        let retiredPet = Animal(
            id: UUID(),
            displayName: "Moss",
            species: .pet,
            productionType: .companion,
            breed: nil,
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .license, value: "D-1", retirementReason: .lost)],
            status: "Active"
        )
        XCTAssertEqual(retiredPet.retirementDisplay, "Lost")
        XCTAssertTrue(LivestockDestination.petsInactive.includesAnimal(retiredPet))
        XCTAssertFalse(LivestockDestination.pets.includesAnimal(retiredPet))
        XCTAssertEqual(LivestockInputType.entryChoices(for: .pet).map(\.label), ["Dry food", "Wet food", "Supplement"])
        XCTAssertEqual(LivestockInputType.entryChoices(for: .cattle).map(\.label), ["Feed", "Hay", "Supplement"])
        XCTAssertEqual(LivestockInputUnit.entryChoices.map(\.label), ["Pounds", "Kilograms", "Scoops", "Bag"])
    }

    @MainActor
    func testIdentifierWriteRejectsViewerBlankValueAndLiveSession() async {
        let viewer = LivestockStore(fixtureWriteRole: .viewer)
        await viewer.loadFixtures()
        let animalID = viewer.animals[0].id
        XCTAssertEqual(
            viewer.assignFixtureIdentifier(animalID: animalID, kind: .rfid, value: "840-1"),
            .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        )
        XCTAssertEqual(viewer.animals[0].identifiers.count, 1)

        let owner = LivestockStore()
        await owner.loadFixtures()
        XCTAssertEqual(
            owner.assignFixtureIdentifier(animalID: owner.animals[0].id, kind: .rfid, value: "   "),
            .rejected(FixturePresentationBoundary.identifierNeedsValueBoundary)
        )

        let liveAnimal = Animal(
            id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: nil,
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "SH-44")],
            status: "Active"
        )
        let live = LivestockStore(
            connection: LivestockReadConnection(
                authorizedProvider: StaticAuthorizedRead(page: LivestockAuthorizedAnimalPage(origin: .live, animals: [liveAnimal]))
            )
        )
        await live.loadAuthorizedRead()
        XCTAssertEqual(
            live.assignFixtureIdentifier(animalID: liveAnimal.id, kind: .rfid, value: "840-1"),
            .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        )
        XCTAssertEqual(
            live.retireFixtureIdentifier(animalID: liveAnimal.id, identifierID: liveAnimal.identifiers[0].id, reason: .replaced),
            .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        )
        XCTAssertEqual(live.animals[0].identifierSummary, "Ear tag SH-44")
        XCTAssertFalse(LivestockIdentifierKind.acceptsCode("band"))
        XCTAssertTrue(LivestockIdentifierKind.acceptsCode("registry_number"))
    }

    @MainActor
    func testFixtureLifecycleAppendsInTimeOrder() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let animalID = store.animals[0].id
        let intakeAt = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .recorded(let intake) = store.recordFixtureLifecycleEvent(animalID: animalID, type: .intake, occurredAt: intakeAt) else {
            return XCTFail("Owner should record an intake event")
        }
        XCTAssertEqual(intake.type, .intake)
        guard case .recorded = store.recordFixtureLifecycleEvent(
            animalID: animalID,
            type: .tagged,
            occurredAt: intakeAt.addingTimeInterval(60)
        ) else {
            return XCTFail("A later tagged event should append")
        }
        guard case .recorded = store.recordFixtureLifecycleEvent(
            animalID: animalID,
            type: .weightRecorded,
            occurredAt: intakeAt.addingTimeInterval(120)
        ) else {
            return XCTFail("A later weight recorded event should append")
        }
        XCTAssertEqual(store.animals[0].lifecycleEvents.map(\.type), [.intake, .tagged, .weightRecorded])
        XCTAssertEqual(
            store.recordFixtureLifecycleEvent(animalID: animalID, type: .intake, occurredAt: intakeAt),
            .rejected(FixturePresentationBoundary.lifecycleOrderBoundary)
        )
        XCTAssertEqual(store.animals[0].lifecycleEvents.count, 3)
        XCTAssertEqual(store.animals[1].lifecycleEvents.count, 0)
        XCTAssertFalse(store.session.isLive)
        XCTAssertTrue(FixturePresentationBoundary.lifecycleBoundary.contains("not written to a database or disk"))
        XCTAssertFalse(LivestockLifecycleEventType.acceptsCode("sale"))
        XCTAssertTrue(LivestockLifecycleEventType.acceptsCode("weight_recorded"))
    }

    @MainActor
    func testLifecycleRecordingRejectsViewerAndLiveSession() async {
        let manager = LivestockStore(fixtureWriteRole: .manager)
        await manager.loadFixtures()
        let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .recorded = manager.recordFixtureLifecycleEvent(animalID: manager.animals[0].id, type: .intake, occurredAt: occurredAt) else {
            return XCTFail("Manager should record a lifecycle event")
        }
        XCTAssertEqual(manager.animals[0].lifecycleEvents.count, 1)

        let viewer = LivestockStore(fixtureWriteRole: .viewer)
        await viewer.loadFixtures()
        XCTAssertEqual(
            viewer.recordFixtureLifecycleEvent(animalID: viewer.animals[0].id, type: .tagged, occurredAt: occurredAt),
            .rejected(FixturePresentationBoundary.viewerCannotRecordLifecycleBoundary)
        )
        XCTAssertTrue(viewer.animals[0].lifecycleEvents.isEmpty)

        let liveAnimal = Animal(
            id: UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: nil,
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "SH-44")],
            status: "Active"
        )
        let live = LivestockStore(
            connection: LivestockReadConnection(
                authorizedProvider: StaticAuthorizedRead(page: LivestockAuthorizedAnimalPage(origin: .live, animals: [liveAnimal]))
            )
        )
        await live.loadAuthorizedRead()
        XCTAssertEqual(
            live.recordFixtureLifecycleEvent(animalID: liveAnimal.id, type: .weightRecorded, occurredAt: occurredAt),
            .rejected(FixturePresentationBoundary.lifecycleUnavailableBoundary)
        )
        XCTAssertTrue(live.animals[0].lifecycleEvents.isEmpty)
    }

    func testDevTicketRejectsNonLoopbackAndDecodesLiveAnimals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ticket = directory.appendingPathComponent("dev-read.json")
        let expiry = ISO8601DateFormatter()
        expiry.formatOptions = [.withInternetDateTime]
        let expiresAt = expiry.string(from: Date().addingTimeInterval(3_600))
        let body = """
        {"baseURL":"http://example.com:9","token":"secret","tenantID":"tenant-a","expiresAt":"\(expiresAt)"}
        """
        try body.write(to: ticket, atomically: true, encoding: .utf8)
        XCTAssertNil(LivestockDevLoopbackRead.load(fileURL: ticket))

        let payload = """
        {"api_version":"v1","operation":"animal_list","origin":"live","body":{"herd_count":1,"animals":[{"animal_id":"11111111-2222-4333-8444-555555555551","display_name":"Aster","species_code":"cattle","production_type_code":"beef","breed_code":"angus","lifecycle_status":"active","identifier":{"kind":"ear_tag","value":"AST-1"},"provenance":{"origin":"live"}}]}}
        """.data(using: .utf8)!
        let page = try LivestockDevLoopbackRead.decode(payload)
        XCTAssertEqual(page.origin, .live)
        XCTAssertEqual(page.animals.map(\.displayName), ["Aster"])
        XCTAssertEqual(page.animals.first?.identifiers.first?.kind, .earTag)
        XCTAssertEqual(page.animals.first?.identifiers.first?.value, "AST-1")
        XCTAssertEqual(page.animals.first?.identifierSummary, "Ear tag AST-1")
        XCTAssertFalse(LivestockDevLoopbackRead.isLoopback(URL(string: "https://127.0.0.1/api")!))
        XCTAssertTrue(LivestockDevLoopbackRead.isLoopback(URL(string: "http://127.0.0.1:9/api/ranchos/livestock/v1/animals")!))
    }

    func testCostsGroupByDateNewestDayFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(86_400 * 2)
        let laterSameDay = newer.addingTimeInterval(3_600)
        let hay = LivestockCostAttribution(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555561")!,
            amount: "40",
            financeReference: nil,
            recordedAt: older,
            frequency: .monthly,
            feedType: .hay
        )
        let operational = LivestockCostAttribution(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555562")!,
            amount: "4.25",
            financeReference: "BILL-1",
            recordedAt: newer,
            frequency: nil,
            feedType: nil
        )
        let later = LivestockCostAttribution(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555563")!,
            amount: "1",
            financeReference: nil,
            recordedAt: laterSameDay,
            frequency: nil,
            feedType: nil
        )
        let days = LivestockCostLedger.days(from: [hay, operational, later], calendar: calendar)
        XCTAssertEqual(days.map(\.day), [calendar.startOfDay(for: laterSameDay), calendar.startOfDay(for: older)])
        XCTAssertEqual(days[0].lines.map(\.label), ["Operational", "Operational · Finance BILL-1"])
        XCTAssertEqual(days[0].total, Decimal(string: "5.25"))
        XCTAssertEqual(days[1].lines.map(\.label), ["Hay · Monthly"])
        XCTAssertEqual(days[1].total, 40)
        let negative = LivestockCostAttribution(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555564")!,
            amount: "-3",
            financeReference: nil,
            recordedAt: older,
            frequency: nil,
            feedType: nil
        )
        let negativeDays = LivestockCostLedger.days(from: [negative], calendar: calendar)
        XCTAssertEqual(negativeDays.first?.lines.first?.amount, -3)
        XCTAssertEqual(negativeDays.first?.total, 0)
        XCTAssertTrue(LivestockCostLedger.days(from: [], calendar: calendar).isEmpty)
    }

    func testHerdOverviewSplitsLivestockPetsAndFloorsCost() {
        let livestock = Animal(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555571")!,
            displayName: "Briar",
            species: .goat,
            productionType: .dairy,
            breed: nil,
            identifiers: [],
            costs: [
                LivestockCostAttribution(
                    id: UUID(uuidString: "11111111-2222-4333-8444-555555555581")!,
                    amount: "12",
                    financeReference: nil,
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                LivestockCostAttribution(
                    id: UUID(uuidString: "11111111-2222-4333-8444-555555555582")!,
                    amount: "-20",
                    financeReference: nil,
                    recordedAt: Date(timeIntervalSince1970: 1_700_086_400)
                ),
            ],
            status: "Active"
        )
        let retiredPet = Animal(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555572")!,
            displayName: "Siri",
            species: .pet,
            productionType: .companion,
            breed: nil,
            identifiers: [],
            petKind: .dog,
            retirementReason: .deceased,
            status: "Active"
        )
        let overview = HerdOverview.from(animals: [livestock, retiredPet])
        XCTAssertEqual(overview.animalCount, 2)
        XCTAssertEqual(overview.currentLivestock, 1)
        XCTAssertEqual(overview.retiredLivestock, 0)
        XCTAssertEqual(overview.currentPets, 0)
        XCTAssertEqual(overview.retiredPets, 1)
        XCTAssertEqual(overview.totalCost, 0)
        XCTAssertEqual(livestock.recordedCostTotal, 0)
    }

    @MainActor
    func testHerdAssignmentKeepsOneCurrentHerd() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let created = await store.createHerd(name: " North pasture ", notes: " Winter lot ")
        XCTAssertEqual(created, "Herd saved.")
        XCTAssertEqual(store.herds.map(\.name), ["North pasture"])
        XCTAssertEqual(store.herds[0].notes, "Winter lot")
        let duplicate = await store.createHerd(name: "north pasture")
        XCTAssertEqual(duplicate, "That herd name is already used.")
        let animal = store.animals[0]
        let assigned = await store.assignHerd(animalID: animal.id, herdID: store.herds[0].id)
        XCTAssertEqual(assigned, "Herd assigned.")
        XCTAssertEqual(store.animals[0].herdName, "North pasture")
        let repeatAssign = await store.assignHerd(animalID: animal.id, herdID: store.herds[0].id)
        XCTAssertEqual(repeatAssign, "This animal is already in that herd.")
        let southSaved = await store.createHerd(name: "South")
        XCTAssertEqual(southSaved, "Herd saved.")
        let south = store.herds.first { $0.name == "South" }
        let moved = await store.assignHerd(animalID: animal.id, herdID: south!.id)
        XCTAssertEqual(moved, "Herd assigned.")
        XCTAssertEqual(store.animals[0].herdName, "South")
        let groups = HerdGrouping.groups(animals: store.animals, herds: store.herds)
        XCTAssertEqual(groups.map(\.name), ["North pasture", "South", "No herd"])
        XCTAssertEqual(groups.first { $0.name == "South" }?.livestockNames, [animal.displayName])
        XCTAssertEqual(groups.first { $0.name == "North pasture" }?.livestockNames, [])
        XCTAssertEqual(groups.first { $0.name == "No herd" }?.livestockNames, ["Cedar"])
        let blocked = await store.retireHerd(herdID: south!.id)
        XCTAssertEqual(blocked, "Reassign or unassign every animal before retiring this herd.")
        let cleared = await store.clearHerd(animalID: animal.id)
        XCTAssertEqual(cleared, "Herd cleared.")
        XCTAssertNil(store.animals[0].herdID)
        let retired = await store.retireHerd(herdID: south!.id)
        XCTAssertEqual(retired, "Herd retired.")
        XCTAssertEqual(store.herds.filter { !$0.isRetired }.map(\.name), ["North pasture"])
        XCTAssertEqual(store.herds.filter(\.isRetired).map(\.name), ["South"])
        let goat = store.animals.first { $0.species == .goat }!
        let cattle = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [],
            herdID: south!.id,
            status: "Active"
        )
        XCTAssertEqual(
            HerdSpeciesWarning.otherSpecies(assigning: goat, to: south!.id, among: [cattle]),
            "Beef cattle"
        )
        XCTAssertNil(HerdSpeciesWarning.otherSpecies(assigning: cattle, to: south!.id, among: [cattle]))
    }

    @MainActor
    func testSoldRetirementKeepsTheSaleOnTheAnimal() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let animal = store.animals[0]
        let missing = await store.retireAnimal(animalID: animal.id, reason: .sold)
        if case .rejected(let message) = missing {
            XCTAssertEqual(message, "A sale needs a date.")
        } else {
            XCTFail("A sold retirement needs a sale")
        }
        let day = Date(timeIntervalSince1970: 1_759_536_000)
        let sold = await store.retireAnimal(animalID: animal.id, reason: .sold, saleAmount: "1200", saleOn: day)
        if case .retired = sold {
            let saved = store.animals.first { $0.id == animal.id }
            XCTAssertEqual(saved?.retirementReason, .sold)
            XCTAssertEqual(saved?.saleAmount, 1200)
            XCTAssertEqual(saved?.saleOn, day)
        } else {
            XCTFail("The sale should be saved with the animal")
        }
    }

    func testLiveHerdEnvelopeKeepsARetiredHerdOnTheRetiredList() throws {
        let json = """
        {"origin":"live","body":{"animals":[],"herds":[
          {"id":"86684d01-3666-43d6-8499-08f6b24d9943","name":"Teat Heard 1","notes":"test","retired_at":"2026-10-04T18:58:09Z"},
          {"id":"23c217e0-206a-49c4-80f2-dba42d16e808","name":"teat Heard 2","notes":"test 2","retired_at":null}
        ]}}
        """
        let page = try LivestockDevLoopbackRead.decode(Data(json.utf8))
        XCTAssertEqual(page.herds.map(\.name), ["Teat Heard 1", "teat Heard 2"])
        XCTAssertTrue(page.herds[0].isRetired)
        XCTAssertEqual(page.herds[0].notes, "test")
        XCTAssertFalse(page.herds[1].isRetired)
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

private struct StaticAuthorizedRead: LivestockAuthorizedReadProvider {
    let page: LivestockAuthorizedAnimalPage

    func readAnimals() async throws -> LivestockAuthorizedAnimalPage {
        page
    }
}
