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
    func herdOverview(context: FixturePresentationContext) async throws -> HerdOverview {
        HerdOverview(activeAnimals: 18, careDue: 3, feedingNeeds: 4, operationalCostLabel: "$1,240 attributed")
    }

    func animals(context: FixturePresentationContext) async throws -> [Animal] {
        [
            Animal(id: UUID(uuidString: "2FB6AA84-374C-4EE1-9D94-6A4CD8E80F52")!, displayName: "Juniper", species: .cattle, productionType: .beef, breed: LivestockCatalog.breeds.first, identifier: "Tag RB-104", status: "Active"),
            Animal(id: UUID(uuidString: "D57C4765-C890-4A2B-8B6F-7C87F0C60DF2")!, displayName: "Cedar", species: .goat, productionType: .dairy, breed: LivestockCatalog.breeds.first { $0.code == "boer" }, identifier: "Tag G-18", status: "Active"),
        ]
    }
}

@MainActor
@Observable final class LivestockStore {
    let fixtureContext: FixturePresentationContext
    private let readModel: any LivestockReadModel
    var overview: HerdOverview?
    var animals: [Animal] = []
    var overviewState: FixtureLoadState = .loading
    var animalsState: FixtureLoadState = .loading
    var selectedAnimalID: Animal.ID?

    init(fixtureContext: FixturePresentationContext = .preview, readModel: any LivestockReadModel = FixtureLivestockReadModel()) {
        self.fixtureContext = fixtureContext
        self.readModel = readModel
    }

    func loadFixtures() async {
        do {
            overview = try await readModel.herdOverview(context: fixtureContext)
            overviewState = .loaded
            animals = try await readModel.animals(context: fixtureContext)
            animalsState = animals.isEmpty ? .empty(message: "No fixture animals are available.") : .loaded
            selectedAnimalID = animals.first?.id
        } catch {
            overviewState = .error(message: error.localizedDescription)
            animalsState = .error(message: error.localizedDescription)
        }
    }
}

struct AddAnimalDraft: Equatable {
    var displayName = ""
    var species: Species?
    var productionType: ProductionType?
    var breed: Breed?

    mutating func selectSpecies(_ species: Species?) {
        self.species = species
        if !LivestockCatalog.productionTypes(for: species).contains(productionType ?? .beef) { productionType = nil }
        if breed?.species != species { breed = nil }
    }

    mutating func selectProductionType(_ productionType: ProductionType?) {
        self.productionType = productionType
    }

    mutating func selectBreed(_ breed: Breed?) {
        self.breed = breed?.species == species ? breed : nil
    }

    var isValidCatalogSelection: Bool {
        LivestockCatalog.accepts(species: species, production: productionType, breed: breed)
    }

    func submitFixturePresentation() -> String {
        FixturePresentationBoundary.addAnimalBoundary
    }
}
