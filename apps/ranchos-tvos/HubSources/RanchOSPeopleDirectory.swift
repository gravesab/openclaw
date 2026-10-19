import Foundation

/// One person's ranch-wide role. It covers every RanchOS component.
enum RanchOSPersonRole: String, CaseIterable, Identifiable, Sendable {
    case owner
    case manager
    case viewer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .owner: "Owner"
        case .manager: "Manager"
        case .viewer: "Viewer"
        }
    }
}

struct RanchOSPerson: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var email: String
    var role: RanchOSPersonRole
}

enum RanchOSPeopleError: Error, Equatable, Sendable {
    case notAllowed
    case duplicateEmail
    case lastOwner
    case unknownPerson
    case invalidName
    case invalidEmail
}

/// In-memory directory of who can sign in to one ranch.
///
/// Only an owner manages membership. The actor's person id and role are
/// known to the directory; every invite, role change, and revocation is
/// checked against them. Nothing here touches the network or storage.
@Observable
final class RanchOSPeopleDirectory {
    var actorPersonID: UUID
    var actorRole: RanchOSPersonRole
    private(set) var people: [RanchOSPerson]

    init(actorPersonID: UUID, actorRole: RanchOSPersonRole, people: [RanchOSPerson] = []) {
        self.actorPersonID = actorPersonID
        self.actorRole = actorRole
        self.people = people
    }

    /// True only for an owner. Managers and viewers see the list read-only.
    var canManage: Bool { actorRole == .owner }

    /// Adds one active person on this ranch.
    @discardableResult
    func invite(name: String, email: String, role: RanchOSPersonRole) throws -> RanchOSPerson {
        guard canManage else { throw RanchOSPeopleError.notAllowed }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw RanchOSPeopleError.invalidName }
        let cleanEmail = Self.normalizedEmail(email)
        guard Self.isValidEmail(cleanEmail) else { throw RanchOSPeopleError.invalidEmail }
        guard !people.contains(where: { $0.email.lowercased() == cleanEmail }) else {
            throw RanchOSPeopleError.duplicateEmail
        }
        let person = RanchOSPerson(id: UUID(), name: cleanName, email: cleanEmail, role: role)
        people.append(person)
        return person
    }

    /// Changes one active person's ranch-wide role.
    func changeRole(id: UUID, role: RanchOSPersonRole) throws {
        guard canManage else { throw RanchOSPeopleError.notAllowed }
        guard let index = people.firstIndex(where: { $0.id == id }) else {
            throw RanchOSPeopleError.unknownPerson
        }
        if people[index].role == .owner, role != .owner, ownerCount == 1 {
            throw RanchOSPeopleError.lastOwner
        }
        people[index].role = role
        if id == actorPersonID {
            actorRole = role
        }
    }

    /// Removes one active person from this ranch.
    func revoke(id: UUID) throws {
        guard canManage else { throw RanchOSPeopleError.notAllowed }
        guard let index = people.firstIndex(where: { $0.id == id }) else {
            throw RanchOSPeopleError.unknownPerson
        }
        if people[index].role == .owner, ownerCount == 1 {
            throw RanchOSPeopleError.lastOwner
        }
        people.remove(at: index)
        if id == actorPersonID {
            actorRole = .viewer
        }
    }

    /// Directory with a single seeded owner for DEV previews and the app.
    static func developmentOwner() -> RanchOSPeopleDirectory {
        let owner = RanchOSPerson(
            id: UUID(),
            name: "Ranch owner",
            email: "owner@ranchos.dev",
            role: .owner)
        return RanchOSPeopleDirectory(
            actorPersonID: owner.id,
            actorRole: .owner,
            people: [owner])
    }

    private var ownerCount: Int {
        people.filter { $0.role == .owner }.count
    }

    private static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[1].contains(".")
    }
}
