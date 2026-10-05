import Foundation
import Observation

enum RanchOSLivestockSpecies: String, CaseIterable, Sendable, Identifiable {
    case cattle, bison, goat, sheep, chicken, pig, horse, pet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cattle: "Cattle"
        case .bison: "Bison"
        case .goat: "Goat"
        case .sheep: "Sheep"
        case .chicken: "Chicken"
        case .pig: "Pig"
        case .horse: "Horse"
        case .pet: "Pet"
        }
    }
}

enum RanchOSLivestockProductionType: String, CaseIterable, Sendable, Identifiable {
    case beef, dairy, breeding, layer, broiler, companion

    var id: String { rawValue }

    var label: String { rawValue.capitalized }
}

enum RanchOSLivestockLifecycleStatus: String, Sendable {
    case active
    case archived

    var label: String { rawValue.capitalized }
}

enum RanchOSLivestockFactFreshness: String, Sendable {
    case current
    case stale
    case incomplete
    case conflicting

    var label: String { rawValue.capitalized }
}

enum RanchOSLivestockSpeciesFilter: Equatable, Hashable, Sendable, Identifiable {
    case all
    case species(RanchOSLivestockSpecies)

    var id: String {
        switch self {
        case .all: "all"
        case .species(let species): species.rawValue
        }
    }

    var label: String {
        switch self {
        case .all: "All species"
        case .species(let species): species.label
        }
    }

    static var pickerChoices: [RanchOSLivestockSpeciesFilter] {
        [.all] + RanchOSLivestockSpecies.allCases.map(RanchOSLivestockSpeciesFilter.species)
    }
}

struct RanchOSLivestockBreed: Equatable, Hashable, Sendable, Identifiable {
    let code: String
    let label: String
    let species: RanchOSLivestockSpecies

    var id: String { code }
}

struct RanchOSLivestockSampleIdentifier: Equatable, Sendable {
    let kind: String
    let value: String

    var summary: String { "\(kind) \(value)" }
}

struct RanchOSLivestockSampleProvenance: Equatable, Sendable {
    let sourceType: String
    let sourceID: String
    let sourceVersion: String
    let isSynthetic: Bool

    var label: String {
        isSynthetic
            ? "Synthetic DEV fixture · \(sourceType) · \(sourceID) · \(sourceVersion)"
            : "\(sourceType) · \(sourceID) · \(sourceVersion)"
    }
}

struct RanchOSLivestockSampleAnimal: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let species: RanchOSLivestockSpecies
    let productionType: RanchOSLivestockProductionType
    let breed: RanchOSLivestockBreed?
    let lifecycleStatus: RanchOSLivestockLifecycleStatus
    let factFreshness: RanchOSLivestockFactFreshness
    let identifier: RanchOSLivestockSampleIdentifier?
    let provenance: RanchOSLivestockSampleProvenance
}

enum RanchOSLivestockBrowserListState: Equatable, Sendable {
    case emptyCatalog
    case noMatches
    case results([RanchOSLivestockSampleAnimal])
}

enum RanchOSLivestockSampleCatalog {
    static let fixtureLabel = "DEV fixture — sample animals are synthetic and not live ranch records."
    static let unavailableHistoriesNote =
        "Care, feeding, routine lifecycle, and cost histories are not included in this sample."

    static let breeds: [RanchOSLivestockBreed] = [
        RanchOSLivestockBreed(code: "angus", label: "Angus", species: .cattle),
        RanchOSLivestockBreed(code: "hereford", label: "Hereford", species: .cattle),
        RanchOSLivestockBreed(code: "american_bison", label: "American Bison", species: .bison),
        RanchOSLivestockBreed(code: "boer", label: "Boer", species: .goat),
        RanchOSLivestockBreed(code: "dorper", label: "Dorper", species: .sheep),
        RanchOSLivestockBreed(code: "rhode_island_red", label: "Rhode Island Red", species: .chicken),
        RanchOSLivestockBreed(code: "yorkshire", label: "Yorkshire", species: .pig),
        RanchOSLivestockBreed(code: "quarter_horse", label: "Quarter Horse", species: .horse),
    ]

    static let productionTypesBySpecies: [RanchOSLivestockSpecies: Set<RanchOSLivestockProductionType>] = [
        .cattle: [.beef, .dairy, .breeding],
        .bison: [.beef, .breeding],
        .goat: [.beef, .dairy, .breeding],
        .sheep: [.breeding, .companion],
        .chicken: [.layer, .broiler, .breeding],
        .pig: [.breeding, .companion],
        .horse: [.breeding, .companion],
        .pet: [.companion],
    ]

    static let breedSpecies: [String: RanchOSLivestockSpecies] = Dictionary(
        uniqueKeysWithValues: breeds.map { ($0.code, $0.species) })

    static func breed(code: String) -> RanchOSLivestockBreed? {
        breeds.first { $0.code == code }
    }

    static func accepts(
        species: RanchOSLivestockSpecies,
        productionType: RanchOSLivestockProductionType,
        breed: RanchOSLivestockBreed?
    ) -> Bool {
        guard productionTypesBySpecies[species]?.contains(productionType) == true else { return false }
        guard let breed else { return true }
        return breed.species == species && breedSpecies[breed.code] == species
    }

    static func accepts(_ animal: RanchOSLivestockSampleAnimal) -> Bool {
        accepts(species: animal.species, productionType: animal.productionType, breed: animal.breed)
    }

    static let developmentSamples: [RanchOSLivestockSampleAnimal] = [
        sample(
            id: "sample-animal-cattle-angus-001",
            name: "Maple",
            species: .cattle,
            production: .beef,
            breedCode: "angus",
            lifecycle: .active,
            freshness: .current,
            identifier: RanchOSLivestockSampleIdentifier(kind: "Tag", value: "SA-104")),
        sample(
            id: "sample-animal-cattle-hereford-002",
            name: "Oak",
            species: .cattle,
            production: .dairy,
            breedCode: "hereford",
            lifecycle: .active,
            freshness: .stale,
            identifier: RanchOSLivestockSampleIdentifier(kind: "Tag", value: "SA-221")),
        sample(
            id: "sample-animal-cattle-breeding-003",
            name: "Ridge",
            species: .cattle,
            production: .breeding,
            breedCode: nil,
            lifecycle: .archived,
            freshness: .current,
            identifier: nil),
        sample(
            id: "sample-animal-bison-004",
            name: "Plains",
            species: .bison,
            production: .beef,
            breedCode: "american_bison",
            lifecycle: .active,
            freshness: .incomplete,
            identifier: RanchOSLivestockSampleIdentifier(kind: "Tag", value: "BZ-09")),
        sample(
            id: "sample-animal-goat-boer-005",
            name: "Willow",
            species: .goat,
            production: .dairy,
            breedCode: "boer",
            lifecycle: .active,
            freshness: .current,
            identifier: nil),
        sample(
            id: "sample-animal-sheep-dorper-006",
            name: "Thistle",
            species: .sheep,
            production: .companion,
            breedCode: "dorper",
            lifecycle: .active,
            freshness: .conflicting,
            identifier: RanchOSLivestockSampleIdentifier(kind: "Tag", value: "SH-44")),
        sample(
            id: "sample-animal-chicken-rir-007",
            name: "Copper",
            species: .chicken,
            production: .layer,
            breedCode: "rhode_island_red",
            lifecycle: .active,
            freshness: .current,
            identifier: RanchOSLivestockSampleIdentifier(kind: "Band", value: "CH-12")),
        sample(
            id: "sample-animal-pig-yorkshire-008",
            name: "Harrow",
            species: .pig,
            production: .companion,
            breedCode: "yorkshire",
            lifecycle: .archived,
            freshness: .stale,
            identifier: nil),
        sample(
            id: "sample-animal-horse-qh-009",
            name: "Saddle",
            species: .horse,
            production: .breeding,
            breedCode: "quarter_horse",
            lifecycle: .active,
            freshness: .current,
            identifier: RanchOSLivestockSampleIdentifier(kind: "Brand", value: "HS-03")),
        sample(
            id: "sample-animal-pet-010",
            name: "Porch",
            species: .pet,
            production: .companion,
            breedCode: nil,
            lifecycle: .active,
            freshness: .incomplete,
            identifier: nil),
    ]

    private static func sample(
        id: String,
        name: String,
        species: RanchOSLivestockSpecies,
        production: RanchOSLivestockProductionType,
        breedCode: String?,
        lifecycle: RanchOSLivestockLifecycleStatus,
        freshness: RanchOSLivestockFactFreshness,
        identifier: RanchOSLivestockSampleIdentifier?
    ) -> RanchOSLivestockSampleAnimal {
        RanchOSLivestockSampleAnimal(
            id: id,
            displayName: name,
            species: species,
            productionType: production,
            breed: breedCode.flatMap(breed(code:)),
            lifecycleStatus: lifecycle,
            factFreshness: freshness,
            identifier: identifier,
            provenance: RanchOSLivestockSampleProvenance(
                sourceType: "synthetic_dev_fixture",
                sourceID: id,
                sourceVersion: "sample-catalog-v1",
                isSynthetic: true))
    }
}

/// In-memory sample-animal browsing. Eligible only while Livestock presentation is fixture.
@MainActor
@Observable
final class RanchOSLivestockBrowserModel {
    static let fixtureLabel = RanchOSLivestockSampleCatalog.fixtureLabel

    private(set) var animals: [RanchOSLivestockSampleAnimal]
    var searchText = "" {
        didSet { clearInvalidSelection() }
    }
    var speciesFilter: RanchOSLivestockSpeciesFilter = .all {
        didSet { clearInvalidSelection() }
    }
    var selectedAnimalID: String? {
        didSet { clearInvalidSelection() }
    }

    init(animals: [RanchOSLivestockSampleAnimal] = RanchOSLivestockSampleCatalog.developmentSamples) {
        self.animals = animals
    }

    nonisolated static func isBrowsingEligible(_ presentation: RanchOSLivestockPresentation) -> Bool {
        switch presentation {
        case .fixture: true
        case .loading, .available, .unavailable, .retryable: false
        }
    }

    var visibleAnimals: [RanchOSLivestockSampleAnimal] {
        animals.filter { matches($0) }
    }

    var selectedAnimal: RanchOSLivestockSampleAnimal? {
        guard let selectedAnimalID else { return nil }
        return visibleAnimals.first { $0.id == selectedAnimalID }
    }

    var listState: RanchOSLivestockBrowserListState {
        if animals.isEmpty { return .emptyCatalog }
        let visible = visibleAnimals
        if visible.isEmpty { return .noMatches }
        return .results(visible)
    }

    func replaceSampleData(_ animals: [RanchOSLivestockSampleAnimal]) {
        self.animals = animals
        clearInvalidSelection()
    }

    func selectAnimal(id: String?) {
        selectedAnimalID = id
    }

    private func matches(_ animal: RanchOSLivestockSampleAnimal) -> Bool {
        if case .species(let species) = speciesFilter, animal.species != species {
            return false
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if animal.displayName.localizedCaseInsensitiveContains(query) { return true }
        if animal.id.localizedCaseInsensitiveContains(query) { return true }
        if let identifier = animal.identifier {
            if identifier.value.localizedCaseInsensitiveContains(query) { return true }
            if identifier.summary.localizedCaseInsensitiveContains(query) { return true }
        }
        return false
    }

    private func clearInvalidSelection() {
        guard let selectedAnimalID else { return }
        if !visibleAnimals.contains(where: { $0.id == selectedAnimalID }) {
            self.selectedAnimalID = nil
        }
    }
}
