import XCTest

/// People client slice: requests carry the session bearer plus the ranch
/// tenant header, success bodies decode into RanchOSPerson, and HTTP
/// failures map without touching any session. All transport is faked.
final class RanchOSPeopleClientTests: XCTestCase {
    private let tenantID = "tenant-a"
    private let personID = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"

    func testListSendsBearerTenantAndDecodesPeople() async throws {
        let transport = PeopleScriptedTransport(scripts: [
            .init(status: 200, body: """
            {"people":[
            {"user_id":"\(personID)","name":"Sam","email":"sam@ranchos.dev","role":"viewer"},
            {"user_id":"B2C3D4E5-6789-4ABC-DEF0-123456789012","name":"Jo","email":"jo@ranchos.dev","role":"manager"}],
            "actor_user_id":"\(personID)","can_manage":false}
            """),
        ])
        let client = makeClient(transport: transport)

        let list = try await client.list()

        XCTAssertEqual(list.people.count, 2)
        XCTAssertEqual(list.people[0].id, UUID(uuidString: personID))
        XCTAssertEqual(list.people[0].name, "Sam")
        XCTAssertEqual(list.people[0].email, "sam@ranchos.dev")
        XCTAssertEqual(list.people[0].role, .viewer)
        XCTAssertEqual(list.people[1].role, .manager)
        XCTAssertEqual(list.actorID, UUID(uuidString: personID))
        XCTAssertFalse(list.canManage)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/people")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)
        XCTAssertNil(request.httpBody)
    }

    func testInviteSendsJSONBodyAndDecodesPerson() async throws {
        let transport = PeopleScriptedTransport(scripts: [
            .init(status: 200, body: """
            {"user_id":"\(personID)","name":"Jo","email":"jo@ranchos.dev","role":"manager"}
            """),
        ])
        let client = makeClient(transport: transport)

        let person = try await client.invite(name: "Jo", email: "jo@ranchos.dev", role: .manager)

        XCTAssertEqual(person.id, UUID(uuidString: personID))
        XCTAssertEqual(person.name, "Jo")
        XCTAssertEqual(person.email, "jo@ranchos.dev")
        XCTAssertEqual(person.role, .manager)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/people/invite")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["name": "Jo", "email": "jo@ranchos.dev", "role": "manager"])
    }

    func testChangeRoleSendsLowercaseUserIDAndDecodesChange() async throws {
        let transport = PeopleScriptedTransport(scripts: [
            .init(status: 200, body: """
            {"user_id":"\(personID.lowercased())","role":"viewer"}
            """),
        ])
        let client = makeClient(transport: transport)
        let id = try XCTUnwrap(UUID(uuidString: personID))

        let change = try await client.changeRole(id: id, role: .viewer)

        XCTAssertEqual(change, RanchOSRoleChange(id: id, role: .viewer))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/people/role")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["user_id": personID.lowercased(), "role": "viewer"])
    }

    func testRevokeSendsUserIDAndSucceedsOnRemovedTrue() async throws {
        let transport = PeopleScriptedTransport(scripts: [
            .init(status: 200, body: #"{"removed":true}"#),
        ])
        let client = makeClient(transport: transport)
        let id = try XCTUnwrap(UUID(uuidString: personID))

        try await client.revoke(id: id)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/people/revoke")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["user_id": personID.lowercased()])
    }

    func testMissingTokenThrowsWithoutCallingTransport() async {
        let transport = PeopleScriptedTransport(scripts: [])
        let client = makeClient(transport: transport, token: nil)

        await expect(.unauthorized) { _ = try await client.list() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func test401MapsToUnauthorized() async {
        let transport = PeopleScriptedTransport(scripts: [.init(status: 401, body: "{}")])
        let client = makeClient(transport: transport)

        await expect(.unauthorized) { _ = try await client.list() }
    }

    func test403MapsToForbidden() async {
        let transport = PeopleScriptedTransport(scripts: [.init(status: 403, body: "{}")])
        let client = makeClient(transport: transport)

        await expect(.forbidden) { _ = try await client.list() }
    }

    func test404MapsToNotFound() async {
        let transport = PeopleScriptedTransport(scripts: [.init(status: 404, body: "{}")])
        let client = makeClient(transport: transport)

        await expect(.notFound) { _ = try await client.list() }
    }

    func test400MapsToRejectedWithServerMessage() async {
        let transport = PeopleScriptedTransport(scripts: [
            .init(status: 400, body: #"{"code":"tenant_context_invalid","message":"already on this ranch"}"#),
        ])
        let client = makeClient(transport: transport)

        await expect(.rejected("already on this ranch")) {
            _ = try await client.invite(name: "Sam", email: "sam@ranchos.dev", role: .viewer)
        }
    }

    // MARK: - Helpers

    private func makeClient(
        transport: PeopleScriptedTransport,
        token: String? = "session-token"
    ) -> RanchOSPeopleClient {
        RanchOSPeopleClient(
            baseURL: URL(string: "http://127.0.0.1:5063")!,
            tenantID: tenantID,
            token: { token },
            transport: transport)
    }

    private func expect(
        _ expected: RanchOSPeopleClientError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ call: () async throws -> Void
    ) async {
        do {
            try await call()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as RanchOSPeopleClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private final class PeopleScriptedTransport: RanchBrainHTTPTransport, @unchecked Sendable {
    struct Script {
        var status: Int
        var body: String
    }

    var scripts: [Script]
    private(set) var requests: [URLRequest] = []

    init(scripts: [Script]) { self.scripts = scripts }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let script = scripts.removeFirst()
        guard let url = request.url,
            let http = HTTPURLResponse(
                url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: [:])
        else {
            throw URLError(.badServerResponse)
        }
        return (Data(script.body.utf8), http)
    }
}
