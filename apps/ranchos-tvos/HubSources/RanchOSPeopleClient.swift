import Foundation

/// Failures from the people admin routes. The client holds no session
/// and purges nothing: a 401 only fails the call it answers.
enum RanchOSPeopleClientError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case rejected(String)
    case transport(String)
}

/// HTTP client for the people admin routes: one list plus invite, role
/// change, and revoke. Every request carries the session bearer and the
/// configured ranch tenant id. Stateless: the token comes from the
/// closure on every call, and no URLSession is built here.
struct RanchOSPeopleClient: Sendable {
    private let baseURL: URL
    private let tenantID: String
    private let token: @Sendable () -> String?
    private let transport: any RanchBrainHTTPTransport

    init(
        baseURL: URL,
        tenantID: String,
        token: @Sendable @escaping () -> String?,
        transport: any RanchBrainHTTPTransport
    ) {
        self.baseURL = baseURL
        self.tenantID = tenantID
        self.token = token
        self.transport = transport
    }

    func list() async throws -> RanchOSPeopleList {
        let body: PeopleListBody = try await send(path: "/v1/people", method: "GET", json: nil)
        guard let actorID = UUID(uuidString: body.actorUserID) else {
            throw RanchOSPeopleClientError.transport("People list has no actor.")
        }
        return RanchOSPeopleList(
            people: try body.people.map(Self.person(from:)),
            actorID: actorID,
            canManage: body.canManage)
    }

    func invite(name: String, email: String, role: RanchOSPersonRole) async throws -> RanchOSPerson {
        let body: PersonBody = try await send(
            path: "/v1/people/invite", method: "POST",
            json: ["name": name, "email": email, "role": role.rawValue])
        return try Self.person(from: body)
    }

    func changeRole(id: UUID, role: RanchOSPersonRole) async throws -> RanchOSRoleChange {
        let body: RoleBody = try await send(
            path: "/v1/people/role", method: "POST",
            json: ["user_id": id.uuidString.lowercased(), "role": role.rawValue])
        guard let uid = UUID(uuidString: body.userID),
            let newRole = RanchOSPersonRole(rawValue: body.role)
        else {
            throw RanchOSPeopleClientError.transport("Role body is not a role change.")
        }
        return RanchOSRoleChange(id: uid, role: newRole)
    }

    func revoke(id: UUID) async throws {
        let body: RemovedBody = try await send(
            path: "/v1/people/revoke", method: "POST",
            json: ["user_id": id.uuidString.lowercased()])
        guard body.removed else {
            throw RanchOSPeopleClientError.transport("Revoke was not confirmed.")
        }
    }

    // -- pipeline --------------------------------------------------

    private func send<T: Decodable>(path: String, method: String, json: [String: String]?) async throws -> T {
        guard let token = token() else { throw RanchOSPeopleClientError.unauthorized }
        let encoded: Data?
        do {
            encoded = try json.map { try JSONEncoder().encode($0) }
        } catch {
            throw RanchOSPeopleClientError.transport(error.localizedDescription)
        }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(suffix))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(tenantID, forHTTPHeaderField: "X-Ranch-Tenant")
        if let encoded {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encoded
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw RanchOSPeopleClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RanchOSPeopleClientError.transport("Non-HTTP response.")
        }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw RanchOSPeopleClientError.transport(error.localizedDescription)
            }
        case 401:
            throw RanchOSPeopleClientError.unauthorized
        case 403:
            throw RanchOSPeopleClientError.forbidden
        case 404:
            throw RanchOSPeopleClientError.notFound
        case 400...499:
            throw RanchOSPeopleClientError.rejected(Self.serverMessage(data, status: http.statusCode))
        default:
            throw RanchOSPeopleClientError.transport("Server error \(http.statusCode).")
        }
    }

    private static func person(from body: PersonBody) throws -> RanchOSPerson {
        guard let id = UUID(uuidString: body.userID),
            let role = RanchOSPersonRole(rawValue: body.role)
        else {
            throw RanchOSPeopleClientError.transport("Person body is not a ranch person.")
        }
        return RanchOSPerson(id: id, name: body.name, email: body.email, role: role)
    }

    private static func serverMessage(_ data: Data, status: Int) -> String {
        if let body = try? JSONDecoder().decode(PeopleErrorBody.self, from: data),
            let message = body.message, !message.isEmpty
        {
            return message
        }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }
}

/// The signed-in actor's view of the ranch roster.
struct RanchOSPeopleList: Equatable, Sendable {
    var people: [RanchOSPerson]
    var actorID: UUID
    var canManage: Bool
}

private struct PeopleListBody: Decodable {
    var people: [PersonBody]
    var actorUserID: String
    var canManage: Bool

    private enum CodingKeys: String, CodingKey {
        case people
        case actorUserID = "actor_user_id"
        case canManage = "can_manage"
    }
}

private struct PersonBody: Decodable {
    var userID: String
    var name: String
    var email: String
    var role: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case name, email, role
    }
}

/// The role route answers with the id and the role only.
struct RanchOSRoleChange: Equatable, Sendable {
    let id: UUID
    let role: RanchOSPersonRole
}

private struct RoleBody: Decodable {
    var userID: String
    var role: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
    }
}

private struct RemovedBody: Decodable {
    var removed: Bool
}

private struct PeopleErrorBody: Decodable {
    var code: String?
    var message: String?
}
