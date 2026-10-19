import Foundation

enum LivestockBreeding {
    static func problem(
        animal: Animal,
        sireID: UUID?,
        damID: UUID?,
        bredWithID: UUID?,
        among animals: [Animal]
    ) -> String? {
        if animal.species == .pet {
            if sireID != nil || damID != nil || bredWithID != nil {
                return "A pet does not have a breeding record."
            }
            return nil
        }
        if sireID == animal.id { return "An animal cannot be its own sire." }
        if damID == animal.id { return "An animal cannot be its own dam." }
        if bredWithID == animal.id { return "An animal cannot be bred with itself." }
        if let sireID, sireID == damID { return "Sire and dam must be two different animals." }
        if let sireID, let relative = animals.first(where: { $0.id == sireID }), relative.species != animal.species {
            return "Sire must be the same species."
        }
        if let damID, let relative = animals.first(where: { $0.id == damID }), relative.species != animal.species {
            return "Dam must be the same species."
        }
        if let bredWithID, let relative = animals.first(where: { $0.id == bredWithID }), relative.species != animal.species {
            return "The animal they are bred with must be the same species."
        }
        if let sireID, animals.contains(where: { $0.id == sireID }) == false {
            return "Sire was not found."
        }
        if let damID, animals.contains(where: { $0.id == damID }) == false {
            return "Dam was not found."
        }
        if let bredWithID, animals.contains(where: { $0.id == bredWithID }) == false {
            return "The animal they are bred with was not found."
        }
        let descendants = descendantIDs(of: animal.id, among: animals)
        if let sireID, descendants.contains(sireID) {
            return "Sire cannot be a descendant of this animal."
        }
        if let damID, descendants.contains(damID) {
            return "Dam cannot be a descendant of this animal."
        }
        return nil
    }

    static func relatives(for species: Species, excluding animalID: UUID, among animals: [Animal]) -> [Animal] {
        animals
            .filter { $0.species == species && $0.id != animalID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func offspring(of animalID: UUID, among animals: [Animal]) -> [Animal] {
        animals
            .filter { $0.sireID == animalID || $0.damID == animalID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func currentMates(of animalID: UUID, among animals: [Animal]) -> [Animal] {
        animals
            .filter { $0.bredWithID == animalID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func tree(for animal: Animal, among animals: [Animal], generations: Int = 3) -> LivestockBreedingNode {
        node(for: animal.id, among: animals, role: "This animal", remaining: generations, visited: [animal.id], includeFamily: true)
            ?? LivestockBreedingNode(id: animal.id, name: animal.displayName, role: "This animal")
    }

    static func descendantIDs(of animalID: UUID, among animals: [Animal]) -> Set<UUID> {
        var found: Set<UUID> = []
        var queue = offspring(of: animalID, among: animals).map(\.id)
        while let next = queue.first {
            queue.removeFirst()
            guard found.insert(next).inserted else { continue }
            queue.append(contentsOf: offspring(of: next, among: animals).map(\.id))
        }
        return found
    }

    private static func node(
        for animalID: UUID,
        among animals: [Animal],
        role: String,
        remaining: Int,
        visited: Set<UUID>,
        includeFamily: Bool
    ) -> LivestockBreedingNode? {
        guard let animal = animals.first(where: { $0.id == animalID }) else { return nil }
        var sire: LivestockBreedingNode?
        var dam: LivestockBreedingNode?
        if remaining > 0 {
            if let sireID = animal.sireID, !visited.contains(sireID) {
                sire = node(
                    for: sireID,
                    among: animals,
                    role: "Sire",
                    remaining: remaining - 1,
                    visited: visited.union([sireID]),
                    includeFamily: false
                )
            }
            if let damID = animal.damID, !visited.contains(damID) {
                dam = node(
                    for: damID,
                    among: animals,
                    role: "Dam",
                    remaining: remaining - 1,
                    visited: visited.union([damID]),
                    includeFamily: false
                )
            }
        }
        var mate: LivestockBreedingNode?
        var children: [LivestockBreedingNode] = []
        var paired: [LivestockBreedingNode] = []
        if includeFamily {
            if let mateID = animal.bredWithID, !visited.contains(mateID) {
                mate = LivestockBreedingNode(
                    id: mateID,
                    name: animals.first { $0.id == mateID }?.displayName ?? "Unknown",
                    role: "Bred with"
                )
            }
            children = offspring(of: animalID, among: animals).compactMap { child in
                LivestockBreedingNode(id: child.id, name: child.displayName, role: "Offspring")
            }
            paired = currentMates(of: animalID, among: animals).compactMap { partner in
                guard partner.id != animal.bredWithID else { return nil }
                return LivestockBreedingNode(id: partner.id, name: partner.displayName, role: "Bred with")
            }
        }
        return LivestockBreedingNode(
            id: animal.id,
            name: animal.displayName,
            role: role,
            sire: sire,
            dam: dam,
            mate: mate,
            offspring: children,
            mates: paired
        )
    }
}

final class LivestockBreedingNode: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let role: String
    let sire: LivestockBreedingNode?
    let dam: LivestockBreedingNode?
    let mate: LivestockBreedingNode?
    let offspring: [LivestockBreedingNode]
    let mates: [LivestockBreedingNode]

    init(
        id: UUID,
        name: String,
        role: String,
        sire: LivestockBreedingNode? = nil,
        dam: LivestockBreedingNode? = nil,
        mate: LivestockBreedingNode? = nil,
        offspring: [LivestockBreedingNode] = [],
        mates: [LivestockBreedingNode] = []
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.sire = sire
        self.dam = dam
        self.mate = mate
        self.offspring = offspring
        self.mates = mates
    }

    static func == (lhs: LivestockBreedingNode, rhs: LivestockBreedingNode) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.role == rhs.role
    }
}
