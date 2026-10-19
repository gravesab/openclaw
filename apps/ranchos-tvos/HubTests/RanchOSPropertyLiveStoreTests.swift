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
    func testRefreshAssetsCanKeepReadySummaryVisibleAcrossFailures() async {
        let spy = PropertyBoundarySpy()
        spy.keychainValue = "test-token-not-a-credential"
        let store = RanchOSPropertyLiveStore(
            mode: .standard,
            credentials: spy.access,
            transport: spy.transport,
            startsAutomaticRefresh: false)
        await store.refreshAssets()
        guard case .ready = store.assetsState else {
            return XCTFail("Expected an initial ready asset summary")
        }
        spy.statusCode = 503
        await store.refreshAssets(keepsVisibleSummary: true)
        guard case .ready = store.assetsState else {
            return XCTFail("A kept summary must stay visible when the refresh fails")
        }
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

    func testEstimatedMinutesAreReadAndFractionalValuesAreIgnored() throws {
        let data = try XCTUnwrap("""
        [{"id":"task-1","item":"Oil change","area":"Barn","estimated_minutes":90},{"id":"task-2","item":"Inspect","area":"Barn","estimated_minutes":30.5}]
        """.data(using: .utf8))

        let dashboard = try RanchOSPropertyLiveDashboard.decode(from: data)

        XCTAssertEqual(dashboard.tasks.first { $0.id == "task-1" }?.estimatedMinutes, 90)
        XCTAssertNil(dashboard.tasks.first { $0.id == "task-2" }?.estimatedMinutes)
    }

    func testAssetRollupTotalsTasksAndHoursAndKeepsAssetsWithNoTasks() throws {
        let mower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let barn = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let assets = try RanchOSPropertyLiveAsset.decode(from: Data("""
        [{"id":"\(mower.uuidString)","name":"DR mower"},{"id":"\(barn.uuidString)","name":"Equipment barn"}]
        """.utf8))
        let tasks = try RanchOSPropertyLiveDashboard.decode(from: Data("""
        [
          {"id":"t1","item":"DR mower: Oil","area":"Equipment","asset_id":"\(mower.uuidString)","estimated_minutes":90,"is_active":true},
          {"id":"t2","item":"DR mower: Blades","area":"Equipment","asset_id":"\(mower.uuidString)","estimated_minutes":30,"is_active":true},
          {"id":"t3","item":"Retired","area":"Equipment","asset_id":"\(mower.uuidString)","estimated_minutes":600,"is_active":false},
          {"id":"t4","item":"Orphan","area":"North","asset_id":"00000000-0000-0000-0000-000000000099","estimated_minutes":15,"is_active":true}
        ]
        """.utf8)).tasks

        let rollups = RanchOSPropertyAssetRollupBuilder.rollups(tasks: tasks, assets: assets)

        XCTAssertEqual(rollups.map(\.name), ["DR mower", "Equipment barn", "Unlinked tasks"])
        XCTAssertEqual(rollups[0].summary, "2 tasks · 2 hours")
        XCTAssertEqual(rollups[0].tasks.map(\.id), ["t2", "t1"])
        XCTAssertEqual(
            RanchOSPropertyAssetRollupBuilder.displayTitle("DR mower: Oil", group: "DR mower"),
            "Oil")
        XCTAssertEqual(rollups[1].summary, "0 tasks · 0 hours")
        XCTAssertEqual(rollups[2].tasks.map(\.id), ["t4"])
        XCTAssertEqual(RanchOSPropertyHours.label(minutes: 30), "0.5 hours")
        XCTAssertEqual(RanchOSPropertyHours.label(minutes: 60), "1 hour")
    }

    func testAssetDecodeReadsPMActiveTaskCountAndDefaultsMissingToZero() throws {
        let mower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let barn = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let group = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let assets = try RanchOSPropertyLiveAsset.decode(from: Data("""
        [
          {"id":"\(mower.uuidString)","name":"DR mower","pm_summary":{"active_task_count":2,"overdue_meter_count":0}},
          {"id":"\(barn.uuidString)","name":"Equipment barn"},
          {"id":"\(group.uuidString)","name":"Mowers","is_pseudo":true,"pm_summary":{"active_task_count":9}}
        ]
        """.utf8))

        XCTAssertEqual(assets.map(\.name), ["DR mower", "Equipment barn", "Mowers"])
        XCTAssertEqual(assets[0].activeTaskCount, 2)
        XCTAssertEqual(assets[0].activeTasksLabel, "2 active tasks")
        XCTAssertEqual(assets[1].activeTaskCount, 0)
        XCTAssertEqual(assets[1].activeTasksLabel, "0 active tasks")
        XCTAssertTrue(assets[2].isPseudo)
        XCTAssertEqual(assets[2].activeTaskCount, 0)
        XCTAssertEqual(
            RanchOSPropertyLiveAsset.summaryAssets(from: assets).map(\.name),
            ["DR mower", "Equipment barn"])
    }

    func testRelationshipSummaryGroupsHostedAssetsAndKeepsTaskCounts() throws {
        let group = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let mower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let deck = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let barn = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let welder = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let shop = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let assets = try RanchOSPropertyLiveAsset.decode(from: Data("""
        [
          {"id":"\(barn.uuidString)","name":"Equipment barn","pm_summary":{"active_task_count":0}},
          {"id":"\(deck.uuidString)","name":"Deck","host_asset_id":"\(mower.uuidString)","pm_summary":{"active_task_count":1}},
          {"id":"\(mower.uuidString)","name":"DR mower","host_asset_id":"\(group.uuidString)","host":{"id":"\(group.uuidString)","name":"Mowers","is_pseudo":true},"pm_summary":{"active_task_count":2}},
          {"id":"\(group.uuidString)","name":"Mowers","is_pseudo":true,"pm_summary":{"active_task_count":9}},
          {"id":"\(welder.uuidString)","name":"Welder","host_asset_id":"\(shop.uuidString)","host":{"id":"\(shop.uuidString)","name":"Shop","is_pseudo":false},"pm_summary":{"active_task_count":0}}
        ]
        """.utf8))

        let summaries = RanchOSPropertyLiveAsset.relationshipSummaries(from: assets)

        XCTAssertEqual(summaries.map(\.title), ["Mowers", "Equipment barn", "Welder"])
        XCTAssertEqual(summaries[0].detail, "2 assets · 3 active tasks")
        XCTAssertEqual(summaries[0].members.map(\.name), ["DR mower"])
        XCTAssertEqual(summaries[0].members[0].detail, "2 active tasks · includes Deck")
        XCTAssertEqual(summaries[1].detail, "0 active tasks")
        XCTAssertTrue(summaries[1].members.isEmpty)
        XCTAssertEqual(summaries[2].detail, "0 active tasks · on Shop")
        XCTAssertEqual(assets.first { $0.id == mower }?.hostName, "Mowers")
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
