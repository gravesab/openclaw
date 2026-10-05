import XCTest

/// Live DEV session slice: sign-in fills the memory-only holder, then one
/// question reads RanchBrain. All transport is faked; the live check in
/// acceptance 4 is manual and is not in this file.
final class RanchOSJarvisDevSessionTests: XCTestCase {
    private let tenantID = RanchOSJarvisDevSession.tenantID

    // MARK: - Acceptance 1: no session, fixture answer, zero transport calls

    @MainActor
    func testNoSessionUsesFixtureAnswerSignInSentenceAndZeroTransportCalls() async {
        let transport = DevScriptedTransport(scripts: [])
        let holder = RanchBrainSessionHolder()
        let store = makeStore(holder: holder, transport: transport, signer: nil)
        store.question = "Who is Maple?"

        await store.askWithUnderstanding()

        XCTAssertEqual(store.answer?.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.signInSentence)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(store.isSignedIn)
    }

    // MARK: - Acceptance 2: tenant header up front, session bearer after

    func testFakeSessionIssueSendsNamedTenantAndSearchUsesSessionBearer() async throws {
        let sessionBody = """
        {"token":"rbs_dev_test","expires_at":"2030-01-01T00:00:00Z","tenant_id":"\(tenantID)"}
        """
        let searchBody = """
        {"tenant_id":"\(tenantID)","profile":"knowledge","total":1,"hits":[
        {"source":"herd.md","line":1,"text":"Twelve head.","modified_at":"2026-10-01T00:00:00Z","indexed_at":"2026-10-01T00:00:00Z"}]}
        """
        let transport = DevScriptedTransport(scripts: [
            DevScriptedTransport.Script(status: 200, body: sessionBody, headers: [:]),
            DevScriptedTransport.Script(status: 200, body: searchBody, headers: [:]),
        ])
        let holder = RanchBrainSessionHolder()
        let client = makeClient(transport: transport, holder: holder)

        let session = try await client.issueSession(googleToken: "google-id-token", tenantID: tenantID)
        XCTAssertEqual(session.token, "rbs_dev_test")
        XCTAssertEqual(session.tenantID, tenantID)
        XCTAssertEqual(holder.currentSession()?.token, "rbs_dev_test")

        let issue = transport.requests.first
        let issueAuthz = issue?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(issueAuthz.hasPrefix("Bearer "))
        XCTAssertTrue(issueAuthz.hasSuffix("google-id-token"))
        XCTAssertEqual(issue?.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)

        let hits = try await client.searchKnowledge(question: "how many?")
        XCTAssertEqual(hits.count, 1)

        let search = transport.requests.last
        let searchAuthz = search?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(searchAuthz.hasPrefix("Bearer "))
        XCTAssertTrue(searchAuthz.hasSuffix("rbs_dev_test"))
        XCTAssertEqual(search?.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)
        XCTAssertFalse(search?.value(forHTTPHeaderField: "Authorization")?.contains("google-id-token") ?? true)
    }

    // MARK: - Acceptance 3: 401 purges and shows expired through the store

    @MainActor
    func testUnauthorizedPurgesHolderAndShowsExpiredThroughStore() async {
        let transport = DevScriptedTransport(scripts: [
            DevScriptedTransport.Script(status: 401, body: "{}", headers: [:]),
        ])
        let holder = RanchBrainSessionHolder()
        holder.store(RanchBrainSession(
            token: "rbs_stale", expiresAt: Date.distantFuture, tenantID: tenantID))
        let store = makeStore(holder: holder, transport: transport, signer: nil)
        store.question = "Who is Maple?"

        await store.askWithUnderstanding()

        XCTAssertNil(holder.currentSession())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.sessionExpiredSentence)
        XCTAssertEqual(store.answer?.provenance, RanchOSJarvis.provenanceLabel)
    }

    // MARK: - Provider request shape (pure, no browser)

    func testDevTenantIDIsTheLiveDEVValue() {
        XCTAssertEqual(tenantID, "11111111-2222-4333-8444-555555555501")
    }

    func testAuthorizationURLRequestsClaimsMaxAgeScopeAndPKCE() {
        let scheme = "com.googleusercontent.apps.test-core"
        let url = RanchOSJarvisDevSession.authorizationURL(
            clientID: "test-core.apps.googleusercontent.com",
            callbackScheme: scheme,
            state: "test-state",
            nonce: "test-nonce",
            verifier: "test-verifier")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var values: [String: String] = [:]
        for item in items {
            if let value = item.value { values[item.name] = value }
        }

        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["scope"], "openid email")
        XCTAssertEqual(values["max_age"], "300")
        XCTAssertEqual(values["claims"], RanchOSJarvisDevSession.claimsParameter)
        XCTAssertTrue(values["claims"]?.contains("auth_time") ?? false)
        XCTAssertTrue(values["claims"]?.contains("\"amr\"") ?? false)
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(
            values["code_challenge"],
            RanchOSJarvisDevSession.pkceChallenge(verifier: "test-verifier"))
        XCTAssertEqual(values["redirect_uri"], scheme + ":/oauth2redirect")
        XCTAssertEqual(values["state"], "test-state")
        XCTAssertEqual(values["nonce"], "test-nonce")
        XCTAssertFalse(values.keys.contains("client_secret"))
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        XCTAssertEqual(
            RanchOSJarvisDevSession.pkceChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCallbackSchemeRoundTripsClientID() {
        let clientID = "12345-abc.apps.googleusercontent.com"
        let scheme = RanchOSJarvisDevSession.callbackScheme(clientID: clientID)
        XCTAssertEqual(scheme, "com.googleusercontent.apps.12345-abc")
        XCTAssertEqual(RanchOSJarvisDevSession.clientID(callbackScheme: scheme!), clientID)
        XCTAssertNil(RanchOSJarvisDevSession.callbackScheme(clientID: "not-a-client-id"))
        XCTAssertNil(RanchOSJarvisDevSession.clientID(callbackScheme: "com.example.app"))
    }

    func testAuthorizationCodeParsingAcceptsDeniesAndRejects() throws {
        let good = URL(string: "com.googleusercontent.apps.x:/oauth2redirect?code=auth-code&state=s1")!
        XCTAssertEqual(
            try RanchOSJarvisDevSession.authorizationCode(callbackURL: good, expectedState: "s1"),
            "auth-code")

        let denied = URL(string: "com.googleusercontent.apps.x:/oauth2redirect?error=access_denied&state=s1")!
        XCTAssertThrowsError(
            try RanchOSJarvisDevSession.authorizationCode(callbackURL: denied, expectedState: "s1"))

        let wrongState = URL(string: "com.googleusercontent.apps.x:/oauth2redirect?code=auth-code&state=s2")!
        XCTAssertThrowsError(
            try RanchOSJarvisDevSession.authorizationCode(callbackURL: wrongState, expectedState: "s1"))

        let missingCode = URL(string: "com.googleusercontent.apps.x:/oauth2redirect?state=s1")!
        XCTAssertThrowsError(
            try RanchOSJarvisDevSession.authorizationCode(callbackURL: missingCode, expectedState: "s1"))
    }

    func testGoogleClientConfigReadsRegisteredScheme() throws {
        let plist: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["com.example.other"]],
                ["CFBundleURLSchemes": ["com.googleusercontent.apps.bundle-test"]],
            ],
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: directory) else {
            return XCTFail("test bundle did not load")
        }

        let config = RanchOSJarvisLiveSessionProvider.googleClientConfig(bundle: bundle)
        XCTAssertEqual(config?.scheme, "com.googleusercontent.apps.bundle-test")
        XCTAssertEqual(config?.clientID, "bundle-test.apps.googleusercontent.com")
        XCTAssertNil(RanchOSJarvisLiveSessionProvider.googleClientConfig(bundle: .main))
    }

    // MARK: - Live provider issue mapping (fake browser + fake transport)

    @MainActor
    func testLiveProviderForbiddenIssueMapsToNotLinked() async {
        let transport = DevScriptedTransport(scripts: [
            DevScriptedTransport.Script(
                status: 200,
                body: #"{"id_token":"google-id-token","token_type":"Bearer"}"#,
                headers: [:]),
            DevScriptedTransport.Script(status: 403, body: "{}", headers: [:]),
        ])
        let holder = RanchBrainSessionHolder()
        let provider = RanchOSJarvisLiveSessionProvider(
            client: makeClient(transport: transport, holder: holder),
            transport: transport,
            clientConfig: (
                clientID: "test-core.apps.googleusercontent.com",
                scheme: "com.googleusercontent.apps.test-core"),
            authCodeRunner: { _, _ in "test-code" })

        do {
            _ = try await provider.signIn()
            XCTFail("403 issue must throw")
        } catch let error as RanchOSJarvisSignInError {
            XCTAssertEqual(error, .forbiddenNotLinked)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNil(holder.currentSession())

        let exchange = transport.requests.first
        let exchangeBody = exchange?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(exchangeBody.contains("grant_type=authorization_code"))
        XCTAssertTrue(exchangeBody.contains("code_verifier="))
        XCTAssertFalse(exchangeBody.contains("client_secret"))
        let issue = transport.requests.last
        XCTAssertEqual(issue?.value(forHTTPHeaderField: "X-Ranch-Tenant"), tenantID)
    }

    @MainActor
    func testLiveProviderSuccessStoresSessionFromIssue() async throws {
        let transport = DevScriptedTransport(scripts: [
            DevScriptedTransport.Script(
                status: 200,
                body: #"{"id_token":"google-id-token","token_type":"Bearer"}"#,
                headers: [:]),
            DevScriptedTransport.Script(
                status: 200,
                body: #"{"token":"rbs_live_test","expires_at":"2030-01-01T00:00:00Z","tenant_id":"\#(tenantID)"}"#,
                headers: [:]),
        ])
        let holder = RanchBrainSessionHolder()
        let provider = RanchOSJarvisLiveSessionProvider(
            client: makeClient(transport: transport, holder: holder),
            transport: transport,
            clientConfig: (
                clientID: "test-core.apps.googleusercontent.com",
                scheme: "com.googleusercontent.apps.test-core"),
            authCodeRunner: { _, _ in "test-code" })

        let session = try await provider.signIn()
        XCTAssertEqual(session.token, "rbs_live_test")
        XCTAssertEqual(holder.currentSession()?.token, "rbs_live_test")
    }

    // MARK: - Acceptance 5-7: signed-out, in-progress, active

    @MainActor
    func testSignedOutState() {
        let store = makeStore(
            holder: RanchBrainSessionHolder(),
            transport: DevScriptedTransport(scripts: []),
            signer: nil)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertFalse(store.isSigningIn)
        XCTAssertEqual(store.workspaceStatusText(), "Ready · Fixture")
    }

    @MainActor
    func testSigningInProgressThenCancel() async throws {
        let holder = RanchBrainSessionHolder()
        let signer = DevFakeSigner(
            holder: holder,
            script: .gateThenSucceed(RanchBrainSession(
                token: "rbs_never", expiresAt: Date.distantFuture, tenantID: tenantID)))
        let store = makeStore(holder: holder, transport: DevScriptedTransport(scripts: []), signer: signer)

        let task = Task { await store.signIn() }
        var sawSigningIn = false
        for _ in 0..<200 {
            if store.isSigningIn {
                sawSigningIn = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawSigningIn)

        store.cancelSignIn()
        await task.value

        XCTAssertFalse(store.isSigningIn)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(holder.currentSession())
        XCTAssertNil(store.understandingLabel)
    }

    @MainActor
    func testActiveSessionShowsSignedInAndRanchBrainStatus() {
        let holder = RanchBrainSessionHolder()
        holder.store(RanchBrainSession(
            token: "rbs_active", expiresAt: Date.distantFuture, tenantID: tenantID))
        let store = makeStore(holder: holder, transport: DevScriptedTransport(scripts: []), signer: nil)

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.workspaceStatusText(), "Ready · RanchBrain")
    }

    @MainActor
    func testListeningKeepsPrecedenceOverSessionStatus() {
        let engine = DevFakeSpeechEngine()
        let holder = RanchBrainSessionHolder()
        holder.store(RanchBrainSession(
            token: "rbs_active", expiresAt: Date.distantFuture, tenantID: tenantID))
        let store = RanchOSJarvisStore(
            speechEngine: engine,
            fmUsableOverride: false,
            retriever: RanchBrainRetriever(
                sessionProvider: holder,
                search: DevCountingSearch(),
                now: { Date() }))

        store.startTalking()
        engine.handler?(.partialTranscript("hello"))

        XCTAssertEqual(store.workspaceStatusText(), "Listening…")
    }

    @MainActor
    func testSignOutPurgesHolder() async {
        let holder = RanchBrainSessionHolder()
        holder.store(RanchBrainSession(
            token: "rbs_active", expiresAt: Date.distantFuture, tenantID: tenantID))
        let signer = DevFakeSigner(holder: holder, script: .succeed(RanchBrainSession(
            token: "rbs_unused", expiresAt: Date.distantFuture, tenantID: tenantID)))
        let store = makeStore(holder: holder, transport: DevScriptedTransport(scripts: []), signer: signer)
        XCTAssertTrue(store.isSignedIn)

        await store.signOut()

        XCTAssertNil(holder.currentSession())
        XCTAssertFalse(store.isSignedIn)
    }

    // MARK: - Acceptance 8: provenance replaces the fixture caption

    @MainActor
    func testProvenanceReplacesFixtureCaption() async {
        let search = DevCountingSearch(hits: [RanchBrainKnowledgeHit(
            text: "Twelve head in the east.", source: "herd.md", indexedAt: Date())])
        let holder = RanchBrainSessionHolder()
        holder.store(RanchBrainSession(
            token: "rbs_active", expiresAt: Date.distantFuture, tenantID: tenantID))
        let store = RanchOSJarvisStore(
            fmUsableOverride: false,
            retriever: RanchBrainRetriever(sessionProvider: holder, search: search, now: { Date() }))
        XCTAssertEqual(store.captionText, RanchOSJarvis.provenanceLabel)
        store.question = "How is the herd?"

        await store.askWithUnderstanding()

        XCTAssertTrue(store.captionText.hasPrefix("RanchBrain · herd.md · indexed"))
        XCTAssertFalse(store.captionText.contains("sample herd"))
        XCTAssertEqual(store.captionText, store.answer?.provenance)
    }

    // MARK: - Failed issue never looks signed in

    @MainActor
    func testForbiddenIssueKeepsSampleHerdAndSignInSentence() async {
        let holder = RanchBrainSessionHolder()
        let signer = DevFakeSigner(holder: holder, script: .fail(.forbiddenNotLinked))
        let store = makeStore(holder: holder, transport: DevScriptedTransport(scripts: []), signer: signer)
        store.question = "Who is Maple?"

        await store.signIn()

        XCTAssertNil(holder.currentSession())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.signInSentence)

        await store.askWithUnderstanding()
        XCTAssertEqual(store.answer?.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.signInSentence)
    }

    @MainActor
    func testUnauthorizedIssueShowsSignInSentence() async {
        let holder = RanchBrainSessionHolder()
        let signer = DevFakeSigner(holder: holder, script: .fail(.unauthorized))
        let store = makeStore(holder: holder, transport: DevScriptedTransport(scripts: []), signer: signer)

        await store.signIn()

        XCTAssertNil(holder.currentSession())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.signInSentence)
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        holder: RanchBrainSessionHolder,
        transport: DevScriptedTransport,
        signer: DevFakeSigner?
    ) -> RanchOSJarvisStore {
        RanchOSJarvisStore(
            fmUsableOverride: false,
            retriever: RanchBrainRetriever(
                sessionProvider: holder,
                search: makeClient(transport: transport, holder: holder),
                now: { Date() }),
            sessionSigner: signer)
    }

    private func makeClient(
        transport: DevScriptedTransport,
        holder: RanchBrainSessionHolder
    ) -> RanchBrainClient {
        RanchBrainClient(
            baseURL: URL(string: "http://127.0.0.1:5063")!,
            tenantID: tenantID,
            token: { holder.currentSession()?.token },
            transport: transport,
            sleeper: DevRecordingSleeper(),
            sessionHolder: holder)
    }
}

private final class DevFixedSession: RanchBrainSessionProviding, @unchecked Sendable {
    var session: RanchBrainSession?
    init(session: RanchBrainSession?) { self.session = session }
    func currentSession() -> RanchBrainSession? { session }
}

private final class DevCountingSearch: RanchBrainKnowledgeSearching, @unchecked Sendable {
    var hits: [RanchBrainKnowledgeHit]
    var error: Error?
    private(set) var questions: [String] = []

    init(hits: [RanchBrainKnowledgeHit] = [], error: Error? = nil) {
        self.hits = hits
        self.error = error
    }

    func searchKnowledge(question: String) async throws -> [RanchBrainKnowledgeHit] {
        questions.append(question)
        if let error { throw error }
        return hits
    }
}

@MainActor
private final class DevFakeSigner: RanchOSJarvisSessionSigning, @unchecked Sendable {
    enum Script {
        case succeed(RanchBrainSession)
        case fail(RanchOSJarvisSignInError)
        case gateThenSucceed(RanchBrainSession)
    }

    private let lock = NSLock()
    private let holder: RanchBrainSessionHolder
    private let script: Script
    private var continuation: CheckedContinuation<Void, Error>?

    init(holder: RanchBrainSessionHolder, script: Script) {
        self.holder = holder
        self.script = script
    }

    func signIn() async throws -> RanchBrainSession {
        switch script {
        case .succeed(let session):
            holder.store(session)
            return session
        case .fail(let error):
            throw error
        case .gateThenSucceed(let session):
            try await withCheckedThrowingContinuation { continuation in
                locked { self.continuation = continuation }
            }
            holder.store(session)
            return session
        }
    }

    func cancelSignIn() {
        locked {
            continuation?.resume(throwing: RanchOSJarvisSignInError.cancelled)
            continuation = nil
        }
    }

    func signOut() async {
        holder.purge()
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}

private final class DevFakeSpeechEngine: RanchOSJarvisSpeechEngine {
    var handler: (@Sendable (RanchOSJarvisSpeechEvent) -> Void)?
    func startListening(eventHandler: @escaping @Sendable (RanchOSJarvisSpeechEvent) -> Void) {
        handler = eventHandler
    }
    func stopListening() {}
    func cancelListening() {}
}

private final class DevScriptedTransport: RanchBrainHTTPTransport, @unchecked Sendable {
    struct Script {
        var status: Int
        var body: String
        var headers: [String: String]
    }

    var scripts: [Script]
    private(set) var requests: [URLRequest] = []

    init(scripts: [Script]) { self.scripts = scripts }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let script = scripts.removeFirst()
        guard let url = request.url,
            let http = HTTPURLResponse(
                url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)
        else {
            throw URLError(.badServerResponse)
        }
        return (Data(script.body.utf8), http)
    }
}

private final class DevRecordingSleeper: RanchBrainSleeper, @unchecked Sendable {
    private(set) var slept: [Int] = []
    func sleep(seconds: Int) async throws { slept.append(seconds) }
}
