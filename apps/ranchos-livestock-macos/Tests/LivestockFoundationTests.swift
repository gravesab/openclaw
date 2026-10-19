import PDFKit
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
        for kind in [PetKind.dog, .cat, .bird, .reptile, .other] {
            let menu = LivestockCatalog.petBreedMenu(for: kind)
            XCTAssertEqual(menu.prefix(2).map(\.value), ["mixed", "typed"])
            XCTAssertEqual(menu.prefix(2).map(\.label), ["Mixed", "Type a breed"])
        }
        let dogMenu = LivestockCatalog.petBreedMenu(for: .dog)
        XCTAssertEqual(dogMenu.dropFirst(2).first?.value, "Akita")
        XCTAssertTrue(dogMenu.contains { $0.value == "Labrador Retriever" })
        XCTAssertFalse(LivestockCatalog.petBreedMenu(for: .other).contains { $0.value == "Labrador Retriever" })

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
        mixed.selectPetKind(.cat)
        XCTAssertEqual(mixed.petBreedChoice, "mixed")
        mixed.mixBreedOne = "Siamese"
        mixed.mixBreedTwo = "Maine Coon"
        XCTAssertNil(mixed.petBreedProblem)
        XCTAssertEqual(mixed.recordedPetBreed, "mixed")
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
        let dev = LivestockBuildStamp.resolved(
            info: [
                "LivestockEnvironment": "DEV",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
            ],
            bundleIdentifier: "ai.openclaw.ranchos.livestock.dev"
        )
        XCTAssertEqual(dev.name, "Livestock DEV")
        XCTAssertEqual(dev.environment, "DEV")
        XCTAssertEqual(dev.headerDetail, "Version 0.1.0 · Build 1")

        let prod = LivestockBuildStamp.resolved(
            info: [
                "LivestockEnvironment": "PROD",
                "CFBundleShortVersionString": "1.2.0",
                "CFBundleVersion": "9",
            ],
            bundleIdentifier: "ai.openclaw.ranchos.livestock"
        )
        XCTAssertEqual(prod.name, "Livestock PROD")
        XCTAssertEqual(prod.environment, "PROD")
        XCTAssertEqual(prod.headerDetail, "Version 1.2.0 · Build 9")
        XCTAssertEqual(prod.databaseLabel, "livestock database")
        XCTAssertEqual(prod.serverLabel, "livestock server")
        XCTAssertTrue(prod.isProduction)

        XCTAssertEqual(LivestockBuildStamp.current.name, "Livestock DEV")
        XCTAssertEqual(LivestockBuildStamp.current.environment, "DEV")
        XCTAssertEqual(LivestockBuildStamp.current.databaseLabel, "DEV database")
        XCTAssertFalse(LivestockBuildStamp.current.isProduction)
        XCTAssertFalse(LivestockBuildStamp.current.version.isEmpty)
        XCTAssertFalse(LivestockBuildStamp.current.build.isEmpty)
    }

    @MainActor
    func testUnavailableReadCanOpenFixtureSessionAndSelectFirstAnimal() async {
        let store = LivestockStore()
        XCTAssertTrue(store.session.canOpenFixtureSession)
        XCTAssertTrue(store.session.canReconnect)
        XCTAssertNil(store.selectedAnimalID)
        await store.loadFixtures()
        XCTAssertFalse(store.session.canOpenFixtureSession)
        XCTAssertTrue(store.session.canReconnect)
        XCTAssertEqual(store.selectedAnimalID, store.animals.first?.id)
        XCTAssertEqual(store.animals.first?.displayName, "Juniper")
        store.selectedAnimalID = store.animals.last?.id
        XCTAssertEqual(store.animals.first { $0.id == store.selectedAnimalID }?.displayName, "Cedar")
    }

    func testDisconnectedSessionOffersReconnectAndDoesNotMentionSampleData() {
        let unavailable = LivestockReadSession.unavailable(LivestockReadConnection.unavailableMessage)
        XCTAssertTrue(unavailable.canReconnect)
        XCTAssertFalse(unavailable.statusDetail.localizedCaseInsensitiveContains("sample"))
        XCTAssertFalse(unavailable.statusDetail.contains("Juniper"))
        XCTAssertTrue(LivestockReadSession.cancelled.canReconnect)
        XCTAssertTrue(LivestockReadSession.fixture([]).canReconnect)
        XCTAssertFalse(LivestockReadSession.readOnly([]).canReconnect)
    }

    func testReconnectKeepsTheLiveReadErrorInsteadOfAGenericUnavailableBanner() async {
        let connection = LivestockReadConnection(authorizedProvider: MessageLivestockReadProvider())
        let session = await connection.resolve()
        XCTAssertEqual(session, .unavailable(LivestockDevLoopbackRead.serverNotRunningMessage))
        XCTAssertTrue(session.canReconnect)
        XCTAssertEqual(
            LivestockDevLoopbackRead.message(for: URLError(.cannotConnectToHost)),
            LivestockDevLoopbackRead.serverNotRunningMessage)
    }

    @MainActor
    func testFixtureRenameUpdatesLivestockPetsAndHerds() async {
        let store = LivestockStore()
        await store.loadFixtures()
        let animal = try! XCTUnwrap(store.animals.first { $0.species == .pet } ?? store.animals.first)
        let blank = await store.renameAnimal(animalID: animal.id, displayName: "   ")
        XCTAssertEqual(blank, "Display name is required.")
        XCTAssertEqual(store.animals.first { $0.id == animal.id }?.displayName, animal.displayName)
        let saved = await store.renameAnimal(animalID: animal.id, displayName: "  North Pasture  ")
        XCTAssertEqual(saved, "Name saved.")
        XCTAssertEqual(store.animals.first { $0.id == animal.id }?.displayName, "North Pasture")

        let eastSaved = await store.createHerd(name: "East Field")
        let westSaved = await store.createHerd(name: "West Field")
        XCTAssertEqual(eastSaved, "Herd saved.")
        XCTAssertEqual(westSaved, "Herd saved.")
        let east = try! XCTUnwrap(store.herds.first { $0.name == "East Field" })
        let duplicate = await store.renameHerd(herdID: east.id, name: "west field")
        XCTAssertEqual(duplicate, "That herd name is already used.")
        XCTAssertEqual(store.herds.first { $0.id == east.id }?.name, "East Field")
        let assigned = await store.assignHerd(animalID: animal.id, herdID: east.id)
        XCTAssertEqual(assigned, "Herd assigned.")
        let renamedHerd = await store.renameHerd(herdID: east.id, name: "  North Field  ")
        XCTAssertEqual(renamedHerd, "Name saved.")
        XCTAssertEqual(store.herds.first { $0.id == east.id }?.name, "North Field")
        XCTAssertEqual(store.animals.first { $0.id == animal.id }?.herdName, "North Field")

        let viewer = LivestockStore(fixtureWriteRole: .viewer)
        await viewer.loadFixtures()
        let blocked = try! XCTUnwrap(viewer.animals.first)
        let denied = await viewer.renameAnimal(animalID: blocked.id, displayName: "Hidden")
        XCTAssertNotEqual(denied, "Name saved.")
        XCTAssertEqual(viewer.animals.first { $0.id == blocked.id }?.displayName, blocked.displayName)
    }

    func testNavigationKeepsFirstSliceScreensOnly() {
        XCTAssertEqual(
            LivestockDestination.allCases.map(\.label),
            ["Herds/groups overview", "Herd/group", "Create herd/group", "Herds/groups retired to a better life", "Current livestock/group", "Livestock/group retired to a better life", "Current pets", "Pets retired to a better life"]
        )
        XCTAssertTrue(AnimalCategory.liveStock.includes(.cattle))
        XCTAssertFalse(AnimalCategory.liveStock.includes(.pet))
        XCTAssertTrue(AnimalCategory.pets.includes(.pet))
        XCTAssertFalse(AnimalCategory.pets.includes(.goat))
        let fixtures = FixtureLivestockReadModel.fixtureAnimals
        XCTAssertEqual(LivestockAnimalSearch.listed(fixtures, query: "  ").map(\.displayName), ["Juniper", "Cedar"])
        XCTAssertEqual(LivestockAnimalSearch.listed(fixtures, query: "jun").map(\.displayName), ["Juniper"])
        XCTAssertEqual(LivestockAnimalSearch.listed(fixtures, query: "G-18").map(\.displayName), ["Cedar"])
        XCTAssertTrue(LivestockAnimalSearch.listed(fixtures, query: "no-such-animal").isEmpty)
        XCTAssertFalse(LivestockAnimalSearch.matches(fixtures[0], query: "Cedar"))
        let labels = LivestockDestination.allCases.map(\.label)
        XCTAssertEqual(LivestockDestination.herd.label, "Herd/group")
        XCTAssertFalse(labels.contains("Care"))
        XCTAssertFalse(labels.contains("Feed and supplies"))
        XCTAssertFalse(labels.contains("Costs"))
        XCTAssertEqual(FixtureLoadState.empty(message: "Nothing here").message, "Nothing here")
        XCTAssertEqual(FixtureLoadState.error(message: "Read failed").message, "Read failed")
        XCTAssertEqual(FixtureLoadState.loading.message, "Loading fixture presentation…")
    }

    func testDictationReplacesSelectedTextAndKeepsTheRest() {
        let field = "Fix the north gate"
        let north = field.range(of: "north")!
        let lower = field.utf16.distance(from: field.utf16.startIndex, to: north.lowerBound)
        let upper = field.utf16.distance(from: field.utf16.startIndex, to: north.upperBound)
        XCTAssertEqual(
            AppleIntelligenceDictationText.completed(
                value: field,
                replacingUTF16: lower..<upper,
                utterance: "south"
            ),
            "Fix the south gate"
        )
        XCTAssertEqual(
            AppleIntelligenceDictationText.completed(
                value: "Juniper",
                replacingUTF16: 0..<7,
                utterance: "Cedar"
            ),
            "Cedar"
        )
        XCTAssertEqual(
            AppleIntelligenceDictationText.completed(
                value: field,
                replacingUTF16: lower..<upper,
                utterance: "  "
            ),
            field
        )
        let caret = field.utf16.distance(from: field.utf16.startIndex, to: field.range(of: "gate")!.lowerBound)
        XCTAssertEqual(
            AppleIntelligenceDictationText.completed(
                value: field,
                replacingUTF16: caret..<caret,
                utterance: "barn"
            ),
            "Fix the north barn gate"
        )
        XCTAssertEqual(
            AppleIntelligenceDictationText.completed(
                value: field,
                replacingUTF16: nil,
                utterance: "now"
            ),
            "Fix the north gate now"
        )
        XCTAssertEqual(
            AppleIntelligenceDictationText.completed(
                value: field,
                replacingUTF16: 90..<94,
                utterance: "south"
            ),
            "Fix the north gate south"
        )
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
        draft.lifecycleWeight = "842"
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
        XCTAssertEqual(draft.costProblem(), "\(LivestockInputType.hay.label) cost cannot be negative.")
        draft.feedLines[0].cost = "1.25"
        draft.costAmount = "10"
        XCTAssertNil(draft.costProblem())
        XCTAssertEqual(draft.enteredTotal(), Decimal(string: "927", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(
            LivestockMoney.total(recorded: 20, entered: draft.enteredTotal()),
            Decimal(string: "947", locale: Locale(identifier: "en_US_POSIX"))
        )
        XCTAssertEqual(LivestockMoney.total(recorded: -5, entered: 0), 0)
        XCTAssertEqual(LivestockMoney.positiveText("0"), nil)
        XCTAssertEqual(LivestockMoney.positiveText("8"), "8")
        XCTAssertEqual(LivestockMoney.entry("123456.789"), "12345.78")
        XCTAssertEqual(LivestockMoney.entry("$99,999.90"), "99999.90")
        XCTAssertEqual(LivestockMoney.entry("-4.5"), "-4.5")
        XCTAssertEqual(LivestockMoney.entry("-"), "-")
        var typedCosts = LivestockAnimalSaveDraft()
        typedCosts.identifierCost = "1"
        typedCosts.careCost = "1"
        typedCosts.careType = .observation
        typedCosts.feedLines = [
            LivestockFeedEntry(inputType: .feed, quantity: "1", frequency: .daily, cost: "2"),
            LivestockFeedEntry(inputType: .hay, quantity: "1", unit: .bag, frequency: .monthly, cost: "40"),
            LivestockFeedEntry(inputType: .supplement, quantity: "1", unit: .scoop, frequency: .weekly, cost: "5"),
        ]
        let summary = typedCosts.costSummary(recorded: [])
        XCTAssertEqual(summary.feedSubtotals.map(\.label), ["Feed · Daily", "Hay · Monthly", "Supplement · Weekly"])
        XCTAssertEqual(summary.feedTotal, 1470)
        XCTAssertEqual(summary.other, 2)
        XCTAssertEqual(summary.total, 1472)
        XCTAssertEqual(LivestockMoney.usd(summary.total), "$1,472.00")
        XCTAssertFalse(LivestockCareEventType.observation.requiresCost)
        XCTAssertNil(LivestockCareEventType.observation.costProblem(""))
        XCTAssertNil(LivestockCareEventType.observation.costProblem("0"))
        XCTAssertEqual(
            LivestockCareEventType.observation.costRequirementNote,
            "Average cost can be zero. This does not post to Finance."
        )
        for type in LivestockCareEventType.allCases where type.requiresCost {
            XCTAssertEqual(type.costProblem(""), "\(type.label) cost is required.")
            XCTAssertTrue(type.costRequirementNote.hasPrefix("Cost is required for \(type.label)."))
            XCTAssertNil(type.costProblem("12.50"))
        }
        var careDraft = LivestockAnimalSaveDraft()
        careDraft.careType = .observation
        XCTAssertNil(careDraft.costProblem())
        XCTAssertFalse(LivestockCareEventType.observation.requiresDosage)
        careDraft.careType = .vaccination
        XCTAssertEqual(careDraft.costProblem(), "Vaccination cost is required.")
        careDraft.careCost = "25"
        XCTAssertEqual(careDraft.costProblem(), "Vaccination dosage is required.")
        XCTAssertEqual(
            LivestockCareEventType.vaccination.dosageRequirementNote,
            "Dosage is required for Vaccination. Record how much was given, such as 5 mL or 2 cc."
        )
        careDraft.careDosage = "2 mL"
        XCTAssertNil(careDraft.costProblem())
        XCTAssertTrue(LivestockCareEventType.medicationAdministration.requiresDosage)
        XCTAssertEqual(
            LivestockCareEventType.medicationAdministration.dosageProblem(""),
            "Medication dosage is required."
        )
        XCTAssertEqual(LivestockCostFrequency.daily.timesPerYear, 365)
        XCTAssertEqual(LivestockCostFrequency.weekly.timesPerYear, 52)
        XCTAssertEqual(LivestockCostFrequency.monthly.timesPerYear, 12)
        XCTAssertEqual(LivestockCostFrequency.quarterly.timesPerYear, 4)
        XCTAssertEqual(LivestockCostFrequency.semiAnnual.timesPerYear, 2)
        XCTAssertEqual(LivestockCostFrequency.annual.timesPerYear, 1)
        XCTAssertEqual(LivestockCostFrequency.semiAnnual.label, "Semi-annual")
        XCTAssertEqual(LivestockCostFrequency.annual.label, "Annual")
        let weekly = LivestockFeedEntry(inputType: .corn, quantity: "2", frequency: .weekly, cost: "3")
        XCTAssertEqual(weekly.annualFeedCost, 312)
        let semiAnnual = LivestockFeedEntry(inputType: .corn, quantity: "2", frequency: .semiAnnual, cost: "3")
        XCTAssertEqual(semiAnnual.annualFeedCost, 12)
        let annual = LivestockFeedEntry(inputType: .corn, quantity: "2", frequency: .annual, cost: "3")
        XCTAssertEqual(annual.annualFeedCost, 6)
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
        XCTAssertEqual(
            FixturePresentationBoundary.retiredCorrectionBoundary,
            "Retirement is locked. You can correct existing care, feed, and cost. You cannot add new records."
        )
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
        XCTAssertEqual(
            LivestockInputType.entryChoices(for: .pet).map(\.label),
            ["Dry food", "Wet food", "Prepared meal", "Supplement"]
        )
        XCTAssertEqual(
            LivestockInputType.entryChoices(for: .cattle).map(\.label),
            ["Pasture", "Grass hay", "Alfalfa hay", "Corn", "Corn silage", "Prepared meal", "Mineral", "Supplement"]
        )
        XCTAssertEqual(
            LivestockInputType.entryChoices(for: .chicken).map(\.label),
            ["Prepared meal", "Scratch", "Corn", "Oyster shell", "Grit", "Supplement"]
        )
        XCTAssertEqual(
            LivestockInputType.entryChoices(for: .pet, petKind: .bird).map(\.label),
            ["Seed", "Pellets", "Prepared meal", "Supplement"]
        )
        XCTAssertEqual(LivestockInputUnit.entryChoices.map(\.label), ["Scoop", "Cup", "Bale", "Each", "Bag", "Pounds"])
        let shot = LivestockCareEvent(id: UUID(), type: .vaccination, occurredAt: Date(), itemName: "CDT", dosage: "2 mL")
        XCTAssertEqual(shot.summary, "Vaccination · CDT · 2 mL")
        let pills = LivestockCareEvent(
            id: UUID(),
            type: .medicationAdministration,
            occurredAt: Date(),
            itemName: "Ivermectin",
            itemKind: "Pills",
            dosage: "5 mL"
        )
        XCTAssertEqual(pills.summary, "Medication · Ivermectin · Pills · 5 mL")
        let unnamed = LivestockCareEvent(id: UUID(), type: .vaccination, occurredAt: Date())
        XCTAssertEqual(unnamed.summary, "Vaccination")
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

    func testPoundsShowReadOnlyKilograms() {
        XCTAssertEqual(LivestockWeight.kilogramsText(for: "842.5"), "382.15 kg")
        XCTAssertEqual(LivestockWeight.kilogramsText(for: "1"), "0.45 kg")
        XCTAssertEqual(LivestockWeight.kilogramsText(for: ""), "—")
        XCTAssertEqual(LivestockWeight.kilogramsText(for: "0"), "—")
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
        guard case .recorded(let weight) = store.recordFixtureLifecycleEvent(
            animalID: animalID,
            type: .weightRecorded,
            occurredAt: intakeAt.addingTimeInterval(120),
            weightPounds: Decimal(string: "842.5", locale: Locale(identifier: "en_US_POSIX"))
        ) else {
            return XCTFail("A later weight recorded event should append")
        }
        XCTAssertEqual(weight.historyTitle, "Weight recorded · 842.5 lb")
        XCTAssertEqual(
            store.recordFixtureLifecycleEvent(
                animalID: animalID,
                type: .weightRecorded,
                occurredAt: intakeAt.addingTimeInterval(180)
            ),
            .rejected("Enter the weight in pounds.")
        )
        XCTAssertEqual(
            store.recordFixtureLifecycleEvent(
                animalID: animalID,
                type: .intake,
                occurredAt: intakeAt.addingTimeInterval(180),
                weightPounds: 10
            ),
            .rejected("Only a weight record stores a weight.")
        )
        guard case .recorded(let correctedWeight) = store.correctFixtureLifecycleEvent(
            animalID: animalID,
            eventID: weight.id,
            occurredAt: intakeAt.addingTimeInterval(30),
            reason: .incorrectTime,
            confirmed: true
        ) else {
            return XCTFail("Owner should keep the weight on a time correction")
        }
        XCTAssertEqual(correctedWeight.weightPounds, weight.weightPounds)
        XCTAssertTrue(correctedWeight.historyTitle.contains("842.5 lb"))
        XCTAssertEqual(store.animals[0].lifecycleEvents.map(\.type), [.intake, .tagged, .weightRecorded, .weightRecorded])
        XCTAssertEqual(
            store.recordFixtureLifecycleEvent(animalID: animalID, type: .intake, occurredAt: intakeAt),
            .rejected(FixturePresentationBoundary.lifecycleOrderBoundary)
        )
        XCTAssertEqual(store.animals[0].lifecycleEvents.count, 4)
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

    @MainActor
    func testOwnerCanCorrectALifecycleEventAndKeepTheOriginal() async {
        let owner = LivestockStore()
        await owner.loadFixtures()
        let animalID = owner.animals[0].id
        let intakeAt = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .recorded(let intake) = owner.recordFixtureLifecycleEvent(animalID: animalID, type: .intake, occurredAt: intakeAt) else {
            return XCTFail("Owner should record an intake event")
        }
        let correctedAt = intakeAt.addingTimeInterval(-3600)
        guard case .recorded(let correction) = owner.correctFixtureLifecycleEvent(
            animalID: animalID,
            eventID: intake.id,
            occurredAt: correctedAt,
            reason: .incorrectTime,
            confirmed: true
        ) else {
            return XCTFail("Owner should correct the intake event")
        }
        let events = owner.animals[0].lifecycleEvents
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(correction.type, .intake)
        XCTAssertEqual(correction.correctionReason, .incorrectTime)
        XCTAssertEqual(correction.supersedesEventID, intake.id)
        XCTAssertTrue(correction.isCurrent)
        XCTAssertEqual(events.first { $0.id == intake.id }?.isCurrent, false)
        XCTAssertEqual(events.first { $0.id == intake.id }?.occurredAt, intakeAt)
        XCTAssertEqual(
            owner.correctFixtureLifecycleEvent(
                animalID: animalID,
                eventID: intake.id,
                occurredAt: correctedAt,
                reason: .duplicateEntry,
                confirmed: true
            ),
            .rejected(FixturePresentationBoundary.lifecycleAlreadyCorrectedBoundary)
        )
        XCTAssertEqual(
            owner.correctFixtureLifecycleEvent(
                animalID: animalID,
                eventID: intake.id,
                occurredAt: correctedAt,
                reason: .incorrectValue,
                confirmed: false
            ),
            .rejected(FixturePresentationBoundary.lifecycleCorrectionConfirmationBoundary)
        )

        let manager = LivestockStore(fixtureWriteRole: .manager)
        await manager.loadFixtures()
        guard case .recorded(let managerEvent) = manager.recordFixtureLifecycleEvent(
            animalID: manager.animals[0].id,
            type: .tagged,
            occurredAt: intakeAt
        ) else {
            return XCTFail("Manager should record a lifecycle event")
        }
        XCTAssertEqual(
            manager.correctFixtureLifecycleEvent(
                animalID: manager.animals[0].id,
                eventID: managerEvent.id,
                occurredAt: correctedAt,
                reason: .incorrectTime,
                confirmed: true
            ),
            .rejected(FixturePresentationBoundary.ownerCorrectsLifecycleBoundary)
        )
        XCTAssertEqual(manager.animals[0].lifecycleEvents.count, 1)
        XCTAssertTrue(manager.animals[0].lifecycleEvents[0].isCurrent)
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
        XCTAssertFalse(LivestockDevLoopbackRead.acceptsDevURL(URL(string: "http://192.168.50.115:9/api")!))

        let loopback = """
        {"baseURL":"http://127.0.0.1:18761","token":"secret","tenantID":"tenant-a","expiresAt":"\(expiresAt)"}
        """
        try loopback.write(to: ticket, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(LivestockDevLoopbackRead.load(fileURL: ticket))
        XCTAssertEqual(loaded.tenantID, "tenant-a")
        XCTAssertEqual(LivestockDevLoopbackRead.connectedWhileOpenCaption, "Connected while Livestock is open.")
        XCTAssertTrue(LivestockDevLoopbackRead.connectedUntilCaption(loaded.expiresAt).hasPrefix("Connected to DEV until "))
        XCTAssertTrue(
            LivestockDevLoopbackRead.connectedUntilCaption(loaded.expiresAt, environment: "PROD")
                .hasPrefix("Connected to PROD until ")
        )

        let expiredAt = expiry.string(from: Date().addingTimeInterval(-60))
        let expired = """
        {"baseURL":"http://127.0.0.1:18761","token":"secret","tenantID":"tenant-a","expiresAt":"\(expiredAt)"}
        """
        try expired.write(to: ticket, atomically: true, encoding: .utf8)
        XCTAssertNil(LivestockDevLoopbackRead.load(fileURL: ticket))
    }

    @MainActor
    func testReconnectWithoutATicketDoesNotOpenTheSampleSession() async {
        let store = LivestockStore()
        await store.loadFixtures()
        XCTAssertEqual(store.animals.first?.displayName, "Juniper")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-dev-read.json")
        await store.reconnectToDev(fileURL: missing)
        XCTAssertFalse(store.session.isLive)
        XCTAssertTrue(store.animals.isEmpty)
        XCTAssertEqual(store.session.statusTitle, "DEV connection ended")
        XCTAssertEqual(store.animalsState, .error(message: LivestockReadConnection.endedMessage))
    }

    @MainActor
    func testLiveSessionStaysConnectedWhenALaterReadFails() async {
        let animal = Animal(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: LivestockCatalog.breeds.first { $0.code == "dorper" },
            identifiers: [],
            status: "Active"
        )
        let page = LivestockAuthorizedAnimalPage(origin: .live, animals: [animal])
        let provider = SequentialAuthorizedRead([
            .success(page),
            .failure(LivestockDevReadError.unavailable(LivestockDevLoopbackRead.serverNotRunningMessage)),
        ])
        let store = LivestockStore(connection: LivestockReadConnection(authorizedProvider: provider))
        await store.loadAuthorizedRead()
        XCTAssertTrue(store.session.isLive)
        XCTAssertEqual(store.animals.map(\.displayName), ["Maple"])
        await store.loadAuthorizedRead()
        XCTAssertTrue(store.session.isLive)
        XCTAssertEqual(store.animals.map(\.displayName), ["Maple"])
        XCTAssertEqual(store.connectionHoldMessage, LivestockDevLoopbackRead.serverNotRunningMessage)
        XCTAssertTrue(store.session.statusDetail.contains("stays connected while it is open"))
    }

    @MainActor
    func testReconnectWithoutATicketKeepsAnOpenLiveSession() async {
        let animal = Animal(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: LivestockCatalog.breeds.first { $0.code == "dorper" },
            identifiers: [],
            status: "Active"
        )
        let ticket = LivestockDevLoopbackRead(
            baseURL: URL(string: "http://127.0.0.1:18761")!,
            token: "secret",
            tenantID: "tenant-a",
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let store = LivestockStore(
            connection: LivestockReadConnection(
                authorizedProvider: StaticAuthorizedRead(
                    page: LivestockAuthorizedAnimalPage(origin: .live, animals: [animal])
                )
            ),
            liveRecords: ticket
        )
        await store.loadAuthorizedRead()
        XCTAssertTrue(store.session.isLive)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-open-dev-read.json")
        await store.reconnectToDev(fileURL: missing)
        XCTAssertTrue(store.session.isLive)
        XCTAssertEqual(store.animals.map(\.displayName), ["Maple"])
        XCTAssertNotNil(store.liveRecords)
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

    func testHerdFeedAddsToOverviewWithoutCopyingOntoAnimals() {
        let consumptionID = UUID()
        let herd = LivestockHerd(
            id: UUID(),
            name: "North pasture",
            consumptions: [
                LivestockConsumption(
                    id: consumptionID,
                    inputType: .hay,
                    quantity: "4",
                    unit: .bale,
                    observedAt: Date(),
                    supplier: nil,
                    batch: nil,
                    frequency: .daily
                )
            ],
            costs: [
                LivestockCostAttribution(
                    id: UUID(),
                    amount: "40",
                    financeReference: nil,
                    recordedAt: Date(),
                    frequency: .daily,
                    feedType: .hay,
                    consumptionID: consumptionID,
                    basisCode: "per_herd"
                )
            ]
        )
        let animal = Animal(
            id: UUID(),
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: nil,
            identifiers: [],
            herdID: herd.id,
            herdName: herd.name,
            status: "Active"
        )
        XCTAssertTrue(animal.consumptions.isEmpty)
        XCTAssertEqual(animal.recordedCostTotal, 0)
        XCTAssertGreaterThan(herd.recordedCostTotal, 0)
        XCTAssertEqual(HerdOverview.from(animals: [animal], herds: [herd]).totalCost, herd.recordedCostTotal)
        XCTAssertTrue(herd.costs[0].summary.contains("per herd"))
    }

    @MainActor
    func testHerdFeedSaveWithoutALiveConnectionStaysOffTheSampleSession() async {
        let store = LivestockStore()
        await store.loadFixtures()
        _ = await store.createHerd(name: "East Field")
        let herdID = try! XCTUnwrap(store.herds.first?.id)
        let message = await store.saveHerdFeed(
            herdID: herdID,
            lines: [LivestockFeedEntry(inputType: .hay, quantity: "2", cost: "10")],
            observedAt: Date(),
            supplier: "",
            batch: ""
        )
        XCTAssertEqual(message, "Herd feed saves in the DEV database. Connect to it first.")
        XCTAssertTrue(store.herds[0].consumptions.isEmpty)
        XCTAssertEqual(store.animals.first?.displayName, "Juniper")
    }

    func testHerdCareAddsToOverviewWithoutCopyingOntoAnimals() {
        let eventID = UUID()
        let herd = LivestockHerd(
            id: UUID(),
            name: "North pasture",
            careEvents: [
                LivestockCareEvent(
                    id: eventID,
                    type: .vaccination,
                    occurredAt: Date(),
                    itemName: "CDT"
                )
            ],
            costs: [
                LivestockCostAttribution(
                    id: UUID(),
                    amount: "12",
                    financeReference: nil,
                    recordedAt: Date(),
                    careEventID: eventID,
                    basisCode: "per_herd"
                )
            ]
        )
        let animal = Animal(
            id: UUID(),
            displayName: "Maple",
            species: .sheep,
            productionType: .breeding,
            breed: nil,
            identifiers: [],
            herdID: herd.id,
            herdName: herd.name,
            status: "Active"
        )
        XCTAssertTrue(animal.careEvents.isEmpty)
        XCTAssertEqual(animal.recordedCostTotal, 0)
        XCTAssertGreaterThan(herd.recordedCostTotal, 0)
        XCTAssertEqual(HerdOverview.from(animals: [animal], herds: [herd]).totalCost, herd.recordedCostTotal)
        XCTAssertEqual(herd.costLabel(herd.costs[0]), "Care · Vaccination")
        XCTAssertTrue(herd.costs[0].summary.contains("per herd"))
    }

    @MainActor
    func testHerdCareSaveWithoutALiveConnectionStaysOffTheSampleSession() async {
        let store = LivestockStore()
        await store.loadFixtures()
        _ = await store.createHerd(name: "West Field")
        let herdID = try! XCTUnwrap(store.herds.first?.id)
        let message = await store.saveHerdCare(
            herdID: herdID,
            type: .observation,
            occurredAt: Date(),
            itemName: "",
            itemKind: "",
            cost: "",
            financeReference: ""
        )
        XCTAssertEqual(message, "Herd care saves in the DEV database. Connect to it first.")
        XCTAssertTrue(store.herds[0].careEvents.isEmpty)
        XCTAssertEqual(store.animals.first?.displayName, "Juniper")
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
        XCTAssertEqual(LivestockHerdMenu.assignable(store.herds).map(\.name), ["North pasture"])
        XCTAssertNil(LivestockHerdMenu.selection(south!.id, among: store.herds))
        XCTAssertEqual(
            LivestockHerdMenu.selection(store.herds.first { $0.name == "North pasture" }?.id, among: store.herds),
            store.herds.first { $0.name == "North pasture" }?.id
        )
        XCTAssertEqual(
            HerdGrouping.groups(animals: store.animals, herds: store.herds).map(\.name),
            ["North pasture", "No herd"]
        )
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

    func testBillOfSalePDFListsTheSoldAnimalsDetails() throws {
        let day = Date(timeIntervalSince1970: 1_759_536_000)
        let animal = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: LivestockCatalog.breeds.first { $0.code == "angus" && $0.species == .cattle },
            identifiers: [LivestockAnimalIdentifier(id: UUID(), kind: .earTag, value: "AST-1")],
            lifecycleEvents: [LivestockLifecycleEvent(id: UUID(), type: .intake, occurredAt: day)],
            retirementReason: .sold,
            retiredAt: day,
            saleAmount: 1200,
            saleOn: day,
            status: "Retired"
        )
        let text = LivestockBillOfSale.lines(for: animal).map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Bill of sale"))
        XCTAssertTrue(text.contains("Aster"))
        XCTAssertTrue(text.contains("Angus"))
        XCTAssertTrue(text.contains("Ear tag: AST-1"))
        XCTAssertTrue(text.contains("Intake"))
        XCTAssertTrue(text.contains(LivestockMoney.usd(1200)))
        XCTAssertTrue(text.contains("does not post to Finance"))
        let data = LivestockBillOfSale.pdfData(for: animal)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 0)
        let pdfText = document.string ?? ""
        XCTAssertTrue(pdfText.contains("Bill of sale"))
        XCTAssertTrue(pdfText.contains("Aster"))
        XCTAssertTrue(pdfText.contains("AST-1"))
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

    func testLifecycleAndCareCostsStayWithTheirEventAndType() throws {
        let day = Date(timeIntervalSince1970: 1_760_536_000)
        let intake = LivestockLifecycleEvent(id: UUID(), type: .intake, occurredAt: day)
        let tagged = LivestockLifecycleEvent(id: UUID(), type: .tagged, occurredAt: day.addingTimeInterval(60))
        let shot = LivestockCareEvent(id: UUID(), type: .vaccination, occurredAt: day, itemName: "CDT")
        let secondShot = LivestockCareEvent(id: UUID(), type: .vaccination, occurredAt: day.addingTimeInterval(120))
        let surgery = LivestockCareEvent(id: UUID(), type: .surgery, occurredAt: day.addingTimeInterval(240))
        func cost(_ amount: String, lifecycle: UUID? = nil, care: UUID? = nil) -> LivestockCostAttribution {
            LivestockCostAttribution(
                id: UUID(),
                amount: amount,
                financeReference: nil,
                recordedAt: day,
                lifecycleEventID: lifecycle,
                careEventID: care
            )
        }
        let animal = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [],
            lifecycleEvents: [intake, tagged],
            careEvents: [shot, secondShot, surgery],
            costs: [
                cost("25", lifecycle: intake.id),
                cost("12.50", care: shot.id),
                cost("10", care: secondShot.id),
                cost("-2.50", care: secondShot.id),
                cost("300", care: surgery.id),
                cost("7"),
            ],
            status: "Active"
        )
        XCTAssertEqual(animal.eventCost(intake.id), 25)
        XCTAssertNil(animal.eventCost(tagged.id))
        XCTAssertEqual(animal.eventCost(secondShot.id), Decimal(string: "7.5"))
        XCTAssertEqual(animal.lifecycleCostByType, [LivestockTypeCost(label: "Intake", amount: 25)])
        XCTAssertEqual(animal.careCostByType, [
            LivestockTypeCost(label: "Surgery", amount: 300),
            LivestockTypeCost(label: "Vaccination", amount: 20),
        ])
        XCTAssertEqual(animal.recordedCostTotal, 352)
        let labels = LivestockCostLedger.days(from: animal.costs, label: animal.costLabel).flatMap(\.lines).map(\.label)
        XCTAssertTrue(labels.contains("Routine lifecycle · Intake"))
        XCTAssertTrue(labels.contains("Care · Vaccination"))
        XCTAssertTrue(labels.contains("Operational"))

        var draft = LivestockAnimalSaveDraft()
        draft.lifecycleType = .tagged
        draft.lifecycleCost = "15"
        XCTAssertNil(draft.costProblem())
        XCTAssertEqual(draft.enteredTotal(), 15)
        XCTAssertTrue(draft.hasActivityCost)
        draft.lifecycleType = nil
        XCTAssertEqual(draft.enteredTotal(), 0)
        draft.lifecycleType = .intake
        draft.lifecycleCost = "abc"
        XCTAssertNotNil(draft.costProblem())

        let json = """
        {"origin":"live","body":{"animals":[{"animal_id":"11111111-2222-4333-8444-555555555551","display_name":"Aster",
          "species_code":"cattle","production_type_code":"beef","breed_code":"angus","lifecycle_status":"active",
          "identifiers":[],"lifecycle_events":[],"care_events":[],"consumptions":[],
          "costs":[{"id":"11111111-2222-4333-8444-5555555555c1","amount":"9.00","recorded_at":"2026-10-15T14:00:00Z",
            "care_event_id":"11111111-2222-4333-8444-5555555555e1","lifecycle_event_id":null}]}],"herds":[]}}
        """
        let page = try LivestockDevLoopbackRead.decode(Data(json.utf8))
        let decoded = try XCTUnwrap(page.animals.first?.costs.first)
        XCTAssertEqual(decoded.careEventID, UUID(uuidString: "11111111-2222-4333-8444-5555555555e1"))
        XCTAssertNil(decoded.lifecycleEventID)
        XCTAssertEqual(decoded.ledgerLabel, "Care")
    }

    func testDuplicateEventTakesItsCostOutOfTotalsAndCorrectionsCarryACost() {
        let day = Date(timeIntervalSince1970: 1_760_536_000)
        let shot = LivestockCareEvent(id: UUID(), type: .vaccination, occurredAt: day, isCurrent: false)
        let duplicate = LivestockCareEvent(
            id: UUID(), type: .vaccination, occurredAt: day, supersedesID: shot.id, correctionReason: .duplicateEntry
        )
        let weighed = LivestockLifecycleEvent(id: UUID(), type: .weightRecorded, occurredAt: day)
        let shotCost = LivestockCostAttribution(id: UUID(), amount: "25", financeReference: nil, recordedAt: day, careEventID: shot.id)
        let weighCost = LivestockCostAttribution(
            id: UUID(), amount: "6", financeReference: nil, recordedAt: day, lifecycleEventID: weighed.id
        )
        let hay = LivestockConsumption(
            id: UUID(), inputType: .grassHay, quantity: "2", unit: .bale, observedAt: day,
            supplier: nil, batch: nil, frequency: .daily, isCurrent: false
        )
        let fixedHay = LivestockConsumption(
            id: UUID(), inputType: .grassHay, quantity: "3", unit: .bale, observedAt: day,
            supplier: nil, batch: nil, frequency: .daily, supersedesID: hay.id, correctionReason: .incorrectValue
        )
        let straw = LivestockConsumption(
            id: UUID(), inputType: .grassHay, quantity: "1", unit: .bale, observedAt: day,
            supplier: nil, batch: nil, frequency: .daily, correctionReason: .duplicateEntry
        )
        let hayCost = LivestockCostAttribution(
            id: UUID(), amount: "30", financeReference: nil, recordedAt: day, frequency: .daily, feedType: .grassHay,
            consumptionID: hay.id
        )
        let strawCost = LivestockCostAttribution(
            id: UUID(), amount: "11", financeReference: nil, recordedAt: day, frequency: .daily, feedType: .grassHay,
            consumptionID: straw.id
        )
        let olderFeedCost = LivestockCostAttribution(
            id: UUID(), amount: "4", financeReference: nil, recordedAt: day, frequency: .daily, feedType: .grassHay
        )
        let animal = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [],
            lifecycleEvents: [weighed],
            careEvents: [shot, duplicate],
            consumptions: [hay, fixedHay, straw],
            costs: [shotCost, weighCost, hayCost, strawCost, olderFeedCost],
            status: "Active"
        )
        XCTAssertEqual(animal.activeCosts.map(\.id), [weighCost.id, hayCost.id, olderFeedCost.id])
        XCTAssertTrue(animal.isRemovedWithEvent(shotCost))
        XCTAssertTrue(animal.isRemovedWithEvent(strawCost))
        XCTAssertFalse(animal.isRemovedWithEvent(weighCost))
        XCTAssertNil(animal.eventCost(duplicate.id))
        XCTAssertEqual(animal.careCostByType, [])
        XCTAssertEqual(animal.eventCosts(weighed.id).map(\.id), [weighCost.id])
        XCTAssertEqual(animal.eventCosts(fixedHay.id).map(\.id), [hayCost.id])
        XCTAssertEqual(animal.feedCostByType, [LivestockTypeCost(label: LivestockInputType.grassHay.label, amount: 30)])
        XCTAssertTrue(animal.costLabel(hayCost).hasPrefix("Feed · "))

        XCTAssertNil(LivestockCostFix.entered(costID: weighCost.id, amount: "  "))
        let fix = LivestockCostFix(costID: weighCost.id, amount: "8.50")
        XCTAssertNil(fix.problem(reason: .incorrectValue))
        XCTAssertNotNil(fix.problem(reason: .duplicateEntry))
        XCTAssertNotNil(LivestockCostFix(costID: weighCost.id, amount: "0").problem(reason: .incorrectValue))
        XCTAssertNil(LivestockRecordCorrection.feed(
            consumptionID: fixedHay.id, quantity: "3", unit: .bale, frequency: .daily, observedAt: day,
            supplier: "", batch: "", reason: .incorrectValue, cost: LivestockCostFix(costID: nil, amount: "12")
        ).problem)
        for blankOrZero in ["", "0", "-3"] {
            XCTAssertNotNil(LivestockRecordCorrection.feed(
                consumptionID: fixedHay.id, quantity: "3", unit: .bale, frequency: .daily, observedAt: day,
                supplier: "", batch: "", reason: .incorrectValue, cost: LivestockCostFix(costID: nil, amount: blankOrZero)
            ).problem, blankOrZero)
        }

        XCTAssertNil(LivestockFeedEntry.problem(quantity: "2", cost: "4.50", feed: "Hay"))
        XCTAssertNotNil(LivestockFeedEntry.problem(quantity: "", cost: "4.50", feed: "Hay"))
        XCTAssertNotNil(LivestockFeedEntry.problem(quantity: "2", cost: "", feed: "Hay"))
        XCTAssertNotNil(LivestockFeedEntry.problem(quantity: "2", cost: "0", feed: "Hay"))
        let costOnly = LivestockFeedEntry(inputType: .hay, quantity: "", frequency: .daily, cost: "5")
        XCTAssertEqual(costOnly.annualFeedCost, 0)
        XCTAssertFalse(LivestockFeedEntry.canSave([costOnly]))
        let ready = LivestockFeedEntry(inputType: .hay, quantity: "1", unit: .lb, frequency: .daily, cost: "5")
        XCTAssertEqual(ready.annualFeedCost, 1825)
        XCTAssertTrue(LivestockFeedEntry.canSave([ready]))
        XCTAssertFalse(LivestockFeedEntry.canSave([LivestockFeedEntry(inputType: .hay)]))
        var draft = LivestockAnimalSaveDraft()
        draft.feedLines = [LivestockFeedEntry(inputType: .grassHay, cost: "6")]
        XCTAssertEqual(draft.costProblem(), "\(LivestockInputType.grassHay.label) needs a quantity of 1 or more.")
        XCTAssertNotNil(LivestockRecordCorrection.care(
            eventID: weighed.id, occurredAt: day, reason: .incorrectValue, itemName: "", itemKind: "",
            cost: LivestockCostFix(costID: nil, amount: "abc")
        ).problem)
    }

    func testCorrectedRecordsReplaceTheEarlierOneInTotalsAndKeepTheirCost() throws {
        let day = Date(timeIntervalSince1970: 1_760_536_000)
        let shot = LivestockCareEvent(id: UUID(), type: .vaccination, occurredAt: day, itemName: "CDT", isCurrent: false)
        let fixed = LivestockCareEvent(
            id: UUID(),
            type: .vaccination,
            occurredAt: day.addingTimeInterval(3600),
            itemName: "Covexin",
            supersedesID: shot.id,
            correctionReason: .incorrectValue
        )
        let hay = LivestockConsumption(
            id: UUID(), inputType: .grassHay, quantity: "2", unit: .bale, observedAt: day,
            supplier: nil, batch: nil, frequency: .weekly, isCurrent: false
        )
        let duplicateHay = LivestockConsumption(
            id: UUID(), inputType: .grassHay, quantity: "2", unit: .bale, observedAt: day,
            supplier: nil, batch: nil, frequency: .weekly,
            supersedesID: hay.id, correctionReason: .duplicateEntry
        )
        let wrong = LivestockCostAttribution(
            id: UUID(), amount: "100", financeReference: nil, recordedAt: day, careEventID: shot.id, isCurrent: false
        )
        let right = LivestockCostAttribution(
            id: UUID(), amount: "40", financeReference: nil, recordedAt: day, careEventID: shot.id,
            supersedesID: wrong.id, correctionReason: .incorrectValue
        )
        let doubled = LivestockCostAttribution(id: UUID(), amount: "9", financeReference: nil, recordedAt: day, isCurrent: false)
        let removed = LivestockCostAttribution(
            id: UUID(), amount: "9", financeReference: nil, recordedAt: day,
            supersedesID: doubled.id, correctionReason: .duplicateEntry
        )
        let animal = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [],
            careEvents: [shot, fixed],
            consumptions: [hay, duplicateHay],
            costs: [wrong, right, doubled, removed],
            status: "Active"
        )
        XCTAssertEqual(animal.activeCosts.map(\.id), [right.id])
        XCTAssertEqual(animal.recordedCostTotal, 40)
        XCTAssertEqual(animal.eventCost(fixed.id), 40)
        XCTAssertEqual(animal.careCostByType, [LivestockTypeCost(label: "Vaccination", amount: 40)])
        XCTAssertTrue(fixed.isActive)
        XCTAssertFalse(shot.isActive)
        XCTAssertTrue(shot.historyTitle.hasSuffix("earlier record"))
        XCTAssertTrue(fixed.historyTitle.contains("Incorrect value"))
        XCTAssertFalse(duplicateHay.isActive)
        XCTAssertTrue(duplicateHay.historyTitle.contains("removed as a duplicate"))

        XCTAssertNotNil(LivestockRecordCorrection.cost(costID: right.id, amount: "0", reason: .incorrectValue).problem)
        XCTAssertNotNil(LivestockRecordCorrection.cost(costID: right.id, amount: "5", reason: .incorrectTime).problem)
        XCTAssertNil(LivestockRecordCorrection.cost(costID: right.id, amount: "-5", reason: .incorrectValue).problem)
        XCTAssertNil(LivestockRecordCorrection.cost(costID: right.id, amount: "", reason: .duplicateEntry).problem)
        XCTAssertNotNil(LivestockRecordCorrection.feed(
            consumptionID: hay.id, quantity: "", unit: .bale, frequency: .weekly,
            observedAt: day, supplier: "", batch: "", reason: .incorrectValue
        ).problem)

        let json = """
        {"origin":"live","body":{"animals":[{"animal_id":"11111111-2222-4333-8444-555555555551","display_name":"Aster",
          "species_code":"cattle","production_type_code":"beef","breed_code":"angus","lifecycle_status":"active",
          "identifiers":[],"lifecycle_events":[],"consumptions":[],
          "care_events":[{"id":"11111111-2222-4333-8444-5555555555e2","type":"observation","occurred_at":"2026-10-15T14:00:00Z",
            "supersedes_id":"11111111-2222-4333-8444-5555555555e1","correction_reason":"incorrect_time","current":true}],
          "costs":[{"id":"11111111-2222-4333-8444-5555555555c1","amount":"9.00","recorded_at":"2026-10-15T14:00:00Z",
            "supersedes_id":null,"correction_reason":null,"current":false}]}],"herds":[]}}
        """
        let page = try LivestockDevLoopbackRead.decode(Data(json.utf8))
        let decoded = try XCTUnwrap(page.animals.first)
        XCTAssertEqual(decoded.careEvents.first?.correctionReason, .incorrectTime)
        XCTAssertEqual(decoded.careEvents.first?.supersedesID, UUID(uuidString: "11111111-2222-4333-8444-5555555555e1"))
        XCTAssertEqual(decoded.costs.first?.isCurrent, false)
        XCTAssertEqual(decoded.recordedCostTotal, 0)
    }

    func testSupplierListRemembersTheLastNameAndKeepsAnEditedName() {
        var directory = LivestockSupplierDirectory()
        directory.remember("  Valley  Mill ")
        directory.remember("valley mill")
        XCTAssertEqual(directory.names, ["valley mill"])
        XCTAssertEqual(directory.last, "valley mill")
        directory.remember("North Hay")
        XCTAssertEqual(directory.last, "North Hay")
        directory.remember("Valley Mill Co")
        XCTAssertEqual(directory.last, "Valley Mill Co")
        XCTAssertEqual(directory.names, ["North Hay", "valley mill", "Valley Mill Co"])
        let earlier = Date(timeIntervalSince1970: 1)
        let later = Date(timeIntervalSince1970: 2)
        let animal = Animal(
            id: UUID(),
            displayName: "Aster",
            species: .cattle,
            productionType: .beef,
            breed: nil,
            identifiers: [],
            consumptions: [
                LivestockConsumption(
                    id: UUID(),
                    inputType: .hay,
                    quantity: "1",
                    unit: .bale,
                    observedAt: earlier,
                    supplier: "Old Barn",
                    batch: nil
                ),
                LivestockConsumption(
                    id: UUID(),
                    inputType: .corn,
                    quantity: "2",
                    unit: .scoop,
                    observedAt: later,
                    supplier: "River Feed",
                    batch: "B-1"
                ),
            ],
            status: "Active"
        )
        var local = LivestockSupplierDirectory()
        local.remember("Kept Local")
        let merged = local.merging(animals: [animal])
        XCTAssertEqual(merged.last, "Kept Local")
        XCTAssertEqual(merged.names, ["Kept Local", "Old Barn", "River Feed"])
        let herd = LivestockHerd(
            id: UUID(),
            name: "North pasture",
            consumptions: [
                LivestockConsumption(
                    id: UUID(),
                    inputType: .hay,
                    quantity: "4",
                    unit: .bale,
                    observedAt: later,
                    supplier: "Herd Mill",
                    batch: nil
                )
            ]
        )
        let withHerd = local.merging(animals: [animal], herds: [herd])
        XCTAssertEqual(withHerd.names, ["Herd Mill", "Kept Local", "Old Barn", "River Feed"])
        XCTAssertEqual(withHerd.last, "Kept Local")
        XCTAssertEqual(
            LivestockConsumption(
                id: UUID(),
                inputType: .hay,
                quantity: "4",
                unit: .bale,
                observedAt: later,
                supplier: "  Herd Mill  ",
                batch: "B-9",
                frequency: .daily
            ).summary,
            "Hay 4 Bale · Daily · Herd Mill"
        )
        XCTAssertEqual(
            LivestockConsumption(
                id: UUID(),
                inputType: .hay,
                quantity: "4",
                unit: .bale,
                observedAt: later,
                supplier: nil,
                batch: nil,
                frequency: .daily
            ).summary,
            "Hay 4 Bale · Daily"
        )
        let defaults = UserDefaults(suiteName: "RanchOSLivestock.supplier-test")!
        defaults.removePersistentDomain(forName: "RanchOSLivestock.supplier-test")
        merged.save(defaults: defaults)
        XCTAssertEqual(LivestockSupplierDirectory.load(defaults: defaults), merged)
        defaults.removePersistentDomain(forName: "RanchOSLivestock.supplier-test")
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

    func testPackageNamerReadsTheLabelAndIgnoresBarcodeDigits() {
        let named = LivestockProductNamer.draft(
            from: LivestockPackageReading(
                barcode: "00123456789012",
                labelText: """
                00123456789012
                Purina Cattle Cubes
                Net Wt 50 lb
                Ingredients: corn, molasses
                """
            ),
            category: .feed,
            feedChoices: LivestockInputType.herdChoices
        )
        XCTAssertEqual(named.name, "Purina Cattle Cubes")
        XCTAssertEqual(named.source, .labelText)
        XCTAssertEqual(named.feedType, .preparedMeal)
    }

    func testPackageNamerDoesNotInventANameFromBarcodeDigitsAlone() {
        let named = LivestockProductNamer.draft(
            from: LivestockPackageReading(barcode: "012345678901", labelText: "012345678901"),
            category: .vaccination,
            feedChoices: []
        )
        XCTAssertEqual(named, .unnamed)
    }

    func testPackageNamerGuessesMedicineKindFromTheLabel() {
        let named = LivestockProductNamer.draft(
            from: LivestockPackageReading(
                barcode: "987654321098",
                labelText: "Ivermectin Paste 1.87%\nApple flavor"
            ),
            category: .medication,
            feedChoices: []
        )
        XCTAssertEqual(named.name, "Ivermectin Paste 1.87%")
        XCTAssertEqual(named.kind, "Paste")
    }

    func testScannedProductStaysInTheListUntilChosen() {
        var directory = LivestockProductDirectory()
        directory.remember(LivestockProduct(category: .vaccination, name: "Triangle 10", barcode: "123"))
        XCTAssertEqual(directory.products(in: .vaccination).map(\.name), ["Triangle 10"])
        XCTAssertEqual(directory.product(barcode: "123", in: .vaccination)?.name, "Triangle 10")
    }

    func testBreedingTreeShowsSireDamMateAndOffspring() {
        let sire = cattle("Duke")
        let dam = cattle("Aster")
        let calf = cattle("Briar", sire: sire.id, dam: dam.id)
        let cow = cattle("Maple", mate: sire.id)
        let among = [sire, dam, calf, cow]
        let tree = LivestockBreeding.tree(for: calf, among: among)
        XCTAssertEqual(tree.sire?.name, "Duke")
        XCTAssertEqual(tree.dam?.name, "Aster")
        XCTAssertEqual(LivestockBreeding.offspring(of: sire.id, among: among).map(\.displayName), ["Briar"])
        XCTAssertEqual(LivestockBreeding.currentMates(of: sire.id, among: among).map(\.displayName), ["Maple"])
        XCTAssertNil(
            LivestockBreeding.problem(
                animal: cow,
                sireID: nil,
                damID: nil,
                bredWithID: sire.id,
                among: among
            )
        )
        XCTAssertEqual(
            LivestockBreeding.problem(
                animal: calf,
                sireID: calf.id,
                damID: nil,
                bredWithID: nil,
                among: among
            ),
            "An animal cannot be its own sire."
        )
        XCTAssertEqual(
            LivestockBreeding.problem(
                animal: sire,
                sireID: calf.id,
                damID: nil,
                bredWithID: nil,
                among: among
            ),
            "Sire cannot be a descendant of this animal."
        )
        let nim = cattle("Nim", species: .goat)
        XCTAssertEqual(
            LivestockBreeding.problem(
                animal: dam,
                sireID: nil,
                damID: nil,
                bredWithID: nim.id,
                among: among + [nim]
            ),
            "The animal they are bred with must be the same species."
        )
    }

    func testOnDeviceNamerFallsBackWhenTheModelReturnsNothing() async {
        let named = await LivestockProductNamer.name(
            LivestockPackageReading(barcode: "1", labelText: "Alfalfa Hay Bales\nNet Wt 90 lb"),
            category: .feed,
            feedChoices: LivestockInputType.herdChoices,
            using: LivestockSilentProductNamer()
        )
        XCTAssertEqual(named.name, "Alfalfa Hay Bales")
        XCTAssertEqual(named.feedType, .alfalfaHay)
        XCTAssertEqual(named.source, .labelText)
    }
}

private func cattle(
    _ name: String,
    id: UUID = UUID(),
    species: Species = .cattle,
    sire: UUID? = nil,
    dam: UUID? = nil,
    mate: UUID? = nil
) -> Animal {
    Animal(
        id: id,
        displayName: name,
        species: species,
        productionType: .breeding,
        breed: nil,
        identifiers: [],
        sireID: sire,
        damID: dam,
        bredWithID: mate,
        status: "Active"
    )
}

private struct LivestockSilentProductNamer: LivestockOnDeviceProductNaming {
    func name(
        from _: LivestockPackageReading,
        category _: LivestockProductCategory,
        feedChoices _: [LivestockInputType]
    ) async -> LivestockNamedProduct? {
        nil
    }
}

private struct StaticAuthorizedRead: LivestockAuthorizedReadProvider {
    let page: LivestockAuthorizedAnimalPage

    func readAnimals() async throws -> LivestockAuthorizedAnimalPage {
        page
    }
}

private final class SequentialAuthorizedRead: LivestockAuthorizedReadProvider, @unchecked Sendable {
    private var remaining: [Result<LivestockAuthorizedAnimalPage, Error>]

    init(_ remaining: [Result<LivestockAuthorizedAnimalPage, Error>]) {
        self.remaining = remaining
    }

    func readAnimals() async throws -> LivestockAuthorizedAnimalPage {
        guard !remaining.isEmpty else { throw LivestockDevReadError.refused }
        return try remaining.removeFirst().get()
    }
}

private struct MessageLivestockReadProvider: LivestockAuthorizedReadProvider {
    func readAnimals() async throws -> LivestockAuthorizedAnimalPage {
        throw LivestockDevReadError.unavailable(LivestockDevLoopbackRead.serverNotRunningMessage)
    }
}
