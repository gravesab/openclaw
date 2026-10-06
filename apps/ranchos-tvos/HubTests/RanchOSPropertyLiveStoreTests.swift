import XCTest

final class RanchOSPropertyLiveStoreTests: XCTestCase {
    func testLiveTaskPayloadDecodesOnlyReadableTaskFields() throws {
        let data = try XCTUnwrap("""
        [{"id":"task-1","item":"Inspect north gate","area":"North pasture","next_due":"2026-09-18T10:00:00.000Z","is_active":true,"priority":"High"}]
        """.data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(dashboard.activeTaskCount, 1)
        XCTAssertEqual(dashboard.tasks.first?.title, "Inspect north gate")
        XCTAssertEqual(dashboard.tasks.first?.area, "North pasture")
        XCTAssertEqual(dashboard.tasks.first?.detail, "North pasture · Due 2026-09-18T10:00:00.000Z")
    }

    func testMalformedLiveTaskIsExcludedRatherThanInvented() throws {
        let data = try XCTUnwrap("[{\"id\":\"task-1\"},{\"id\":\"task-2\",\"item\":\"Inspect water\"}]".data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(dashboard.tasks.map(\.id), ["task-2"])
    }

    @MainActor
    func testOfflineInitializationAndRefreshNeverTouchCredentialsOrTransport() async {
        let spy = PropertyBoundarySpy()
        let store = RanchOSPropertyLiveStore(
            mode: .offlineVerification,
            credentials: spy.access,
            transport: spy.transport,
            startsAutomaticRefresh: true)

        XCTAssertEqual(store.state, .unavailable(RanchOSPropertyLiveStore.offlineUnavailableMessage))
        XCTAssertEqual(spy.environmentReads, 0)
        XCTAssertEqual(spy.keychainReads, 0)
        XCTAssertEqual(spy.keychainWrites, 0)
        XCTAssertEqual(spy.transportSends, 0)

        await store.refresh()
        await store.refreshAssets()

        XCTAssertEqual(store.assetsState, .unavailable(RanchOSPropertyLiveStore.offlineUnavailableMessage))
        XCTAssertEqual(store.state, .unavailable(RanchOSPropertyLiveStore.offlineUnavailableMessage))
        XCTAssertTrue(spy.operations.isEmpty)
    }

    @MainActor
    func testStandardRefreshUsesInjectedCredentialAndTransport() async {
        let spy = PropertyBoundarySpy()
        spy.keychainValue = "test-token-not-a-credential"
        let payload = Data(#"[{"id":"task-9","item":"Check fence","area":"South","is_active":true}]"#.utf8)
        spy.responseData = payload
        let store = RanchOSPropertyLiveStore(
            mode: .standard,
            credentials: spy.access,
            transport: spy.transport,
            startsAutomaticRefresh: false)

        XCTAssertEqual(spy.environmentReads, 1)
        XCTAssertEqual(spy.keychainWrites, 0)
        XCTAssertEqual(spy.transportSends, 0)

        await store.refresh()

        XCTAssertEqual(spy.keychainReads, 1)
        XCTAssertEqual(spy.transportSends, 1)
        XCTAssertEqual(spy.sentRequests.first?.httpMethod, "GET")
        XCTAssertEqual(spy.sentRequests.first?.url?.path, "/tasks")
        if case .ready(let dashboard) = store.state {
            XCTAssertEqual(dashboard.tasks.map(\.id), ["task-9"])
        } else {
            XCTFail("Expected the injected transport response to become ready")
        }
    }

    @MainActor
    func testStandardInitializationImportsEnvironmentCredentialThroughTheBoundary() {
        let spy = PropertyBoundarySpy()
        spy.environmentValue = "test-token-not-a-credential"
        _ = RanchOSPropertyLiveStore(
            mode: .standard,
            credentials: spy.access,
            transport: spy.transport,
            startsAutomaticRefresh: false)

        XCTAssertEqual(spy.environmentReads, 1)
        XCTAssertEqual(spy.keychainWrites, 1)
        XCTAssertEqual(spy.writtenCredentials, ["test-token-not-a-credential"])
        XCTAssertEqual(spy.keychainReads, 0)
        XCTAssertEqual(spy.transportSends, 0)
    }

    @MainActor
    func testAssetsReadUsesExistingEndpointAndLeavesTaskStateIndependent() async {
        let spy = PropertyBoundarySpy()
        spy.keychainValue = "test-token-not-a-credential"
        let store = RanchOSPropertyLiveStore(mode: .standard, credentials: spy.access, transport: spy.transport, startsAutomaticRefresh: false)
        await store.refresh()
        let taskState = store.state
        await store.refreshAssets()
        XCTAssertEqual(store.assetsState, .ready([]))
        XCTAssertEqual(store.state, taskState)
        XCTAssertEqual(spy.sentRequests.last?.url?.path, "/v1/assets")
        XCTAssertEqual(spy.sentRequests.last?.url?.host, spy.sentRequests.first?.url?.host)
        XCTAssertEqual(spy.sentRequests.last?.httpMethod, "GET")
        XCTAssertEqual(spy.sentRequests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-not-a-credential")
        spy.responseData = Data("{\"unexpected\":[]}".utf8)
        await store.refreshAssets()
        guard case .unavailable = store.assetsState else { return XCTFail("Malformed response must be unavailable") }
        XCTAssertEqual(store.state, taskState)
        spy.responseData = Data("[]".utf8)
        await store.refresh()
        XCTAssertEqual(store.state, taskState)
    }

    @MainActor
    func testAssetsHTTPFailureDoesNotReplaceReadyTasks() async {
        let spy = PropertyBoundarySpy()
        spy.keychainValue = "test-token-not-a-credential"
        let store = RanchOSPropertyLiveStore(mode: .standard, credentials: spy.access, transport: spy.transport, startsAutomaticRefresh: false)
        await store.refresh()
        let before = store.state
        spy.statusCode = 503
        await store.refreshAssets()
        XCTAssertEqual(store.assetsState, .unavailable("PropertyManager DEV is unavailable (HTTP 503)."))
        XCTAssertEqual(store.state, before)
    }

    @MainActor
    func testCancelledAssetReadNeverPublishesResponse() async {
        let spy = PropertyBoundarySpy()
        spy.keychainValue = "test-token-not-a-credential"
        let transport = RanchOSPropertyTransport { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = RanchOSPropertyLiveStore(mode: .standard, credentials: spy.access, transport: transport, startsAutomaticRefresh: false)
        let operation = Task { await store.refreshAssets() }
        await operation.value
        XCTAssertEqual(store.assetsState, .idle)
    }

    func testOfflineVerificationArgumentIsSessionOnly() {
        XCTAssertEqual(
            RanchOSLaunchMode.resolve(arguments: ["RanchOS", "--ranchos-offline-verification"]),
            .offlineVerification)
        XCTAssertEqual(
            RanchOSLaunchMode.resolve(arguments: ["RanchOS", "--ranchos-offline-verification-extra"]),
            .standard)
        XCTAssertEqual(RanchOSLaunchMode.resolve(arguments: ["RanchOS"]), .standard)
    }
}

private final class PropertyBoundarySpy: @unchecked Sendable {
    var environmentReads = 0
    var keychainReads = 0
    var keychainWrites = 0
    var transportSends = 0
    var environmentValue: String?
    var keychainValue: String?
    var writtenCredentials: [String] = []
    var sentRequests: [URLRequest] = []
    var responseData = Data("[]".utf8)
    var statusCode = 200

    var operations: [String] {
        var names: [String] = []
        if environmentReads > 0 { names.append("environment") }
        if keychainReads > 0 { names.append("keychain-read") }
        if keychainWrites > 0 { names.append("keychain-write") }
        if transportSends > 0 { names.append("transport") }
        return names
    }

    var access: RanchOSPropertyCredentialAccess {
        RanchOSPropertyCredentialAccess(
            readEnvironment: {
                self.environmentReads += 1
                return self.environmentValue
            },
            readKeychain: {
                self.keychainReads += 1
                return self.keychainValue
            },
            writeKeychain: { credential in
                self.keychainWrites += 1
                self.writtenCredentials.append(credential)
            })
    }

    var transport: RanchOSPropertyTransport {
        RanchOSPropertyTransport { request in
            self.transportSends += 1
            self.sentRequests.append(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1/tasks")!,
                statusCode: self.statusCode,
                httpVersion: nil,
                headerFields: nil)!
            return (self.responseData, response)
        }
    }
}
