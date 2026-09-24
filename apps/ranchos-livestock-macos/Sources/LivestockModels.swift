import Foundation
import SwiftUI

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

enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Species: String, CaseIterable, Identifiable, Sendable {
    case cattle, bison, chicken, goat, horse, pet, pig, rabbit, sheep, other

    var id: String { rawValue }
    static let pickerChoices: [Species] = [.cattle, .bison, .chicken, .goat, .horse, .pet, .pig, .rabbit, .sheep, .other]

    var label: String {
        switch self {
        case .cattle: "Beef cattle"
        case .bison: "Bison"
        case .goat: "Goats"
        case .sheep: "Sheep"
        case .chicken: "Chickens"
        case .pig: "Pigs"
        case .horse: "Horses"
        case .rabbit: "Rabbits"
        case .pet: "Pets"
        case .other: "Other"
        }
    }

    /// Picker-only species that this DEV fixture must not present as durable catalog values.
    var isFixtureOnlyPickerSpecies: Bool {
        switch self {
        case .rabbit, .other: true
        case .cattle, .bison, .chicken, .goat, .horse, .pet, .pig, .sheep: false
        }
    }
}

enum ProductionType: String, CaseIterable, Identifiable, Sendable {
    case beef, breeding, broiler, companion, dairy, layer

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
        let types: [ProductionType] = switch species {
        case .cattle: [.beef, .dairy, .breeding]
        case .bison: [.beef, .breeding]
        case .chicken: [.layer, .broiler, .breeding]
        case .goat: [.dairy, .beef, .breeding]
        case .horse, .rabbit, .sheep, .pig: [.breeding, .companion]
        case .other, .pet: [.companion]
        }
        return types.sorted { $0.label < $1.label }
    }

    static func breeds(for species: Species?) -> [Breed] {
        guard let species else { return [] }
        return breeds.filter { $0.species == species }.sorted { $0.label < $1.label }
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
    let care: AnimalCareFixture
    let feed: AnimalFeedFixture
    let operationalCostAttribution: AnimalOperationalCostFixture
}

/// Local presentation values for a future authorized Livestock care read model.
struct AnimalCareFixture: Equatable, Sendable {
    let nextCheckLabel: String
    let summary: String
}

/// Local presentation values for a future authorized Livestock feeding read model.
struct AnimalFeedFixture: Equatable, Sendable {
    let rationLabel: String
    let dailyAmountLabel: String
}

/// Display-only attribution. Ranch Finance remains the canonical ledger.
struct AnimalOperationalCostFixture: Equatable, Sendable {
    let categoryLabel: String
    let amountLabel: String
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
    static let otherSpeciesBoundary = "Other livestock descriptions are fixture-only and are not accepted by the durable catalog."
    static let rabbitSpeciesBoundary = "Rabbit is a fixture-only picker choice and is not accepted by the durable catalog."
}
