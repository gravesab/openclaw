import XCTest

final class RanchBrainRetrievalTests: XCTestCase {
    private let now = RanchBrainFacts.utcDate(year: 2026, month: 10, day: 3)

    func testAgeLabelsTodayRecentAndStale() {
        let today = RanchBrainFacts.provenance(sourceBasename: "herd.md", indexedAt: now, now: now)
        let recent = RanchBrainFacts.provenance(
            sourceBasename: "maple.md",
            indexedAt: RanchBrainFacts.utcDate(year: 2026, month: 10, day: 1),
            now: now)
        let stale = RanchBrainFacts.provenance(
            sourceBasename: "herd.md",
            indexedAt: RanchBrainFacts.utcDate(year: 2026, month: 8, day: 19),
            now: now)

        XCTAssertEqual(today, "RanchBrain · herd.md · indexed today")
        XCTAssertEqual(recent, "RanchBrain · maple.md · indexed 2d ago")
        XCTAssertEqual(stale, "RanchBrain · herd.md · indexed 45d ago · verify")
        XCTAssertEqual(
            RanchBrainFacts.dayCount(
                from: RanchBrainFacts.utcDate(year: 2026, month: 8, day: 19), to: now),
            45)
    }

    func testJoinedFactTextTruncatesAt2000Characters() {
        let fact = RanchBrainFact(
            text: String(repeating: "a", count: 2001),
            sourceBasename: "herd.md",
            indexedAt: now)
        XCTAssertEqual(RanchBrainFacts.joinedText([fact]).count, 2000)
    }

    func testTwoHitsShapeOnlyRetrievedFactsAndRecordEncodedQuestion() async {
        let old = RanchBrainFacts.utcDate(year: 2026, month: 8, day: 19)
        let recent = RanchBrainFacts.utcDate(year: 2026, month: 10, day: 1)
        let body = """
        {"tenant_id":"tenant-1","profile":"knowledge","total":2,"hits":[
        {"source":"herd.md","line":1,"text":"Twelve head in the east.","modified_at":"2026-08-19T00:00:00Z","indexed_at":"2026-08-19T00:00:00Z"},
        {"source":"maple.md","line":4,"text":"Maple is listed.","modified_at":"2026-10-01T00:00:00Z","indexed_at":"2026-10-01T00:00:00Z"}]}
        """
        let transport = ScriptedTransport(scripts: [
            ScriptedTransport.Script(status: 200, body: body, headers: [:]),
        ])
        let holder = signedInHolder()
        let client = makeClient(transport: transport, holder: holder, sleeper: RecordingSleeper())
        let retriever = RanchBrainRetriever(sessionProvider: holder, search: client, now: frozenNow)
        let shaper = CaptureShaper(shaped: "Twelve head.")
        let outcome = await retriever.fetch(question: "how many head?")

        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "how many head?",
            shaper: shaper,
            fmUsableOverride: true,
            retrieval: outcome,
            now: now)

        let expectedFacts = "Twelve head in the east. Maple is listed."
        XCTAssertEqual(shaper.facts, expectedFacts)
        XCTAssertEqual(reply.text, "Twelve head.")
        XCTAssertEqual(
            reply.provenance,
            "RanchBrain · herd.md · indexed 45d ago · verify | RanchBrain · maple.md · indexed 2d ago")
        XCTAssertFalse(reply.provenance.contains(RanchOSJarvis.provenanceLabel))
        XCTAssertEqual(decision.route, .onDeviceUnderstanding)
        let url = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/v1/search/knowledge/how%20many%20head%3F"), url)
        XCTAssertTrue(url.contains("limit=5"), url)
        XCTAssertEqual(transport.requests.count, 1)
        assertNoCredentials(in: shaper.seen)
        XCTAssertEqual(old.timeIntervalSince1970 > 0, true)
        XCTAssertEqual(recent.timeIntervalSince1970 > old.timeIntervalSince1970, true)
    }

    func testZeroHitsStayOnTheFixtureLabel() async {
        let search = CountingSearch()
        let retriever = RanchBrainRetriever(
            sessionProvider: signedInHolder(), search: search, now: frozenNow)
        let outcome = await retriever.fetch(question: "Who is Maple?")
        let (reply, _) = await RanchFMAnswerer.answer(
            question: "Who is Maple?",
            shaper: CaptureShaper(),
            fmUsableOverride: false,
            retrieval: outcome,
            now: now)

        XCTAssertEqual(reply, RanchOSJarvis.answer("Who is Maple?"))
        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(search.questions.count, 1)
    }

    func testTransportFailureCallsSearchOnce() async {
        let search = CountingSearch(error: RanchBrainRetrievalError.transport)
        let retriever = RanchBrainRetriever(
            sessionProvider: signedInHolder(), search: search, now: frozenNow)
        let outcome = await retriever.fetch(question: "How is the herd?")
        let shaper = CaptureShaper()
        let (reply, _) = await RanchFMAnswerer.answer(
            question: "How is the herd?",
            shaper: shaper,
            fmUsableOverride: false,
            retrieval: outcome)

        XCTAssertEqual(search.questions.count, 1)
        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertTrue(shaper.calls.isEmpty)
    }

    func testMissingSessionAndTenantUseFixturesAndSignInSentence() async {
        let search = CountingSearch()
        let noSession = RanchBrainRetriever(
            sessionProvider: FixedSession(session: nil), search: search, now: frozenNow)
        let missingTenant = RanchBrainRetriever(
            sessionProvider: FixedSession(session: RanchBrainSession(
                token: "rbs_present", expiresAt: now.addingTimeInterval(3600), tenantID: "  ")),
            search: search,
            now: frozenNow)

        let missing = await noSession.fetch(question: "Who is Maple?")
        let blank = await missingTenant.fetch(question: "Who is Maple?")
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?", shaper: CaptureShaper(), retrieval: missing)
        let (_, tenantDecision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?", shaper: CaptureShaper(), retrieval: blank)

        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(decision.label, RanchBrainFacts.signInSentence)
        XCTAssertEqual(tenantDecision.label, RanchBrainFacts.signInSentence)
        XCTAssertTrue(search.questions.isEmpty)
    }

    func testUnauthorizedPurgesSessionAndShowsExpired() async {
        let transport = ScriptedTransport(scripts: [
            ScriptedTransport.Script(status: 401, body: "{}", headers: [:]),
        ])
        let holder = signedInHolder()
        let client = makeClient(transport: transport, holder: holder, sleeper: RecordingSleeper())
        let retriever = RanchBrainRetriever(sessionProvider: holder, search: client, now: frozenNow)
        let outcome = await retriever.fetch(question: "Who is Maple?")
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?", shaper: CaptureShaper(), retrieval: outcome)

        XCTAssertNil(holder.currentSession())
        XCTAssertEqual(decision.label, "session expired — sign in again")
        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
    }

    func testRateLimitRetriesOnceThenUsesFixtureReason() async {
        let transport = ScriptedTransport(scripts: [
            ScriptedTransport.Script(status: 429, body: "{}", headers: ["Retry-After": "1"]),
            ScriptedTransport.Script(status: 429, body: "{}", headers: ["Retry-After": "1"]),
        ])
        let sleeper = RecordingSleeper()
        let holder = signedInHolder()
        let client = makeClient(transport: transport, holder: holder, sleeper: sleeper)
        let retriever = RanchBrainRetriever(sessionProvider: holder, search: client, now: frozenNow)
        let outcome = await retriever.fetch(question: "How is the herd?")
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "How is the herd?", shaper: CaptureShaper(), fmUsableOverride: false, retrieval: outcome)

        XCTAssertEqual(sleeper.slept, [1])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(decision.label, RanchBrainFacts.rateLimitFallbackReason)
        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
    }

    func testLiveFactsAreNotSentToPrivateCloud() async {
        let shaper = CaptureShaper(shaped: "SHAPED LIVE")
        let facts = [sampleFact(text: "Twelve head in the east.", source: "herd.md", daysAgo: 2)]
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "How is the herd?",
            shaper: shaper,
            retrieval: .facts(facts),
            now: now,
            routeOverride: .applePCC)

        XCTAssertTrue(shaper.calls.isEmpty)
        XCTAssertEqual(reply.text, "Twelve head in the east.")
        XCTAssertTrue(reply.provenance.hasPrefix("RanchBrain · herd.md · indexed"))
        XCTAssertEqual(decision.label, RanchBrainFacts.unavailable("Private Cloud Compute stays fixture-only"))
    }

    func testFixtureQuestionStillShapesOnPrivateCloudRoute() async {
        let shaper = CaptureShaper(shaped: "Maple is a Cattle.")
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?",
            shaper: shaper,
            fmUsableOverride: nil,
            retrieval: nil,
            routeOverride: .applePCC)

        XCTAssertEqual(shaper.calls, ["classify", "extract", "shape"])
        XCTAssertEqual(reply.text, "Maple is a Cattle.")
        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(decision.route, .applePCC)
    }

    func testUngroundedLiveReplyFallsBackToRetrievedFacts() async {
        let shaper = CaptureShaper(shaped: "Al invented this.")
        let facts = [sampleFact(text: "Twelve head in the east.", source: "herd.md", daysAgo: 1)]
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "How is the herd?",
            shaper: shaper,
            fmUsableOverride: true,
            retrieval: .facts(facts),
            now: now)

        XCTAssertEqual(reply.text, "Twelve head in the east.")
        XCTAssertTrue(reply.provenance.contains("RanchBrain · herd.md"))
        XCTAssertTrue(decision.label.contains("rejected"))
        XCTAssertNotEqual(reply, RanchOSJarvis.answer("How is the herd?"))
    }

    func testFailedLiveShapingKeepsRetrievedFacts() async {
        let shaper = CaptureShaper(intent: nil, terms: nil, shaped: nil)
        let facts = [sampleFact(text: "Twelve head in the east.", source: "herd.md", daysAgo: 1)]
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "How is the herd?",
            shaper: shaper,
            fmUsableOverride: true,
            retrieval: .facts(facts),
            now: now)

        XCTAssertEqual(reply.text, "Twelve head in the east.")
        XCTAssertEqual(decision.label, RanchBrainFacts.unavailable("shaping failed"))
        XCTAssertFalse(reply.provenance.contains("sample herd"))
    }

    func testIssueSessionStoresRanchBrainTokenNotGoogleToken() async throws {
        let body = #"{"token":"rbs_session","expires_at":"2026-10-04T00:00:00Z","tenant_id":"tenant-1"}"#
        let transport = ScriptedTransport(scripts: [
            ScriptedTransport.Script(status: 200, body: body, headers: [:]),
        ])
        let holder = RanchBrainSessionHolder(now: frozenNow)
        let client = makeClient(transport: transport, holder: holder, sleeper: RecordingSleeper())
        let session = try await client.issueSession(googleToken: "google-token", tenantID: "tenant-1")

        XCTAssertEqual(session.token, "rbs_session")
        XCTAssertEqual(session.tenantID, "tenant-1")
        XCTAssertEqual(holder.currentSession()?.token, "rbs_session")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer google-token")
        XCTAssertFalse(holder.currentSession()?.token.contains("google-token") ?? true)
    }

    @MainActor
    func testStorePassesRetrieverIntoUnderstanding() async {
        let search = CountingSearch()
        let retriever = RanchBrainRetriever(
            sessionProvider: FixedSession(session: nil), search: search, now: frozenNow)
        let store = RanchOSJarvisStore(speechEngine: nil, fmUsableOverride: false, retriever: retriever)
        store.question = "Who is Maple?"

        await store.askWithUnderstanding()

        XCTAssertEqual(store.answer?.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.signInSentence)
        XCTAssertTrue(search.questions.isEmpty)
    }

    private var frozenNow: @Sendable () -> Date {
        let clock = now
        return { clock }
    }

    private func signedInHolder() -> RanchBrainSessionHolder {
        let holder = RanchBrainSessionHolder(now: frozenNow)
        holder.store(RanchBrainSession(
            token: "rbs_testtoken",
            expiresAt: now.addingTimeInterval(3600),
            tenantID: "tenant-1"))
        return holder
    }

    private func makeClient(
        transport: ScriptedTransport,
        holder: RanchBrainSessionHolder,
        sleeper: RecordingSleeper
    ) -> RanchBrainClient {
        RanchBrainClient(
            baseURL: URL(string: "http://127.0.0.1:5063")!,
            tenantID: "tenant-1",
            token: { holder.currentSession()?.token },
            transport: transport,
            sleeper: sleeper,
            sessionHolder: holder)
    }

    private func sampleFact(text: String, source: String, daysAgo: Int) -> RanchBrainFact {
        RanchBrainFact(
            text: text,
            sourceBasename: source,
            indexedAt: now.addingTimeInterval(TimeInterval(-daysAgo * 86_400)))
    }

    private func assertNoCredentials(in seen: [String]) {
        let blob = seen.joined(separator: "\n")
        XCTAssertFalse(blob.contains("rbs_"))
        XCTAssertFalse(blob.contains("eyJ"))
        XCTAssertFalse(blob.contains("Bearer"))
        XCTAssertFalse(blob.contains("X-Ranch-Tenant"))
    }
}

private final class FixedSession: RanchBrainSessionProviding, @unchecked Sendable {
    var session: RanchBrainSession?
    init(session: RanchBrainSession?) { self.session = session }
    func currentSession() -> RanchBrainSession? { session }
}

private final class CountingSearch: RanchBrainKnowledgeSearching, @unchecked Sendable {
    var hits: [RanchBrainKnowledgeHit] = []
    var error: Error?
    private(set) var questions: [String] = []

    init(error: Error? = nil) { self.error = error }

    func searchKnowledge(question: String) async throws -> [RanchBrainKnowledgeHit] {
        questions.append(question)
        if let error { throw error }
        return hits
    }
}

private final class CaptureShaper: RanchFMUnderstanding, @unchecked Sendable {
    var intent: RanchJarvisIntentKind?
    var terms: RanchFindTerms?
    var shaped: String?
    private(set) var calls: [String] = []
    private(set) var facts: String?
    private(set) var seen: [String] = []

    init(
        intent: RanchJarvisIntentKind? = .answerSupported,
        terms: RanchFindTerms? = RanchFindTerms(terms: []),
        shaped: String? = "Shaped."
    ) {
        self.intent = intent
        self.terms = terms
        self.shaped = shaped
    }

    func classify(question: String) async -> RanchJarvisIntentKind? {
        calls.append("classify")
        seen.append(question)
        return intent
    }

    func extractTerms(question: String) async -> RanchFindTerms? {
        calls.append("extract")
        seen.append(question)
        return terms
    }

    func shape(question: String, facts: String, intent: RanchJarvisIntentKind, terms: RanchFindTerms) async -> String? {
        calls.append("shape")
        self.facts = facts
        seen.append(question)
        seen.append(facts)
        seen.append(intent.rawValue)
        seen.append(terms.terms.joined(separator: ","))
        return shaped
    }
}

private final class ScriptedTransport: RanchBrainHTTPTransport, @unchecked Sendable {
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

private final class RecordingSleeper: RanchBrainSleeper, @unchecked Sendable {
    private(set) var slept: [Int] = []
    func sleep(seconds: Int) async throws { slept.append(seconds) }
}
