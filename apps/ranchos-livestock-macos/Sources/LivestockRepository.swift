import Foundation
import Observation

protocol LivestockReadModel: Sendable {
    func herdOverview(context: FixturePresentationContext) async throws -> HerdOverview
    func animals(context: FixturePresentationContext) async throws -> [Animal]
}

/// Placeholder only; no live identity transport is deployed for this app.
protocol VerifiedPrincipalProvider: Sendable {
    func verifiedPrincipal() async throws -> Never
}

enum FutureLiveIntegrationError: LocalizedError {
    case notDeployed

    var errorDescription: String? {
        "Live tenant integration is not deployed. DEV fixture data remains local presentation only."
    }
}

struct UnavailableVerifiedPrincipalProvider: VerifiedPrincipalProvider {
    func verifiedPrincipal() async throws -> Never {
        throw FutureLiveIntegrationError.notDeployed
    }
}

enum FixtureReadModelError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Authorized LivestockReadModel data is not connected in this DEV fixture." }
}

struct FixtureLivestockReadModel: LivestockReadModel {
    static let fixtureAnimals: [Animal] = [
        Animal(
            id: UUID(uuidString: "2FB6AA84-374C-4EE1-9D94-6A4CD8E80F52")!,
            displayName: "Juniper",
            species: .cattle,
            productionType: .beef,
            breed: LivestockCatalog.breeds.first { $0.code == "angus" },
            identifiers: [LivestockAnimalIdentifier(id: UUID(uuidString: "A1111111-2222-4333-8444-555555555551")!, kind: .earTag, value: "RB-104")],
            status: "Active"
        ),
        Animal(
            id: UUID(uuidString: "D57C4765-C890-4A2B-8B6F-7C87F0C60DF2")!,
            displayName: "Cedar",
            species: .goat,
            productionType: .dairy,
            breed: LivestockCatalog.breeds.first { $0.code == "boer" },
            identifiers: [LivestockAnimalIdentifier(id: UUID(uuidString: "A1111111-2222-4333-8444-555555555552")!, kind: .earTag, value: "G-18")],
            status: "Active"
        ),
    ]

    func herdOverview(context: FixturePresentationContext) async throws -> HerdOverview {
        HerdOverview.from(animals: Self.fixtureAnimals)
    }

    func animals(context: FixturePresentationContext) async throws -> [Animal] {
        Self.fixtureAnimals
    }
}

enum LivestockRecordOrigin: Equatable, Sendable {
    case fixture
    case live
}

struct LivestockAuthorizedAnimalPage: Equatable, Sendable {
    let origin: LivestockRecordOrigin
    let animals: [Animal]
    var herds: [LivestockHerd] = []
}

protocol LivestockAuthorizedReadProvider: Sendable {
    func readAnimals() async throws -> LivestockAuthorizedAnimalPage
}

enum LivestockReadRequestMethod: String, CaseIterable, Sendable {
    case get = "GET"

    var isWrite: Bool { false }
}

enum LivestockReadSession: Equatable, Sendable {
    case unavailable(String)
    case fixture([Animal])
    case readOnly([Animal])
    case cancelled

    var isLive: Bool {
        if case .readOnly = self { return true }
        return false
    }

    var canOpenFixtureSession: Bool {
        switch self {
        case .unavailable, .cancelled: true
        case .fixture, .readOnly: false
        }
    }

    var banner: String {
        switch self {
        case .unavailable(let message): message
        case .fixture: FixturePresentationBoundary.tenantDisclosure
        case .readOnly: LivestockReadConnection.liveReadOnlyLabel
        case .cancelled: LivestockReadConnection.unavailableMessage
        }
    }

    var statusTitle: String {
        switch self {
        case .readOnly: "Live DEV read"
        case .fixture: "Sample session"
        case .unavailable, .cancelled: "No animals loaded"
        }
    }

    var statusDetail: String {
        switch self {
        case .readOnly:
            "These animals are stored in the DEV database. Tags, lifecycle, care, feed, and cost can be saved. Species, production type, and breed stay as recorded."
        case .fixture:
            "Juniper and Cedar can be edited here. Changes stay on this screen until you quit."
        case .unavailable, .cancelled:
            "The live read is unavailable. Open the sample session to edit Juniper and Cedar."
        }
    }

    var statusFooter: String {
        switch self {
        case .readOnly: "Tags, lifecycle, care, feed, and cost save in the DEV database."
        case .fixture: "Sample session. Nothing is written to a database."
        case .unavailable, .cancelled: "The live read is unavailable."
        }
    }
}

/// Read-only Livestock DEV connection. No endpoint, credentials, or write verb.
struct LivestockReadConnection: Sendable {
    static let unavailableMessage = "The authorized Livestock read API is not available."
    static let liveReadOnlyLabel = "Live DEV data · read only. Ranch OS Livestock cannot change records."
    static let fixtureAsLiveMessage = "Fixture data cannot be presented as a live DEV read."
    static let writeRequestMethods: [String] = []
    static let prohibitedRequestMethods = ["POST", "PUT", "PATCH", "DELETE"]

    private let authorizedProvider: (any LivestockAuthorizedReadProvider)?

    init(authorizedProvider: (any LivestockAuthorizedReadProvider)? = nil) {
        self.authorizedProvider = authorizedProvider
    }

    var hasAuthorizedProvider: Bool { authorizedProvider != nil }

    func resolve() async -> LivestockReadSession {
        let (session, _) = await resolveLoaded()
        return session
    }

    func resolveLoaded() async -> (LivestockReadSession, [LivestockHerd]) {
        guard let authorizedProvider else {
            return (.unavailable(Self.unavailableMessage), [])
        }
        do {
            try Task.checkCancellation()
            let page = try await authorizedProvider.readAnimals()
            try Task.checkCancellation()
            guard page.origin == .live else {
                return (.unavailable(Self.fixtureAsLiveMessage), [])
            }
            let fixtureIDs = Set(FixtureLivestockReadModel.fixtureAnimals.map(\.id))
            guard page.animals.allSatisfy({ animal in
                !fixtureIDs.contains(animal.id) && LivestockCatalog.acceptsSpeciesCode(animal.species.rawValue)
            }) else {
                return (.unavailable(Self.fixtureAsLiveMessage), [])
            }
            return (.readOnly(page.animals), page.herds)
        } catch is CancellationError {
            return (.cancelled, [])
        } catch {
            if Task.isCancelled { return (.cancelled, []) }
            return (.unavailable(Self.unavailableMessage), [])
        }
    }
}

@MainActor
@Observable final class LivestockStore {
    let fixtureContext: FixturePresentationContext
    private let readModel: any LivestockReadModel
    private let connection: LivestockReadConnection
    let fixtureWriteRole: LivestockFixtureWriteRole
    let liveRecords: LivestockDevLoopbackRead?
    var session: LivestockReadSession = .unavailable(LivestockReadConnection.unavailableMessage)
    var overview: HerdOverview?
    var animals: [Animal] = []
    var herds: [LivestockHerd] = []
    var overviewState: FixtureLoadState = .loading
    var animalsState: FixtureLoadState = .loading
    var selectedAnimalID: Animal.ID?
    var saveNotice: LivestockSaveNotice?

    init(
        fixtureContext: FixturePresentationContext = .preview,
        readModel: any LivestockReadModel = FixtureLivestockReadModel(),
        connection: LivestockReadConnection = LivestockReadConnection(),
        fixtureWriteRole: LivestockFixtureWriteRole = .owner,
        liveRecords: LivestockDevLoopbackRead? = nil
    ) {
        self.fixtureContext = fixtureContext
        self.readModel = readModel
        self.connection = connection
        self.fixtureWriteRole = fixtureWriteRole
        self.liveRecords = liveRecords
    }

    var canEditStoredAnimal: Bool {
        guard fixtureWriteRole.canAssignIdentifier else { return false }
        if case .fixture = session { return true }
        return session.isLive && liveRecords != nil
    }

    func loadFixtures() async {
        do {
            let loadedAnimals = try await readModel.animals(context: fixtureContext)
            let loadedOverview = try await readModel.herdOverview(context: fixtureContext)
            guard loadedOverview.animalCount == loadedAnimals.count else {
                throw FixtureReadModelError.unavailable
            }
            session = .fixture(loadedAnimals)
            herds = []
            overview = loadedOverview
            overviewState = .loaded
            animals = loadedAnimals
            animalsState = loadedAnimals.isEmpty ? .empty(message: "No fixture animals are available.") : .loaded
            selectedAnimalID = loadedAnimals.first?.id
        } catch {
            session = .unavailable(error.localizedDescription)
            overview = nil
            animals = []
            overviewState = .error(message: error.localizedDescription)
            animalsState = .error(message: error.localizedDescription)
            selectedAnimalID = nil
        }
    }

    func loadAuthorizedRead(keeping selection: Animal.ID? = nil) async {
        let (resolved, loadedHerds) = await connection.resolveLoaded()
        session = resolved
        switch resolved {
        case .readOnly(let loadedAnimals):
            herds = loadedHerds
            overview = HerdOverview.from(animals: loadedAnimals)
            overviewState = .loaded
            animals = loadedAnimals
            animalsState = loadedAnimals.isEmpty ? .empty(message: "No authorized animals are available.") : .loaded
            if let selection, loadedAnimals.contains(where: { $0.id == selection }) {
                selectedAnimalID = selection
            } else {
                selectedAnimalID = loadedAnimals.first?.id
            }
        case .unavailable, .cancelled:
            let message = resolved.banner
            overview = nil
            animals = []
            herds = []
            overviewState = .error(message: message)
            animalsState = .error(message: message)
            selectedAnimalID = nil
        case .fixture:
            overview = nil
            animals = []
            herds = []
            overviewState = .error(message: LivestockReadConnection.fixtureAsLiveMessage)
            animalsState = .error(message: LivestockReadConnection.fixtureAsLiveMessage)
            selectedAnimalID = nil
        }
    }

    /// Session memory only. A fixture owner or manager can append an animal. Nothing is written to disk or a database.
    func createFixtureAnimal(_ draft: AddAnimalDraft) -> LivestockCreateAnimalResult {
        guard case .fixture = session else {
            return .rejected(FixturePresentationBoundary.createUnavailableBoundary)
        }
        guard fixtureWriteRole.canCreateAnimal else {
            return .rejected(FixturePresentationBoundary.viewerCannotCreateBoundary)
        }
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .rejected(FixturePresentationBoundary.createNeedsNameBoundary)
        }
        guard draft.isValidCatalogSelection, let species = draft.species, let productionType = draft.productionType else {
            return .rejected(FixturePresentationBoundary.rejectedSpeciesBoundary)
        }
        let animal = Animal(
            id: UUID(),
            displayName: name,
            species: species,
            productionType: productionType,
            breed: draft.breed,
            identifiers: [],
            recordedBreed: draft.recordedPetBreed,
            mixBreedOne: draft.petBreedChoice == "mixed" ? draft.mixBreedOne.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            mixBreedTwo: draft.petBreedChoice == "mixed" ? draft.mixBreedTwo.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            petKind: draft.petKind,
            petSpeciesOther: draft.petKind == .other ? draft.petSpeciesOther.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            status: "Active"
        )
        animals.append(animal)
        session = .fixture(animals)
        overview = HerdOverview.from(animals: animals)
        overviewState = .loaded
        animalsState = .loaded
        selectedAnimalID = animal.id
        return .created(animal)
    }

    func createAnimal(_ draft: AddAnimalDraft) async -> LivestockCreateAnimalResult {
        if draft.category == .pets, draft.species != .pet {
            return .rejected("A pet must use the Pets species.")
        }
        if draft.category == .liveStock, draft.species == .pet {
            return .rejected("Live Stock does not include pets.")
        }
        if let problem = draft.petFormProblem {
            return .rejected(problem)
        }
        if case .fixture = session {
            return createFixtureAnimal(draft)
        }
        guard let liveRecords, session.isLive, fixtureWriteRole.canCreateAnimal else {
            return .rejected(FixturePresentationBoundary.createUnavailableBoundary)
        }
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .rejected(FixturePresentationBoundary.createNeedsNameBoundary)
        }
        guard draft.isValidCatalogSelection, let species = draft.species, let productionType = draft.productionType else {
            return .rejected(FixturePresentationBoundary.rejectedSpeciesBoundary)
        }
        do {
            let id = try await liveRecords.createAnimal(
                displayName: name,
                species: species,
                productionType: productionType,
                breed: draft.breed,
                petBreed: draft.recordedPetBreed ?? "",
                mixBreedOne: draft.petBreedChoice == "mixed" ? draft.mixBreedOne : "",
                mixBreedTwo: draft.petBreedChoice == "mixed" ? draft.mixBreedTwo : "",
                petSpecies: draft.petKind?.rawValue ?? "",
                petSpeciesOther: draft.petKind == .other ? draft.petSpeciesOther : ""
            )
            await reloadLiveAnimal(id)
            return .created(Animal(
                id: id,
                displayName: name,
                species: species,
                productionType: productionType,
                breed: draft.breed,
                identifiers: [],
                recordedBreed: draft.recordedPetBreed,
                mixBreedOne: draft.petBreedChoice == "mixed" ? draft.mixBreedOne.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                mixBreedTwo: draft.petBreedChoice == "mixed" ? draft.mixBreedTwo.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                petKind: draft.petKind,
                petSpeciesOther: draft.petKind == .other ? draft.petSpeciesOther.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                status: "Active"
            ))
        } catch {
            return .rejected(errorText(error))
        }
    }

    /// Session memory only. Retired values may be assigned again. Nothing is written to disk or a database.
    func assignFixtureIdentifier(animalID: Animal.ID, kind: LivestockIdentifierKind, value: String) -> LivestockIdentifierResult {
        guard case .fixture = session else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .rejected(FixturePresentationBoundary.identifierNeedsValueBoundary)
        }
        guard let index = animals.firstIndex(where: { $0.id == animalID }) else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        if activeIdentifierCollision(kind: kind, value: normalized) {
            return .rejected(FixturePresentationBoundary.identifierActiveCollisionBoundary)
        }
        let assigned = LivestockAnimalIdentifier(id: UUID(), kind: kind, value: normalized, retirementReason: nil)
        animals[index] = animals[index].replacingIdentifiers(animals[index].identifiers + [assigned])
        session = .fixture(animals)
        return .assigned(assigned)
    }

    func retireFixtureIdentifier(
        animalID: Animal.ID,
        identifierID: UUID,
        reason: LivestockIdentifierRetirementReason
    ) -> LivestockIdentifierResult {
        guard case .fixture = session else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        }
        guard let animalIndex = animals.firstIndex(where: { $0.id == animalID }),
              let identifierIndex = animals[animalIndex].identifiers.firstIndex(where: { $0.id == identifierID })
        else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        let current = animals[animalIndex].identifiers[identifierIndex]
        guard current.isActive else {
            return .rejected(FixturePresentationBoundary.identifierAlreadyRetiredBoundary)
        }
        let retired = LivestockAnimalIdentifier(
            id: current.id,
            kind: current.kind,
            value: current.value,
            retirementReason: reason
        )
        var identifiers = animals[animalIndex].identifiers
        identifiers[identifierIndex] = retired
        animals[animalIndex] = animals[animalIndex].replacingIdentifiers(identifiers)
        session = .fixture(animals)
        return .retired(retired)
    }

    func retireFixtureAnimal(
        animalID: Animal.ID,
        reason: LivestockIdentifierRetirementReason,
        saleAmount: Decimal? = nil,
        saleOn: Date? = nil
    ) -> LivestockIdentifierResult {
        guard case .fixture = session else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        }
        guard let animalIndex = animals.firstIndex(where: { $0.id == animalID }) else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard !animals[animalIndex].isRetired else {
            return .rejected(FixturePresentationBoundary.identifierAlreadyRetiredBoundary)
        }
        let retiredAt = Date()
        animals[animalIndex] = animals[animalIndex].retiring(reason: reason, at: retiredAt, saleAmount: saleAmount, saleOn: saleOn)
        session = .fixture(animals)
        let kind: LivestockIdentifierKind = animals[animalIndex].species == .pet ? .license : .earTag
        return .retired(LivestockAnimalIdentifier(id: animalID, kind: kind, value: "", retirementReason: reason, retiredAt: retiredAt))
    }

    /// Session memory only. Events append in occurred-time order. Nothing is written to disk or a database.
    func recordFixtureLifecycleEvent(
        animalID: Animal.ID,
        type: LivestockLifecycleEventType,
        occurredAt: Date
    ) -> LivestockLifecycleResult {
        guard case .fixture = session else {
            return .rejected(FixturePresentationBoundary.lifecycleUnavailableBoundary)
        }
        guard fixtureWriteRole.canRecordLifecycle else {
            return .rejected(FixturePresentationBoundary.viewerCannotRecordLifecycleBoundary)
        }
        guard let index = animals.firstIndex(where: { $0.id == animalID }) else {
            return .rejected(FixturePresentationBoundary.lifecycleUnavailableBoundary)
        }
        if let latest = animals[index].lifecycleEvents.map(\.occurredAt).max(), occurredAt <= latest {
            return .rejected(FixturePresentationBoundary.lifecycleOrderBoundary)
        }
        let recorded = LivestockLifecycleEvent(id: UUID(), type: type, occurredAt: occurredAt)
        animals[index] = animals[index].replacingLifecycleEvents(animals[index].lifecycleEvents + [recorded])
        session = .fixture(animals)
        return .recorded(recorded)
    }

    func assignIdentifier(animalID: Animal.ID, kind: LivestockIdentifierKind, value: String) async -> LivestockIdentifierResult {
        if case .fixture = session {
            return assignFixtureIdentifier(animalID: animalID, kind: kind, value: value)
        }
        guard let liveRecords, session.isLive else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        }
        do {
            try await liveRecords.assignIdentifier(animalID: animalID, kind: kind, value: value)
            await reloadLiveAnimal(animalID)
            return .assigned(LivestockAnimalIdentifier(id: UUID(), kind: kind, value: value.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            return .rejected(errorText(error))
        }
    }

    func retireAnimal(
        animalID: Animal.ID,
        reason: LivestockIdentifierRetirementReason,
        saleAmount: String? = nil,
        saleOn: Date? = nil
    ) async -> LivestockIdentifierResult {
        let soldAmount = reason == .sold ? LivestockMoney.decimal(saleAmount ?? "") : nil
        if reason == .sold {
            guard let saleOn else { return .rejected("A sale needs a date.") }
            if let problem = LivestockMoney.requirement(saleAmount ?? "", label: "Sale amount", allowZero: true) {
                return .rejected(problem)
            }
        }
        if case .fixture = session {
            return retireFixtureAnimal(
                animalID: animalID,
                reason: reason,
                saleAmount: soldAmount,
                saleOn: reason == .sold ? saleOn : nil
            )
        }
        guard let liveRecords, session.isLive else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        }
        do {
            try await liveRecords.retireAnimal(
                animalID: animalID,
                reason: reason,
                saleAmount: reason == .sold ? LivestockMoney.amountText(saleAmount ?? "") : nil,
                saleOn: reason == .sold ? saleOn : nil
            )
            if let index = animals.firstIndex(where: { $0.id == animalID }) {
                animals[index] = animals[index].retiring(
                    reason: reason,
                    at: Date(),
                    saleAmount: soldAmount,
                    saleOn: reason == .sold ? saleOn : nil
                )
                selectedAnimalID = animalID
            }
            await reloadLiveAnimal(animalID)
            let kind: LivestockIdentifierKind = animals.first { $0.id == animalID }?.species == .pet ? .license : .earTag
            return .retired(LivestockAnimalIdentifier(id: animalID, kind: kind, value: "", retirementReason: reason))
        } catch {
            return .rejected(errorText(error))
        }
    }

    func updateClassification(animalID: Animal.ID, production: ProductionType, breed: Breed?) async -> String {
        guard let index = animals.firstIndex(where: { $0.id == animalID }) else {
            return "The animal was not found."
        }
        let current = animals[index]
        guard current.species != .pet else {
            return "A pet does not have a livestock production type or breed."
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.viewerCannotAssignBoundary
        }
        let allowedProduction = LivestockCatalog.productionChoices(for: current.species, including: current.productionType)
        guard allowedProduction.contains(production) else {
            return "Production type is not accepted."
        }
        if let breed, !LivestockCatalog.breedChoices(for: current.species, including: current.breed).contains(breed) {
            return "Breed is not accepted for that species."
        }
        if case .fixture = session {
            animals[index] = current.replacingClassification(productionType: production, breed: breed)
            session = .fixture(animals)
            return "Production type and breed saved."
        }
        guard let liveRecords, session.isLive else {
            return FixturePresentationBoundary.identifierUnavailableBoundary
        }
        do {
            try await liveRecords.updateClassification(animalID: animalID, production: production, breed: breed)
            await reloadLiveAnimal(animalID)
            return "Production type and breed saved to the DEV database."
        } catch {
            return errorText(error)
        }
    }

    func createHerd(name: String, notes: String = "") async -> String {
        let cleaned = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let recordedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 80 else { return "Herd name is required." }
        guard recordedNotes.count <= 2000 else { return "Other information is too long." }
        guard fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.viewerCannotAssignBoundary
        }
        if herds.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return "That herd name is already used."
        }
        if case .fixture = session {
            herds.append(LivestockHerd(id: UUID(), name: cleaned, notes: recordedNotes))
            herds.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return "Herd saved."
        }
        guard let liveRecords, session.isLive else {
            return FixturePresentationBoundary.identifierUnavailableBoundary
        }
        do {
            try await liveRecords.createHerd(name: cleaned, notes: recordedNotes)
            await reloadLiveAnimal(selectedAnimalID ?? animals.first?.id ?? UUID())
            return "Herd saved to the DEV database."
        } catch {
            return errorText(error)
        }
    }

    func assignHerd(animalID: Animal.ID, herdID: UUID) async -> String {
        guard let herd = herds.first(where: { $0.id == herdID }), !herd.isRetired else { return "That herd was not found." }
        guard let index = animals.firstIndex(where: { $0.id == animalID }) else { return "The animal was not found." }
        let current = animals[index]
        guard current.herdID != herdID else { return "This animal is already in that herd." }
        guard fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.viewerCannotAssignBoundary
        }
        if case .fixture = session {
            animals[index] = current.assigningHerd(id: herd.id, name: herd.name, at: Date())
            session = .fixture(animals)
            overview = HerdOverview.from(animals: animals)
            return "Herd assigned."
        }
        guard let liveRecords, session.isLive else {
            return FixturePresentationBoundary.identifierUnavailableBoundary
        }
        do {
            try await liveRecords.assignHerd(animalID: animalID, herdID: herdID)
            await reloadLiveAnimal(animalID)
            return "Herd assigned in the DEV database."
        } catch {
            return errorText(error)
        }
    }

    func clearHerd(animalID: Animal.ID) async -> String {
        guard let index = animals.firstIndex(where: { $0.id == animalID }) else { return "The animal was not found." }
        guard animals[index].herdID != nil else { return "This animal is already unassigned." }
        guard fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.viewerCannotAssignBoundary
        }
        if case .fixture = session {
            animals[index] = animals[index].clearingHerd()
            session = .fixture(animals)
            overview = HerdOverview.from(animals: animals)
            return "Herd cleared."
        }
        guard let liveRecords, session.isLive else {
            return FixturePresentationBoundary.identifierUnavailableBoundary
        }
        do {
            try await liveRecords.clearHerd(animalID: animalID)
            await reloadLiveAnimal(animalID)
            return "Herd cleared in the DEV database."
        } catch {
            return errorText(error)
        }
    }

    func retireHerd(herdID: UUID) async -> String {
        guard let index = herds.firstIndex(where: { $0.id == herdID }) else { return "That herd was not found." }
        guard !herds[index].isRetired else { return "That herd has already been retired." }
        guard !animals.contains(where: { $0.herdID == herdID }) else {
            return "Reassign or unassign every animal before retiring this herd."
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.viewerCannotAssignBoundary
        }
        if case .fixture = session {
            herds[index].retiredAt = Date()
            return "Herd retired."
        }
        guard let liveRecords, session.isLive else {
            return FixturePresentationBoundary.identifierUnavailableBoundary
        }
        do {
            let retiredName = herds[index].name
            let retiredNotes = herds[index].notes
            try await liveRecords.retireHerd(herdID: herdID)
            await reloadLiveAnimal(selectedAnimalID ?? animals.first?.id ?? UUID())
            if let refreshed = herds.firstIndex(where: { $0.id == herdID }) {
                if herds[refreshed].retiredAt == nil {
                    herds[refreshed].retiredAt = Date()
                }
            } else {
                herds.append(LivestockHerd(id: herdID, name: retiredName, notes: retiredNotes, retiredAt: Date()))
                herds.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            return "Herd retired in the DEV database."
        } catch {
            return errorText(error)
        }
    }

    func retireIdentifier(animalID: Animal.ID, identifierID: UUID, reason: LivestockIdentifierRetirementReason) async -> LivestockIdentifierResult {
        if case .fixture = session {
            return retireFixtureIdentifier(animalID: animalID, identifierID: identifierID, reason: reason)
        }
        guard let liveRecords, session.isLive else {
            return .rejected(FixturePresentationBoundary.identifierUnavailableBoundary)
        }
        guard fixtureWriteRole.canAssignIdentifier else {
            return .rejected(FixturePresentationBoundary.viewerCannotAssignBoundary)
        }
        do {
            try await liveRecords.retireIdentifier(animalID: animalID, identifierID: identifierID, reason: reason)
            await reloadLiveAnimal(animalID)
            return .retired(LivestockAnimalIdentifier(id: identifierID, kind: .earTag, value: "", retirementReason: reason))
        } catch {
            return .rejected(errorText(error))
        }
    }

    func recordLifecycleEvent(animalID: Animal.ID, type: LivestockLifecycleEventType, occurredAt: Date) async -> LivestockLifecycleResult {
        if case .fixture = session {
            return recordFixtureLifecycleEvent(animalID: animalID, type: type, occurredAt: occurredAt)
        }
        guard let liveRecords, session.isLive else {
            return .rejected(FixturePresentationBoundary.lifecycleUnavailableBoundary)
        }
        guard fixtureWriteRole.canRecordLifecycle else {
            return .rejected(FixturePresentationBoundary.viewerCannotRecordLifecycleBoundary)
        }
        do {
            try await liveRecords.recordLifecycle(animalID: animalID, type: type, occurredAt: occurredAt)
            await reloadLiveAnimal(animalID)
            return .recorded(LivestockLifecycleEvent(id: UUID(), type: type, occurredAt: occurredAt))
        } catch {
            return .rejected(errorText(error))
        }
    }

    func recordCareEvent(animalID: Animal.ID, type: LivestockCareEventType, occurredAt: Date, confirmed: Bool) async -> String {
        guard let liveRecords, session.isLive, fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.lifecycleUnavailableBoundary
        }
        do {
            try await liveRecords.recordCare(animalID: animalID, type: type, occurredAt: occurredAt, confirmed: confirmed)
            await reloadLiveAnimal(animalID)
            return FixturePresentationBoundary.databaseWriteBoundary
        } catch {
            return errorText(error)
        }
    }

    func recordConsumptionEvent(
        animalID: Animal.ID,
        inputType: LivestockInputType,
        quantity: String,
        unit: LivestockInputUnit,
        observedAt: Date,
        supplier: String,
        batch: String,
        frequency: LivestockCostFrequency = .daily
    ) async -> String {
        guard let liveRecords, session.isLive, fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.lifecycleUnavailableBoundary
        }
        do {
            try await liveRecords.recordConsumption(
                animalID: animalID,
                inputType: inputType,
                quantity: quantity,
                unit: unit,
                observedAt: observedAt,
                supplier: supplier,
                batch: batch,
                frequency: frequency
            )
            await reloadLiveAnimal(animalID)
            return FixturePresentationBoundary.databaseWriteBoundary
        } catch {
            return errorText(error)
        }
    }

    func recordCostEvent(animalID: Animal.ID, amount: String, financeReference: String, confirmed: Bool) async -> String {
        guard let liveRecords, session.isLive, fixtureWriteRole.canAssignIdentifier else {
            return FixturePresentationBoundary.lifecycleUnavailableBoundary
        }
        do {
            try await liveRecords.recordCost(animalID: animalID, amount: amount, financeReference: financeReference, confirmed: confirmed)
            await reloadLiveAnimal(animalID)
            return FixturePresentationBoundary.databaseWriteBoundary
        } catch {
            return errorText(error)
        }
    }

    private func reloadLiveAnimal(_ animalID: Animal.ID) async {
        let keptAnimals = animals
        let keptSession = session
        let keptHerds = herds
        let keptOverview = overview
        await loadAuthorizedRead(keeping: animalID)
        guard case .readOnly = session else {
            session = keptSession
            animals = keptAnimals
            herds = keptHerds
            overview = keptOverview
            animalsState = .loaded
            if keptOverview != nil { overviewState = .loaded }
            selectedAnimalID = animalID
            return
        }
        if animals.contains(where: { $0.id == animalID }) {
            selectedAnimalID = animalID
        }
    }

    func saveAnimalRecords(animalID: Animal.ID, draft: LivestockAnimalSaveDraft) async -> LivestockAnimalSaveResult {
        if draft.isEmpty {
            return posted(LivestockAnimalSaveResult(message: FixturePresentationBoundary.saveNeedsEntryBoundary), animalID: animalID)
        }
        if !fixtureWriteRole.canAssignIdentifier {
            return posted(LivestockAnimalSaveResult(message: FixturePresentationBoundary.viewerCannotAssignBoundary), animalID: animalID)
        }
        if let problem = draft.costProblem() {
            return posted(LivestockAnimalSaveResult(message: problem), animalID: animalID)
        }
        var result = LivestockAnimalSaveResult(message: "")
        if case .fixture = session {
            if draft.careType != nil || draft.hasFeedActivity || draft.wantsCost || draft.hasActivityCost {
                return posted(
                    LivestockAnimalSaveResult(message: "Care, feed, and cost save in the DEV database."),
                    animalID: animalID
                )
            }
            if draft.wantsIdentifier {
                let assigned = assignFixtureIdentifier(animalID: animalID, kind: draft.identifierKind, value: draft.identifierValue)
                if case .rejected(let message) = assigned {
                    result.message = saveFailure(saved: result.savedLabels, label: "Identifier", reason: message)
                    return posted(result, animalID: animalID)
                }
                result.savedIdentifier = true
            }
            if let lifecycleType = draft.lifecycleType {
                let recorded = recordFixtureLifecycleEvent(animalID: animalID, type: lifecycleType, occurredAt: draft.lifecycleAt)
                if case .rejected(let message) = recorded {
                    result.message = saveFailure(saved: result.savedLabels, label: "Lifecycle", reason: message)
                    return posted(result, animalID: animalID)
                }
                result.savedLifecycle = true
            }
            result.acceptedIdentifierCost = result.savedIdentifier
            result.message = "Saved in this sample session."
            return posted(result, animalID: animalID)
        }
        guard let liveRecords, session.isLive else {
            return posted(LivestockAnimalSaveResult(message: FixturePresentationBoundary.lifecycleUnavailableBoundary), animalID: animalID)
        }
        var step = "Save"
        do {
            if draft.wantsIdentifier {
                step = "Identifier"
                try await liveRecords.assignIdentifier(animalID: animalID, kind: draft.identifierKind, value: draft.identifierValue)
                result.savedIdentifier = true
            }
            if draft.wantsIdentifier || LivestockMoney.nonzeroText(draft.identifierCost) != nil {
                step = "Identifier cost"
                result.acceptedIdentifierCost = try await recordOptionalCost(liveRecords, animalID: animalID, amount: draft.identifierCost)
            }
            if let lifecycleType = draft.lifecycleType {
                step = "Lifecycle"
                try await liveRecords.recordLifecycle(animalID: animalID, type: lifecycleType, occurredAt: draft.lifecycleAt)
                result.savedLifecycle = true
            }
            if let careType = draft.careType {
                step = "Care"
                try await liveRecords.recordCare(
                    animalID: animalID,
                    type: careType,
                    occurredAt: draft.careAt,
                    confirmed: careType.needsConfirmation
                )
                result.savedCare = true
            }
            if draft.careType != nil || LivestockMoney.nonzeroText(draft.careCost) != nil {
                step = "Care cost"
                result.acceptedCareCost = try await recordOptionalCost(liveRecords, animalID: animalID, amount: draft.careCost)
            }
            for line in draft.feedLines where line.hasQuantity || LivestockMoney.nonzeroText(line.cost) != nil {
                if line.hasQuantity {
                    step = line.inputType.label
                    try await liveRecords.recordConsumption(
                        animalID: animalID,
                        inputType: line.inputType,
                        quantity: line.quantity,
                        unit: line.unit,
                        observedAt: draft.feedAt,
                        supplier: draft.supplier,
                        batch: draft.batch,
                        frequency: line.frequency
                    )
                    result.savedFeed = true
                }
                step = "\(line.inputType.label) cost"
                let accepted = try await recordOptionalCost(
                    liveRecords,
                    animalID: animalID,
                    amount: line.cost,
                    frequency: line.frequency,
                    feedType: line.inputType
                )
                result.acceptedFeedCost = result.acceptedFeedCost || accepted
            }
            if draft.wantsCost {
                step = "Cost"
                try await liveRecords.recordCost(
                    animalID: animalID,
                    amount: draft.costAmount,
                    financeReference: draft.financeReference,
                    confirmed: true
                )
                result.savedCost = true
            }
            await reloadLiveAnimal(animalID)
            result.message = FixturePresentationBoundary.databaseWriteBoundary
            return posted(result, animalID: animalID)
        } catch {
            if result.savedAnything {
                await reloadLiveAnimal(animalID)
            }
            result.message = saveFailure(saved: result.savedLabels, label: step, reason: errorText(error))
            return posted(result, animalID: animalID)
        }
    }

    private func posted(_ result: LivestockAnimalSaveResult, animalID: Animal.ID) -> LivestockAnimalSaveResult {
        let succeeded = result.message == FixturePresentationBoundary.databaseWriteBoundary
            || result.message == "Saved in this sample session."
        saveNotice = LivestockSaveNotice(animalID: animalID, message: result.message, succeeded: succeeded)
        return result
    }

    private func recordOptionalCost(
        _ liveRecords: LivestockDevLoopbackRead,
        animalID: Animal.ID,
        amount: String,
        frequency: LivestockCostFrequency? = nil,
        feedType: LivestockInputType? = nil
    ) async throws -> Bool {
        guard let amountText = LivestockMoney.nonzeroText(amount) else { return true }
        try await liveRecords.recordCost(
            animalID: animalID,
            amount: amountText,
            financeReference: "",
            confirmed: true,
            frequency: frequency,
            feedType: feedType
        )
        return true
    }

    private func saveFailure(saved: [String], label: String, reason: String) -> String {
        guard !saved.isEmpty else { return reason }
        return "Saved \(saved.joined(separator: ", ")). \(label) was not saved: \(reason)"
    }

    private func errorText(_ error: Error) -> String {
        if let message = (error as? LocalizedError)?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        return "The DEV livestock database did not save the change."
    }

    private func activeIdentifierCollision(kind: LivestockIdentifierKind, value: String) -> Bool {
        let key = LivestockIdentifierComparison.key(value)
        return animals.contains { animal in
            animal.identifiers.contains { item in
                item.isActive && item.kind == kind && LivestockIdentifierComparison.key(item.value) == key
            }
        }
    }
}

enum LivestockFixtureWriteRole: Equatable, Sendable {
    case owner, manager, viewer

    var canCreateAnimal: Bool {
        switch self {
        case .owner, .manager: true
        case .viewer: false
        }
    }

    var canAssignIdentifier: Bool { canCreateAnimal }

    var canRecordLifecycle: Bool { canCreateAnimal }
}

struct LivestockAnimalSaveDraft: Equatable, Sendable {
    var identifierKind: LivestockIdentifierKind = .earTag
    var identifierValue = ""
    var lifecycleType: LivestockLifecycleEventType?
    var lifecycleAt = Date()
    var careType: LivestockCareEventType?
    var careAt = Date()
    var feedLines: [LivestockFeedEntry] = [LivestockFeedEntry(inputType: .feed)]
    var feedAt = Date()
    var supplier = ""
    var batch = ""
    var identifierCost = ""
    var careCost = ""
    var costAmount = ""
    var financeReference = ""

    var wantsIdentifier: Bool {
        !identifierValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var wantsFeed: Bool {
        feedLines.contains { $0.hasQuantity }
    }

    var hasFeedActivity: Bool {
        feedLines.contains { $0.hasQuantity || LivestockMoney.nonzeroText($0.cost) != nil }
    }

    var wantsCost: Bool {
        !costAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmpty: Bool {
        !wantsIdentifier && lifecycleType == nil && careType == nil && !hasFeedActivity && !wantsCost
            && LivestockMoney.nonzeroText(identifierCost) == nil
            && LivestockMoney.nonzeroText(careCost) == nil
    }

    var hasActivityCost: Bool {
        LivestockMoney.nonzeroText(identifierCost) != nil
            || LivestockMoney.nonzeroText(careCost) != nil
            || feedLines.contains { LivestockMoney.nonzeroText($0.cost) != nil }
    }

    func costProblem() -> String? {
        if let problem = activityCostProblem(identifierCost, label: "Identifier cost", required: wantsIdentifier) {
            return problem
        }
        if let problem = activityCostProblem(careCost, label: "Care cost", required: careType != nil) {
            return problem
        }
        for line in feedLines where line.hasQuantity || !line.cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let problem = activityCostProblem(line.cost, label: "\(line.inputType.label) cost", required: line.hasQuantity) {
                return problem
            }
        }
        if wantsCost, let problem = LivestockMoney.requirement(costAmount, label: "Cost", allowZero: false, allowNegative: true) {
            return problem
        }
        return nil
    }

    func enteredTotal() -> Decimal { costSummary(recorded: []).total }

    func costSummary(recorded: [LivestockCostAttribution]) -> LivestockCostSummary {
        var amounts: [String: Decimal] = [:]
        var types: [String: LivestockInputType] = [:]
        var frequencies: [String: LivestockCostFrequency] = [:]
        var other = LivestockMoney.signed(identifierCost)
            + LivestockMoney.signed(careCost)
            + LivestockMoney.signed(costAmount)
        func addFeed(_ amount: Decimal, type: LivestockInputType, frequency: LivestockCostFrequency) {
            guard amount != 0 else { return }
            let key = "\(type.rawValue)-\(frequency.rawValue)"
            amounts[key, default: 0] += amount
            types[key] = type
            frequencies[key] = frequency
        }
        for line in feedLines {
            addFeed(LivestockMoney.signed(line.cost), type: line.inputType, frequency: line.frequency)
        }
        for item in recorded {
            let amount = LivestockMoney.signed(item.amount)
            if let frequency = item.frequency {
                addFeed(amount, type: item.feedType ?? .feed, frequency: frequency)
            } else {
                other += amount
            }
        }
        let typeOrder = LivestockInputType.allCases
        let frequencyOrder = LivestockCostFrequency.allCases
        let rows = amounts.keys.sorted { left, right in
            let leftType = typeOrder.firstIndex(of: types[left] ?? .feed) ?? 0
            let rightType = typeOrder.firstIndex(of: types[right] ?? .feed) ?? 0
            if leftType != rightType { return leftType < rightType }
            let leftFrequency = frequencyOrder.firstIndex(of: frequencies[left] ?? .daily) ?? 0
            let rightFrequency = frequencyOrder.firstIndex(of: frequencies[right] ?? .daily) ?? 0
            return leftFrequency < rightFrequency
        }.compactMap { key -> LivestockFeedSubtotal? in
            guard let type = types[key], let frequency = frequencies[key], let amount = amounts[key] else { return nil }
            return LivestockFeedSubtotal(inputType: type, frequency: frequency, amount: amount)
        }
        let feedTotal = rows.reduce(Decimal(0)) { $0 + $1.amount }
        let total = feedTotal + other
        return LivestockCostSummary(
            feedSubtotals: rows,
            feedTotal: feedTotal,
            other: other,
            total: total < 0 ? 0 : total
        )
    }

    private func activityCostProblem(_ text: String, label: String, required: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return required ? LivestockMoney.requirement(text, label: label) : nil
        }
        return LivestockMoney.requirement(text, label: label, allowNegative: true)
    }
}

struct LivestockSaveNotice: Equatable, Sendable {
    var animalID: Animal.ID
    var message: String
    var succeeded: Bool
}

struct LivestockAnimalSaveResult: Equatable, Sendable {
    var savedIdentifier = false
    var savedLifecycle = false
    var savedCare = false
    var savedFeed = false
    var savedCost = false
    var acceptedIdentifierCost = false
    var acceptedCareCost = false
    var acceptedFeedCost = false
    var message: String

    var savedAnything: Bool {
        savedIdentifier || savedLifecycle || savedCare || savedFeed || savedCost
            || acceptedIdentifierCost || acceptedCareCost || acceptedFeedCost
    }

    var savedLabels: [String] {
        var labels: [String] = []
        if savedIdentifier { labels.append("the identifier") }
        if savedLifecycle { labels.append("the lifecycle event") }
        if savedCare { labels.append("the care record") }
        if savedFeed { labels.append("the feed record") }
        if savedCost { labels.append("the cost") }
        return labels
    }
}

enum LivestockCreateAnimalResult: Equatable {
    case created(Animal)
    case rejected(String)
}

enum LivestockIdentifierResult: Equatable {
    case assigned(LivestockAnimalIdentifier)
    case retired(LivestockAnimalIdentifier)
    case rejected(String)

    var message: String {
        switch self {
        case .assigned(let identifier):
            "Assigned \(identifier.summary). \(FixturePresentationBoundary.identifierBoundary)"
        case .retired(let identifier):
            "Retired \(identifier.summary). \(FixturePresentationBoundary.identifierBoundary)"
        case .rejected(let reason):
            reason
        }
    }
}

enum LivestockLifecycleResult: Equatable {
    case recorded(LivestockLifecycleEvent)
    case rejected(String)

    var message: String {
        switch self {
        case .recorded(let event):
            "Recorded \(event.summary). \(FixturePresentationBoundary.lifecycleBoundary)"
        case .rejected(let reason):
            reason
        }
    }
}

enum LivestockIdentifierComparison {
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct AddAnimalDraft: Equatable {
    var category: AnimalCategory = .liveStock
    var displayName = ""
    var species: Species?
    var productionType: ProductionType?
    var breed: Breed?
    var petBreedChoice = ""
    var typedBreed = ""
    var mixBreedOne = ""
    var mixBreedTwo = ""
    var petKind: PetKind?
    var petSpeciesOther = ""

    var petFormProblem: String? {
        guard category == .pets else { return nil }
        guard let petKind else { return "Choose a species." }
        if petKind == .other, petSpeciesOther.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the species."
        }
        return petBreedProblem
    }

    var recordedPetBreed: String? {
        let choice = petBreedChoice.trimmingCharacters(in: .whitespacesAndNewlines)
        if choice == "mixed" { return "mixed" }
        if choice == "typed" {
            let typed = typedBreed.trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? nil : typed
        }
        return choice.isEmpty ? nil : choice
    }

    var petBreedProblem: String? {
        guard category == .pets else { return nil }
        if petBreedChoice == "typed", typedBreed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a breed, or choose one from the list."
        }
        if petBreedChoice == "mixed" {
            if petKind != .dog {
                return "A mixed breed is for a dog."
            }
            if mixBreedOne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || mixBreedTwo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter both breeds in the mix."
            }
        }
        if let petKind, petKind != .other, petBreedChoice != "typed", petBreedChoice != "mixed", !petBreedChoice.isEmpty,
           !LivestockCatalog.petBreeds(for: petKind).contains(petBreedChoice) {
            return "Choose a breed for this species."
        }
        return nil
    }

    init(
        category: AnimalCategory = .liveStock,
        displayName: String = "",
        species: Species? = nil,
        productionType: ProductionType? = nil,
        breed: Breed? = nil
    ) {
        self.category = category
        self.displayName = displayName
        if category == .pets, species == nil {
            self.species = .pet
            self.productionType = productionType ?? .companion
            self.breed = nil
        } else {
            self.species = species
            self.productionType = productionType
            self.breed = breed
        }
    }

    mutating func selectPetKind(_ kind: PetKind?) {
        petKind = kind
        species = .pet
        productionType = .companion
        breed = nil
        if kind == .other {
            petBreedChoice = "typed"
            return
        }
        if kind != .dog, petBreedChoice == "mixed" {
            petBreedChoice = ""
        }
        if petBreedChoice != "typed", petBreedChoice != "mixed", !LivestockCatalog.petBreeds(for: kind).contains(petBreedChoice) {
            petBreedChoice = ""
        }
    }

    mutating func selectSpecies(_ species: Species?) {
        self.species = species
        if let productionType, !LivestockCatalog.productionTypes(for: species).contains(productionType) {
            self.productionType = nil
        }
        if breed?.species != species { breed = nil }
    }

    mutating func selectProductionType(_ productionType: ProductionType?) {
        self.productionType = productionType
    }

    mutating func selectBreed(_ breed: Breed?) {
        self.breed = breed?.species == species ? breed : nil
    }

    var isValidCatalogSelection: Bool {
        guard let productionType, LivestockCatalog.productionTypes(for: species).contains(productionType) else { return false }
        return LivestockCatalog.accepts(species: species, production: productionType, breed: breed)
    }

    func submitFixturePresentation() -> String {
        FixturePresentationBoundary.addAnimalBoundary
    }
}

enum LivestockDevReadError: LocalizedError {
    case refused
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .refused: "The livestock database request was refused."
        case .unavailable(let message): message
        }
    }
}

struct LivestockDevLoopbackRead: LivestockAuthorizedReadProvider, Sendable {
    static let animalsPath = "/api/ranchos/livestock/v1/animals"
    static let ticketRelativePath = "Library/Application Support/RanchOSLivestock/dev-read.json"

    let baseURL: URL
    let token: String
    let tenantID: String

    static func load(fileURL: URL? = nil, now: Date = Date()) -> LivestockDevLoopbackRead? {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(ticketRelativePath)
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let base = object["baseURL"] as? String,
            let token = object["token"] as? String,
            let tenantID = object["tenantID"] as? String,
            let expiresAt = object["expiresAt"] as? String,
            let expiry = iso8601.date(from: expiresAt),
            expiry > now,
            !token.isEmpty,
            !tenantID.isEmpty,
            let parsed = URL(string: base),
            isLoopback(parsed)
        else {
            return nil
        }
        return LivestockDevLoopbackRead(baseURL: parsed, token: token, tenantID: tenantID)
    }

    func readAnimals() async throws -> LivestockAuthorizedAnimalPage {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LivestockDevReadError.refused
        }
        components.path = Self.animalsPath
        components.query = nil
        components.fragment = nil
        guard let url = components.url, Self.isLoopback(url) else {
            throw LivestockDevReadError.refused
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(tenantID, forHTTPHeaderField: "X-RanchOS-Tenant")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LivestockDevReadError.unavailable("The DEV livestock database did not return animals.")
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> LivestockAuthorizedAnimalPage {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["origin"] as? String == "live",
            let body = object["body"] as? [String: Any],
            let rows = body["animals"] as? [[String: Any]]
        else {
            throw LivestockDevReadError.unavailable("The DEV livestock database returned an unreadable animal list.")
        }
        let animals = try rows.map(animal(from:))
        let herds = (body["herds"] as? [[String: Any]] ?? []).compactMap { item -> LivestockHerd? in
            guard
                let idText = item["id"] as? String,
                let id = UUID(uuidString: idText),
                let name = item["name"] as? String,
                !name.isEmpty
            else { return nil }
            return LivestockHerd(
                id: id,
                name: name,
                notes: item["notes"] as? String ?? "",
                retiredAt: stamp.date(from: Self.text(item["retired_at"]))
            )
        }
        return LivestockAuthorizedAnimalPage(origin: .live, animals: animals, herds: herds)
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func animal(from row: [String: Any]) throws -> Animal {
        guard
            let idText = row["animal_id"] as? String,
            let id = UUID(uuidString: idText),
            let name = row["display_name"] as? String,
            let speciesCode = row["species_code"] as? String,
            let species = Species(rawValue: speciesCode),
            let productionCode = row["production_type_code"] as? String,
            let production = ProductionType(rawValue: productionCode),
            LivestockCatalog.accepts(species: species, production: production, breed: nil)
        else {
            throw LivestockDevReadError.unavailable("An animal from the DEV livestock database could not be read.")
        }
        let breedCode = row["breed_code"] as? String
        let breed = breedCode.flatMap { code in
            LivestockCatalog.breeds.first { $0.code == code && $0.species == species }
        }
        guard LivestockCatalog.accepts(species: species, production: production, breed: breed) else {
            throw LivestockDevReadError.unavailable("An animal from the DEV livestock database could not be read.")
        }
        let identifiers = Self.identifiers(from: row)
        let lifecycleEvents = Self.lifecycleEvents(from: row)
        return Animal(
            id: id,
            displayName: name,
            species: species,
            productionType: production,
            breed: breed,
            identifiers: identifiers,
            lifecycleEvents: lifecycleEvents,
            careEvents: Self.careEvents(from: row),
            consumptions: Self.consumptions(from: row),
            costs: Self.costs(from: row),
            recordedBreed: row["pet_breed"] as? String,
            mixBreedOne: row["pet_mix_one"] as? String,
            mixBreedTwo: row["pet_mix_two"] as? String,
            petKind: Self.text(row["pet_species"]).isEmpty ? nil : PetKind(rawValue: Self.text(row["pet_species"])),
            petSpeciesOther: Self.text(row["pet_species_other"]).isEmpty ? nil : Self.text(row["pet_species_other"]),
            herdID: UUID(uuidString: Self.text(row["herd_id"])),
            herdName: Self.text(row["herd_name"]).isEmpty ? nil : Self.text(row["herd_name"]),
            herdStartedAt: stamp.date(from: Self.text(row["herd_started_at"])),
            retirementReason: LivestockIdentifierRetirementReason(rawValue: Self.text(row["retirement_reason"])),
            retiredAt: stamp.date(from: Self.text(row["retired_at"])),
            saleAmount: Self.text(row["sale_amount"]).isEmpty ? nil : LivestockMoney.decimal(Self.text(row["sale_amount"])),
            saleOn: Self.saleDay.date(from: Self.text(row["sale_on"])),
            status: "Active"
        )
    }

    func createAnimal(
        displayName: String,
        species: Species,
        productionType: ProductionType,
        breed: Breed?,
        petBreed: String = "",
        mixBreedOne: String = "",
        mixBreedTwo: String = "",
        petSpecies: String = "",
        petSpeciesOther: String = ""
    ) async throws -> UUID {
        let body = try await post(
            path: Self.animalsPath,
            body: [
                "display_name": displayName,
                "species_code": species.rawValue,
                "production_type_code": productionType.rawValue,
                "breed_code": breed?.code ?? "",
                "pet_breed": petBreed,
                "pet_mix_one": mixBreedOne,
                "pet_mix_two": mixBreedTwo,
                "pet_species": petSpecies,
                "pet_species_other": petSpeciesOther,
            ]
        )
        guard let idText = body["animal_id"] as? String, let id = UUID(uuidString: idText) else {
            throw LivestockDevReadError.unavailable("The DEV livestock database did not return the new animal.")
        }
        return id
    }

    func assignIdentifier(animalID: Animal.ID, kind: LivestockIdentifierKind, value: String) async throws {
        try await post(path: "\(Self.animalsPath)/\(animalID.uuidString)/identifiers", body: ["kind": kind.rawValue, "value": value])
    }

    func retireAnimal(animalID: Animal.ID, reason: LivestockIdentifierRetirementReason, saleAmount: String? = nil, saleOn: Date? = nil) async throws {
        var body: [String: Any] = ["reason": reason.rawValue]
        if reason == .sold, let saleAmount, let saleOn {
            body["sale_amount"] = saleAmount
            body["sale_on"] = Self.saleDay.string(from: saleOn)
        }
        try await post(path: "\(Self.animalsPath)/\(animalID.uuidString)/retire", body: body)
    }

    func updateClassification(animalID: Animal.ID, production: ProductionType, breed: Breed?) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/classification",
            body: [
                "production_type_code": production.rawValue,
                "breed_code": breed?.code ?? "",
            ]
        )
    }

    func createHerd(name: String, notes: String) async throws {
        try await post(path: "\(Self.animalsPath)/herds", body: ["name": name, "notes": notes])
    }

    func assignHerd(animalID: Animal.ID, herdID: UUID) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/herd",
            body: ["herd_id": herdID.uuidString]
        )
    }

    func clearHerd(animalID: Animal.ID) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/herd",
            body: ["herd_id": ""]
        )
    }

    func retireHerd(herdID: UUID) async throws {
        try await post(path: "\(Self.animalsPath)/herds/\(herdID.uuidString)/retire", body: [:])
    }

    func retireIdentifier(animalID: Animal.ID, identifierID: UUID, reason: LivestockIdentifierRetirementReason) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/identifiers/\(identifierID.uuidString)/retire",
            body: ["reason": reason.rawValue]
        )
    }

    func recordCare(animalID: Animal.ID, type: LivestockCareEventType, occurredAt: Date, confirmed: Bool) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/care",
            body: ["type": type.rawValue, "occurred_at": Self.stamp.string(from: occurredAt), "confirmed": confirmed]
        )
    }

    func recordConsumption(
        animalID: Animal.ID,
        inputType: LivestockInputType,
        quantity: String,
        unit: LivestockInputUnit,
        observedAt: Date,
        supplier: String,
        batch: String,
        frequency: LivestockCostFrequency
    ) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/consumption",
            body: [
                "input_type": inputType.rawValue,
                "quantity": quantity,
                "unit": unit.rawValue,
                "observed_at": Self.stamp.string(from: observedAt),
                "supplier": supplier,
                "batch": batch,
                "frequency": frequency.rawValue,
            ]
        )
    }

    func recordCost(
        animalID: Animal.ID,
        amount: String,
        financeReference: String,
        confirmed: Bool,
        frequency: LivestockCostFrequency? = nil,
        feedType: LivestockInputType? = nil
    ) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/costs",
            body: [
                "amount": amount,
                "finance_reference": financeReference,
                "confirmed": confirmed,
                "frequency": frequency?.rawValue ?? "",
                "feed_type": feedType?.rawValue ?? "",
            ]
        )
    }

    func recordLifecycle(animalID: Animal.ID, type: LivestockLifecycleEventType, occurredAt: Date) async throws {
        try await post(
            path: "\(Self.animalsPath)/\(animalID.uuidString)/lifecycle",
            body: ["type": type.rawValue, "occurred_at": Self.stamp.string(from: occurredAt)]
        )
    }

    @discardableResult
    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LivestockDevReadError.refused
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url, Self.isLoopback(url) else {
            throw LivestockDevReadError.refused
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(tenantID, forHTTPHeaderField: "X-RanchOS-Tenant")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LivestockDevReadError.unavailable("The DEV livestock database did not answer.")
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw LivestockDevReadError.unavailable(message ?? "The DEV livestock database did not save the change.")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func identifiers(from row: [String: Any]) -> [LivestockAnimalIdentifier] {
        if let rows = row["identifiers"] as? [[String: Any]] {
            return rows.compactMap { item in
                guard
                    let idText = item["id"] as? String,
                    let id = UUID(uuidString: idText),
                    let kindCode = item["kind"] as? String,
                    let kind = LivestockIdentifierKind(rawValue: kindCode),
                    let value = item["value"] as? String
                else {
                    return nil
                }
                let reason = (item["retirement_reason"] as? String).flatMap(LivestockIdentifierRetirementReason.init(rawValue:))
                let retiredAt = (item["retired_at"] as? String).flatMap { stamp.date(from: $0) }
                return LivestockAnimalIdentifier(id: id, kind: kind, value: value, retirementReason: reason, retiredAt: retiredAt)
            }
        }
        let identifierObject = row["identifier"] as? [String: Any]
        let identifierValue = identifierObject?["value"] as? String ?? ""
        if let kindCode = identifierObject?["kind"] as? String,
           let kind = LivestockIdentifierKind(rawValue: kindCode),
           !identifierValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [LivestockAnimalIdentifier(id: UUID(), kind: kind, value: identifierValue, retirementReason: nil)]
        }
        return []
    }

    private static func lifecycleEvents(from row: [String: Any]) -> [LivestockLifecycleEvent] {
        guard let rows = row["lifecycle_events"] as? [[String: Any]] else { return [] }
        return rows.compactMap { item in
            guard
                let idText = item["id"] as? String,
                let id = UUID(uuidString: idText),
                let typeCode = item["type"] as? String,
                let type = LivestockLifecycleEventType(rawValue: typeCode),
                let occurred = item["occurred_at"] as? String,
                let occurredAt = stamp.date(from: occurred)
            else {
                return nil
            }
            return LivestockLifecycleEvent(id: id, type: type, occurredAt: occurredAt)
        }
    }

    private static func careEvents(from row: [String: Any]) -> [LivestockCareEvent] {
        guard let rows = row["care_events"] as? [[String: Any]] else { return [] }
        return rows.compactMap { item in
            guard
                let idText = item["id"] as? String,
                let id = UUID(uuidString: idText),
                let typeCode = item["type"] as? String,
                let type = LivestockCareEventType(rawValue: typeCode),
                let occurred = item["occurred_at"] as? String,
                let occurredAt = stamp.date(from: occurred)
            else { return nil }
            return LivestockCareEvent(id: id, type: type, occurredAt: occurredAt)
        }
    }

    private static func consumptions(from row: [String: Any]) -> [LivestockConsumption] {
        guard let rows = row["consumptions"] as? [[String: Any]] else { return [] }
        return rows.compactMap { item in
            guard
                let idText = item["id"] as? String,
                let id = UUID(uuidString: idText),
                let typeCode = item["input_type"] as? String,
                let inputType = LivestockInputType(rawValue: typeCode),
                let unitCode = item["unit"] as? String,
                let unit = LivestockInputUnit(rawValue: unitCode),
                let observed = item["observed_at"] as? String,
                let observedAt = stamp.date(from: observed)
            else { return nil }
            return LivestockConsumption(
                id: id,
                inputType: inputType,
                quantity: text(item["quantity"]),
                unit: unit,
                observedAt: observedAt,
                supplier: item["supplier"] as? String,
                batch: item["batch"] as? String,
                frequency: (item["frequency"] as? String).flatMap(LivestockCostFrequency.init(rawValue:))
            )
        }
    }

    private static func costs(from row: [String: Any]) -> [LivestockCostAttribution] {
        guard let rows = row["costs"] as? [[String: Any]] else { return [] }
        return rows.compactMap { item in
            guard
                let idText = item["id"] as? String,
                let id = UUID(uuidString: idText),
                let recorded = item["recorded_at"] as? String,
                let recordedAt = stamp.date(from: recorded)
            else { return nil }
            return LivestockCostAttribution(
                id: id,
                amount: text(item["amount"]),
                financeReference: item["finance_reference"] as? String,
                recordedAt: recordedAt,
                frequency: (item["frequency"] as? String).flatMap(LivestockCostFrequency.init(rawValue:)),
                feedType: (item["feed_type"] as? String).flatMap(LivestockInputType.init(rawValue:))
            )
        }
    }

    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static let saleDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()
