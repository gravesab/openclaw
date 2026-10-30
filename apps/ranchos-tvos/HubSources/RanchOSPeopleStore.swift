import Foundation
import Observation

/// One named ranch and its people for this DEV run. Codable so the store
/// can persist it as JSON.
struct RanchOSPeopleRanch: Identifiable, Codable {
    let id: UUID
    let name: String
    var people: [RanchOSPerson]
}

/// One ranch section for the page. Sendable so views and tests can list ranches.
struct RanchOSPeopleRanchSection: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let saved: Bool
    let hasOwnData: Bool
    let applications: [RanchOSPeopleApplicationData]
    let people: [RanchOSPerson]
}

/// One application's data name for a ranch. People stay in people.json.
struct RanchOSPeopleApplicationData: Identifiable, Sendable, Equatable {
    let name: String
    let dataName: String

    var id: String { dataName }
}

/// One saved person as an Opened as choice. Sendable so views can list people.
struct RanchOSPeopleIdentity: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let privilege: String
    let ranchName: String
}

private struct SavedPeopleRanches: Codable {
    var ranches: [RanchOSPeopleRanch]
}

/// One application entry inside a ranch's own data file.
private struct RanchOSRanchApplication: Codable, Equatable {
    let name: String
    let dataName: String
}

/// One ranch's own data file. People stay in people.json.
private struct RanchOSRanchFile: Codable, Equatable {
    let id: UUID
    let name: String
    let applications: [RanchOSRanchApplication]

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
        self.applications = Self.canonicalApplications(for: id)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case applications
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        applications = try values.decodeIfPresent([RanchOSRanchApplication].self, forKey: .applications) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(applications, forKey: .applications)
    }

    static func canonicalApplications(for id: UUID) -> [RanchOSRanchApplication] {
        let key = id.uuidString.lowercased()
        return [
            RanchOSRanchApplication(name: "People", dataName: "people-\(key)"),
            RanchOSRanchApplication(name: "Livestock", dataName: "livestock-\(key)"),
            RanchOSRanchApplication(name: "Finance", dataName: "finance-\(key)"),
            RanchOSRanchApplication(name: "Property Manager", dataName: "property-manager-\(key)"),
        ]
    }
}

/// People state for this DEV run. Ranch names are entered once; assigning a
/// person picks one of those names. The page is opened as the administrator
/// or as one saved person; only the administrator and owners change who has
/// access. Every successful change is written to a JSON file, and a new store
/// loads that file. The opened-as choice itself is never written.
/// Nothing here touches the network.
@MainActor
@Observable
final class RanchOSPeopleStore {
    private static let notOwnerMessage = "An owner changes who has access."
    private static let administratorAddsRanchMessage = "The administrator adds a ranch."
    private static let unknownPersonMessage = "That person is no longer on this ranch. The list is up to date."
    private static let unknownRanchMessage = "That ranch is no longer on the list. The list is up to date."
    private static let saveFailedMessage = "That change couldn't be saved. Try again."

    private(set) var message: String?

    var openedAsPersonID: UUID? {
        didSet {
            message = nil
        }
    }

    private var ranches: [RanchOSPeopleRanch] = []
    private var savedRanchIDs: Set<UUID> = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultFileURL()
        self.fileURL = url
        guard let data = try? Data(contentsOf: url) else { return }
        if let saved = try? JSONDecoder().decode(SavedPeopleRanches.self, from: data) {
            self.ranches = saved.ranches
            self.savedRanchIDs = Set(saved.ranches.map(\.id))
            backfillRanchFiles()
        } else {
            self.message = "Saved people couldn't be read. Starting empty."
        }
    }

    var ranchSections: [RanchOSPeopleRanchSection] {
        visibleRanches.map {
            RanchOSPeopleRanchSection(
                id: $0.id, name: $0.name,
                saved: savedRanchIDs.contains($0.id),
                hasOwnData: ranchFileMatches(id: $0.id),
                applications: ranchApplications(id: $0.id),
                people: $0.people)
        }
    }

    /// Isolation rows for the save-check card, verified against the JSON
    /// files on disk. Empty when the ranch is unknown.
    func isolationChecks(for ranchID: UUID) -> [IsolationCheck] {
        guard let ranch = ranches.first(where: { $0.id == ranchID }) else { return [] }
        return DataIsolationVerifier.verifyIsolation(
            ranchID: ranchID, ranchName: ranch.name, peopleFileURL: fileURL)
    }

    var openedAsOptions: [RanchOSPeopleIdentity] {
        ranches.flatMap { ranch in
            ranch.people.map {
                RanchOSPeopleIdentity(
                    id: $0.id, name: $0.name,
                    privilege: $0.role.label, ranchName: ranch.name)
            }
        }
    }

    var openedAsLine: String? {
        guard let id = openedAsPersonID,
              let found = personAndRanch(id: id) else { return nil }
        return "Opened as \(found.person.name) · \(found.person.role.label) · \(found.ranch.name)."
    }

    func setOpenedAs(id: UUID?) async {
        openedAsPersonID = id
    }

    func addRanch(name: String) async {
        guard openedAsPersonID == nil else {
            message = Self.administratorAddsRanchMessage
            return
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            message = "Give the ranch a name before adding it."
            return
        }
        let lowered = clean.lowercased()
        let taken = ranches.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowered
        }
        guard !taken else {
            message = "A ranch with that name already exists."
            return
        }
        let ranch = RanchOSPeopleRanch(id: UUID(), name: clean, people: [])
        do {
            try writeRanchFile(ranch)
        } catch {
            message = Self.saveFailedMessage
            return
        }
        ranches.append(ranch)
        do {
            try writePeopleFile()
            savedRanchIDs.insert(ranch.id)
            message = nil
        } catch {
            try? FileManager.default.removeItem(at: ranchFileURL(id: ranch.id))
            savedRanchIDs.remove(ranch.id)
            message = Self.saveFailedMessage
        }
    }

    func assign(name: String, email: String, role: RanchOSPersonRole, ranchID: UUID?) async {
        guard mayChangePeople(on: ranchID) else {
            message = Self.notOwnerMessage
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            message = "Add the person's name before assigning."
            return
        }
        guard let ranchID = ranchID, let index = ranches.firstIndex(where: { $0.id == ranchID }) else {
            if ranches.isEmpty {
                message = "Add a ranch name first."
            } else {
                message = Self.unknownRanchMessage
            }
            return
        }
        let person = RanchOSPerson(
            id: UUID(),
            name: cleanName,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role)
        ranches[index].people.append(person)
        persist(ranchID: ranchID)
    }

    func changeRole(id: UUID, role: RanchOSPersonRole) async {
        guard let (ranchIndex, personIndex) = indexOfPerson(id: id) else {
            message = openedAsPersonID == nil ? Self.unknownPersonMessage : Self.notOwnerMessage
            return
        }
        guard mayChangePeople(on: ranches[ranchIndex].id) else {
            message = Self.notOwnerMessage
            return
        }
        ranches[ranchIndex].people[personIndex].role = role
        persist(ranchID: ranches[ranchIndex].id)
    }

    func revoke(id: UUID) async {
        guard let (ranchIndex, personIndex) = indexOfPerson(id: id) else {
            message = openedAsPersonID == nil ? Self.unknownPersonMessage : Self.notOwnerMessage
            return
        }
        guard mayChangePeople(on: ranches[ranchIndex].id) else {
            message = Self.notOwnerMessage
            return
        }
        ranches[ranchIndex].people.remove(at: personIndex)
        if openedAsPersonID == id {
            openedAsPersonID = nil
        }
        persist(ranchID: ranches[ranchIndex].id)
    }

    /// Administrator sees every ranch. An opened person sees only their ranch.
    private var visibleRanches: [RanchOSPeopleRanch] {
        guard let id = openedAsPersonID, let found = personAndRanch(id: id) else {
            return ranches
        }
        return ranches.filter { $0.id == found.ranch.id }
    }

    /// Administrator changes any ranch. An owner changes only the opened ranch.
    private func mayChangePeople(on ranchID: UUID?) -> Bool {
        guard let openedID = openedAsPersonID else { return true }
        guard let ranchID,
              let found = personAndRanch(id: openedID),
              found.person.role == .owner
        else { return false }
        return found.ranch.id == ranchID
    }

    private func personAndRanch(id: UUID) -> (person: RanchOSPerson, ranch: RanchOSPeopleRanch)? {
        for ranch in ranches {
            if let person = ranch.people.first(where: { $0.id == id }) {
                return (person, ranch)
            }
        }
        return nil
    }

    private func indexOfPerson(id: UUID) -> (Int, Int)? {
        for (ranchIndex, ranch) in ranches.enumerated() {
            if let personIndex = ranch.people.firstIndex(where: { $0.id == id }) {
                return (ranchIndex, personIndex)
            }
        }
        return nil
    }

    private func persist(ranchID: UUID) {
        do {
            try writePeopleFile()
            savedRanchIDs.insert(ranchID)
            message = nil
        } catch {
            savedRanchIDs.remove(ranchID)
            message = Self.saveFailedMessage
        }
    }

    private func writePeopleFile() throws {
        let data = try Self.encoder.encode(SavedPeopleRanches(ranches: ranches))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func ranchFileURL(id: UUID) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("ranches", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".json")
    }

    private func writeRanchFile(_ ranch: RanchOSPeopleRanch) throws {
        let data = try Self.encoder.encode(RanchOSRanchFile(id: ranch.id, name: ranch.name))
        let url = ranchFileURL(id: ranch.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readRanchFile(id: UUID) -> RanchOSRanchFile? {
        guard let data = try? Data(contentsOf: ranchFileURL(id: id)),
              let file = try? JSONDecoder().decode(RanchOSRanchFile.self, from: data),
              file.id == id
        else { return nil }
        return file
    }

    private func ranchFileMatches(id: UUID) -> Bool {
        readRanchFile(id: id) != nil
    }

    private func ranchApplications(id: UUID) -> [RanchOSPeopleApplicationData] {
        guard let file = readRanchFile(id: id) else { return [] }
        return file.applications.map {
            RanchOSPeopleApplicationData(name: $0.name, dataName: $0.dataName)
        }
    }

    private func backfillRanchFiles() {
        for ranch in ranches {
            let expected = RanchOSRanchFile.canonicalApplications(for: ranch.id)
            if let file = readRanchFile(id: ranch.id), file.applications == expected {
                continue
            }
            let url = ranchFileURL(id: ranch.id)
            if FileManager.default.fileExists(atPath: url.path), readRanchFile(id: ranch.id) == nil {
                continue
            }
            try? writeRanchFile(ranch)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let app = Bundle.main.bundleIdentifier ?? "RanchOS"
        return base.appendingPathComponent(app, isDirectory: true).appendingPathComponent("people.json")
    }
}
