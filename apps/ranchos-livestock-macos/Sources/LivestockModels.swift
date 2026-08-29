import Foundation

/// Presentation-only DEV fixture metadata. It is never an authenticated tenant context.
struct FixturePresentationContext: Equatable, Sendable {
    let displayName: String
    let environment: String
    let statusLabel: String

    static let preview = FixturePresentationContext(
        displayName: "RedBud Ranch fixture",
        environment: "DEV fixture",
        statusLabel: "No authenticated tenant session"
    )
}

enum Species: String, CaseIterable, Identifiable, Sendable {
    case cattle, bison, goat, sheep, chicken, pig, horse

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cattle: "Beef cattle"
        case .bison: "Bison"
        case .goat: "Goats"
        case .sheep: "Sheep"
        case .chicken: "Chickens"
        case .pig: "Pigs"
        case .horse: "Horses"
        }
    }
}

enum ProductionType: String, CaseIterable, Identifiable, Sendable {
    case beef, dairy, layer, broiler, breeding, companion

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct Breed: Identifiable, Equatable, Hashable, Sendable {
    let code: String
    let label: String
    let species: Species
    var id: String { code }
}

enum LivestockCatalog {
    static let breeds = [
        Breed(code: "angus", label: "Angus", species: .cattle),
        Breed(code: "hereford", label: "Hereford", species: .cattle),
        Breed(code: "boer", label: "Boer", species: .goat),
        Breed(code: "dorper", label: "Dorper", species: .sheep),
        Breed(code: "rhode_island_red", label: "Rhode Island Red", species: .chicken),
        Breed(code: "quarter_horse", label: "Quarter Horse", species: .horse),
        Breed(code: "american_bison", label: "American Bison", species: .bison),
        Breed(code: "yorkshire", label: "Yorkshire", species: .pig),
    ]

    static func productionTypes(for species: Species?) -> [ProductionType] {
        guard let species else { return [] }
        switch species {
        case .cattle: return [.beef, .dairy, .breeding]
        case .bison: return [.beef, .breeding]
        case .goat: return [.dairy, .beef, .breeding]
        case .sheep: return [.breeding, .companion]
        case .chicken: return [.layer, .broiler, .breeding]
        case .pig: return [.breeding, .companion]
        case .horse: return [.breeding, .companion]
        }
    }

    static func breeds(for species: Species?) -> [Breed] {
        guard let species else { return [] }
        return breeds.filter { $0.species == species }
    }

    static func accepts(species: Species?, production: ProductionType?, breed: Breed?) -> Bool {
        guard let species, let production, productionTypes(for: species).contains(production) else { return false }
        return breed == nil || breed?.species == species
    }
}

struct Animal: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let species: Species
    let productionType: ProductionType
    let breed: Breed?
    let identifier: String
    let status: String
}

struct HerdOverview: Equatable, Sendable {
    let activeAnimals: Int
    let careDue: Int
    let feedingNeeds: Int
    let operationalCostLabel: String
}

enum FixtureLoadState: Equatable, Sendable {
    case loading
    case loaded
    case empty(message: String)
    case error(message: String)

    var message: String? {
        switch self {
        case .loading: "Loading fixture presentation…"
        case .loaded: nil
        case let .empty(message), let .error(message): message
        }
    }
}

enum FixturePresentationBoundary {
    static let tenantDisclosure = "DEV fixture — live tenant data is not connected."
    static let careOwnership = "Livestock owns animal care records. Ranch Health remains human-only."
    static let financeOwnership = "Fixture operational attribution only. Ranch Finance remains the canonical ledger; no posting or editing occurs here."
    static let addAnimalBoundary = "Fixture presentation only — Add animal does not write to a database or disk."
}
