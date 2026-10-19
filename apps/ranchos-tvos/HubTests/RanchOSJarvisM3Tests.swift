import XCTest

final class RanchOSJarvisM3Tests: XCTestCase {
    private let fixtureNames = [
        "Maple", "Oak", "Ridge", "Plains", "Willow", "Thistle", "Copper", "Harrow", "Saddle", "Porch",
    ]

    @MainActor
    func testSignedInHerdUsesLiveProjection() async {
        let reader = FakeLivestockReader(herd: currentHerd())
        let search = ScriptedSearch()
        let store = makeStore(reader: reader, search: search)
        store.question = "How is the herd?"

        await store.askWithUnderstanding()

        let expected = RanchOSJarvisLivestockFormatter.herdAnswer(currentHerd())
        XCTAssertEqual(store.answer, expected)
        XCTAssertEqual(store.answer?.provenance, "Livestock · live · North Ranch · Current")
        XCTAssertEqual(reader.herdReads, 1)
        XCTAssertTrue(reader.animalReads.isEmpty)
        XCTAssertTrue(search.questions.isEmpty)
        XCTAssertFalse(store.answer?.provenance.contains(RanchOSJarvis.provenanceLabel) ?? true)
    }

    @MainActor
    func testSignedInAnimalUsesLiveDetail() async {
        let animal = currentAnimal(name: "Maple")
        let reader = FakeLivestockReader(animals: ["maple": animal])
        let store = makeStore(reader: reader, search: ScriptedSearch())
        store.question = "Who is Maple?"

        await store.askWithUnderstanding()

        XCTAssertEqual(store.answer, RanchOSJarvisLivestockFormatter.animalAnswer(animal))
        XCTAssertEqual(store.answer?.provenance, "Livestock · live · Maple · Current")
        XCTAssertEqual(
            store.answer?.text,
            "Maple is a rhode island red (meat, angus). Status: active. ear tag: 12")
        XCTAssertEqual(reader.animalReads, ["Maple"])
    }

    @MainActor
    func testAbsentFixtureNamesDoNotFillIn() async {
        let reader = FakeLivestockReader()
        let search = ScriptedSearch()
        for name in fixtureNames {
            let store = makeStore(reader: reader, search: search)
            store.question = "Who is \(name)?"
            await store.askWithUnderstanding()
            XCTAssertEqual(store.answer?.text, RanchOSJarvisLivestockFormatter.animalUnavailableText)
            XCTAssertEqual(store.answer?.provenance, RanchOSJarvisLivestockFormatter.unavailableCaption)
            XCTAssertFalse(store.answer?.text.contains(name) ?? true)
        }
        XCTAssertTrue(search.questions.isEmpty)
    }

    @MainActor
    func testSignedOutFixtureKeepsSignInLabel() async {
        let search = ScriptedSearch()
        let store = RanchOSJarvisStore(
            speechEngine: nil,
            fmUsableOverride: false,
            retriever: RanchBrainRetriever(
                sessionProvider: RanchBrainSessionHolder(), search: search, now: { Date() }),
            livestockReader: FakeLivestockReader(herd: currentHerd()))
        store.question = "How is the herd?"

        await store.askWithUnderstanding()

        XCTAssertEqual(store.answer, RanchOSJarvis.answer("How is the herd?"))
        XCTAssertEqual(store.answer?.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(store.understandingLabel, RanchBrainFacts.signInSentence)
        XCTAssertEqual(search.questions, [])
    }

    @MainActor
    func testFreshnessSuffixes() async {
        var staleHerd = currentHerd()
        staleHerd.cards[1] = card(
            id: "fact-freshness", title: "Fact freshness", detail: "One animal is stale", status: .careDue)
        let staleAnimal = currentAnimal(name: "Maple", freshness: .stale)
        let incompleteAnimal = currentAnimal(name: "Maple", freshness: .incomplete)
        let conflictingAnimal = currentAnimal(name: "Maple", freshness: .conflicting)

        let staleHerdStore = makeStore(reader: FakeLivestockReader(herd: staleHerd), search: ScriptedSearch())
        staleHerdStore.question = "How is the herd?"
        await staleHerdStore.askWithUnderstanding()
        XCTAssertTrue(staleHerdStore.answer?.text.hasSuffix(" Care due.") ?? false)
        XCTAssertEqual(staleHerdStore.answer?.provenance, "Livestock · live · North Ranch · Care due")

        let staleAnimalStore = makeStore(
            reader: FakeLivestockReader(animals: ["maple": staleAnimal]), search: ScriptedSearch())
        staleAnimalStore.question = "Maple"
        await staleAnimalStore.askWithUnderstanding()
        XCTAssertTrue(staleAnimalStore.answer?.text.hasSuffix(" Care due.") ?? false)
        XCTAssertEqual(staleAnimalStore.answer?.provenance, "Livestock · live · Maple · Care due")

        for freshness in [RanchOSLivestockFactFreshness.incomplete, .conflicting] {
            var herd = currentHerd()
            herd.cards[1] = card(
                id: "fact-freshness", title: "Fact freshness", detail: "Facts need review", status: .review)
            let herdStore = makeStore(reader: FakeLivestockReader(herd: herd), search: ScriptedSearch())
            herdStore.question = "How is the herd?"
            await herdStore.askWithUnderstanding()
            XCTAssertTrue(herdStore.answer?.text.hasSuffix(" Needs review.") ?? false, "\(freshness)")
            XCTAssertEqual(herdStore.answer?.provenance, "Livestock · live · North Ranch · Review")

            let animal = currentAnimal(name: "Maple", freshness: freshness)
            let animalStore = makeStore(
                reader: FakeLivestockReader(animals: ["maple": animal]), search: ScriptedSearch())
            animalStore.question = "Maple"
            await animalStore.askWithUnderstanding()
            XCTAssertTrue(animalStore.answer?.text.hasSuffix(" Needs review.") ?? false, "\(freshness)")
            XCTAssertEqual(animalStore.answer?.provenance, "Livestock · live · Maple · Review")
        }
        XCTAssertEqual(incompleteAnimal.factFreshness, .incomplete)
        XCTAssertEqual(conflictingAnimal.factFreshness, .conflicting)
    }

    @MainActor
    func testReaderErrorsStayOnTheNotAvailableSentence() async {
        let foreign = "tenant-b-secret"
        for error in [
            RanchOSJarvisLivestockReadError.unauthorized, .crossTenant, .missing, .foreignID, .transport,
        ] {
            let reader = FakeLivestockReader(animalError: error)
            let search = ScriptedSearch()
            let store = makeStore(reader: reader, search: search)
            store.question = "Maple"
            await store.askWithUnderstanding()
            XCTAssertEqual(store.answer?.text, RanchOSJarvisLivestockFormatter.animalUnavailableText)
            XCTAssertEqual(store.answer?.provenance, RanchOSJarvisLivestockFormatter.unavailableCaption)
            XCTAssertFalse(store.answer?.text.contains(foreign) ?? true)
            XCTAssertTrue(search.questions.isEmpty)
        }
    }

    @MainActor
    func testRanchBrainFailuresDoNotShowTheFixture() async {
        let rateLimited = await ranchBrainFailure(.retryExhausted(RanchBrainFacts.rateLimitedSentence))
        XCTAssertEqual(rateLimited.text, RanchBrainFacts.rateLimitedSentence)
        XCTAssertEqual(rateLimited.provenance, RanchBrainFacts.rateLimitedCaption)

        let unavailable = await ranchBrainFailure(.retryExhausted(RanchBrainFacts.unavailableSentence))
        XCTAssertEqual(unavailable.text, RanchBrainFacts.unavailableSentence)
        XCTAssertEqual(unavailable.provenance, RanchBrainFacts.unavailableCaption)

        let transport = await ranchBrainFailure(.transportFailure)
        XCTAssertEqual(transport.text, RanchBrainFacts.unavailableSentence)
        XCTAssertEqual(transport.provenance, RanchBrainFacts.unavailableCaption)

        let noRecord = await ranchBrainFailure(.zeroHits)
        XCTAssertEqual(noRecord.text, RanchBrainFacts.noRecordSentence)
        XCTAssertEqual(noRecord.provenance, RanchBrainFacts.noRecordCaption)

        for reply in [rateLimited, unavailable, transport, noRecord] {
            XCTAssertFalse(reply.text.contains("sample herd"))
            XCTAssertFalse(reply.provenance.contains(RanchOSJarvis.provenanceLabel))
        }
    }

    @MainActor
    func testUnauthorizedPurgesHolderAndSpeaksExpiredSentence() async {
        let holder = signedInHolder()
        let client = RanchBrainClient(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            tenantID: "tenant-1",
            token: { holder.currentSession()?.token },
            transport: StatusTransport(status: 401),
            sleeper: ImmediateSleeper(),
            sessionHolder: holder)
        let store = RanchOSJarvisStore(
            speechEngine: nil,
            fmUsableOverride: false,
            retriever: RanchBrainRetriever(sessionProvider: holder, search: client, now: { Date() }))
        store.question = "what can you do?"

        await store.askWithUnderstanding()

        XCTAssertNil(holder.currentSession())
        XCTAssertEqual(store.answer?.text, RanchBrainFacts.sessionExpiredSentence)
        XCTAssertEqual(store.answer?.provenance, RanchBrainFacts.sessionExpiredCaption)
        XCTAssertNil(store.understandingLabel)
        XCTAssertFalse(store.answer?.provenance.contains(RanchOSJarvis.provenanceLabel) ?? true)
    }

    @MainActor
    func testDeterministicAndOnDeviceLivestockCaptionsMatch() async {
        let deterministicText = RanchOSJarvisLivestockFormatter.herdAnswer(currentHerd()).text
        let shaper = EchoShaper(shaped: deterministicText)
        let deterministic = makeStore(
            reader: FakeLivestockReader(herd: currentHerd()), search: ScriptedSearch(), fmUsableOverride: false)
        let onDevice = makeStore(
            reader: FakeLivestockReader(herd: currentHerd()),
            search: ScriptedSearch(),
            shaper: shaper,
            fmUsableOverride: true)
        deterministic.question = "How is the herd?"
        onDevice.question = "How is the herd?"

        await deterministic.askWithUnderstanding()
        await onDevice.askWithUnderstanding()

        XCTAssertEqual(deterministic.answer?.provenance, onDevice.answer?.provenance)
        XCTAssertEqual(onDevice.answer?.text, deterministicText)
        XCTAssertNotEqual(deterministic.understandingLabel, onDevice.understandingLabel)
        XCTAssertEqual(onDevice.understandingLabel, "Reply shaped on-device from livestock facts.")
        XCTAssertTrue(onDevice.answer?.provenance.contains("Current") ?? false)
        for token in ["North", "Ranch", "4"] {
            XCTAssertTrue(onDevice.answer?.text.contains(token) ?? false, token)
        }
    }

    @MainActor
    func testPrivateCloudDoesNotReceiveLiveLivestockFacts() async {
        let shaper = EchoShaper(shaped: "SHAPED LIVE")
        let deterministic = RanchOSJarvisLivestockFormatter.herdAnswer(currentHerd())
        let (reply, decision) = await RanchFMAnswerer.answerLivestock(
            question: "How is the herd?",
            deterministic: deterministic,
            shaper: shaper,
            routeOverride: .applePCC)

        XCTAssertEqual(shaper.shapeCount, 0)
        XCTAssertEqual(reply, deterministic)
        XCTAssertEqual(decision.label, RanchBrainFacts.unavailable("Private Cloud Compute stays fixture-only"))
    }

    @MainActor
    func testSignedInWeatherAndEmptyAskNothing() async {
        for question in ["weather tomorrow", ""] {
            let reader = FakeLivestockReader(herd: currentHerd(), animals: ["maple": currentAnimal(name: "Maple")])
            let search = ScriptedSearch()
            let store = makeStore(reader: reader, search: search)
            store.question = question
            await store.askWithUnderstanding()
            XCTAssertEqual(store.answer?.text, RanchBrainFacts.unsupportedSentence)
            XCTAssertEqual(store.answer?.provenance, RanchBrainFacts.unsupportedCaption)
            XCTAssertEqual(reader.herdReads, 0)
            XCTAssertTrue(reader.animalReads.isEmpty)
            XCTAssertTrue(search.questions.isEmpty)
        }
    }

    func testReadAloudMatchesDisplayedText() {
        let live = RanchOSJarvisLivestockFormatter.herdAnswer(currentHerd())
        var staleHerd = currentHerd()
        staleHerd.cards[1] = card(
            id: "fact-freshness", title: "Fact freshness", detail: "One animal is stale", status: .careDue)
        let stale = RanchOSJarvisLivestockFormatter.herdAnswer(staleHerd)
        let review = RanchOSJarvisLivestockFormatter.animalAnswer(currentAnimal(name: "Maple", freshness: .incomplete))
        let failure = RanchOSJarvisLivestockFormatter.herdUnavailable()
        let fixture = RanchOSJarvis.answer("How is the herd?")
        for answer in [live, stale, review, failure, fixture] {
            XCTAssertEqual(RanchOSJarvisSpoken.string(for: answer), answer.text)
        }
    }

    @MainActor
    func testRanchBrainFactThirtyDaysOldCarriesVerify() async {
        let indexed = RanchBrainFacts.utcDate(year: 2026, month: 9, day: 1)
        let now = RanchBrainFacts.utcDate(year: 2026, month: 10, day: 1)
        let search = ScriptedSearch(hits: [
            RanchBrainKnowledgeHit(text: "Fence note.", source: "fence.md", indexedAt: indexed),
        ])
        let holder = signedInHolder()
        let store = RanchOSJarvisStore(
            speechEngine: nil,
            fmUsableOverride: false,
            retriever: RanchBrainRetriever(sessionProvider: holder, search: search, now: { now }))
        store.question = "pasture notes"

        await store.askWithUnderstanding()

        XCTAssertTrue(store.answer?.provenance.contains(" · verify") ?? false)
        XCTAssertTrue(store.answer?.provenance.hasPrefix("RanchBrain · fence.md · indexed") ?? false)
    }

    @MainActor
    func testNilReaderAndThrownErrorDoNotCallRanchBrain() async {
        let nilSearch = ScriptedSearch()
        let nilStore = makeStore(reader: nil, search: nilSearch)
        nilStore.question = "how is the herd?"
        await nilStore.askWithUnderstanding()
        XCTAssertEqual(nilStore.answer?.text, RanchOSJarvisLivestockFormatter.herdUnavailableText)
        XCTAssertTrue(nilSearch.questions.isEmpty)

        let search = ScriptedSearch()
        let reader = FakeLivestockReader(herdError: .unauthorized)
        let store = makeStore(reader: reader, search: search)
        store.question = "how is the herd?"
        await store.askWithUnderstanding()
        XCTAssertEqual(store.answer?.text, RanchOSJarvisLivestockFormatter.herdUnavailableText)
        XCTAssertEqual(reader.herdReads, 1)
        XCTAssertTrue(search.questions.isEmpty)
    }

    @MainActor
    func testSignedOutUnsupportedAndEmptyStayOnTheFixture() async {
        let holder = RanchBrainSessionHolder()
        for question in ["weather tomorrow", ""] {
            let store = RanchOSJarvisStore(
                speechEngine: nil,
                fmUsableOverride: false,
                retriever: RanchBrainRetriever(
                    sessionProvider: holder, search: ScriptedSearch(), now: { Date() }))
            store.question = question
            await store.askWithUnderstanding()
            XCTAssertEqual(store.answer, RanchOSJarvis.answer(question))
            XCTAssertEqual(store.answer?.provenance, RanchOSJarvis.provenanceLabel)
        }
    }

    @MainActor
    func testWhoIsMapleResolvesOrRefusesWithoutRanchBrain() async {
        let present = FakeLivestockReader(animals: ["maple": currentAnimal(name: "Maple")])
        let presentSearch = ScriptedSearch()
        let presentStore = makeStore(reader: present, search: presentSearch)
        presentStore.question = "Who is Maple?"
        await presentStore.askWithUnderstanding()
        XCTAssertEqual(present.animalReads, ["Maple"])
        XCTAssertEqual(presentStore.answer?.provenance, "Livestock · live · Maple · Current")
        XCTAssertTrue(presentSearch.questions.isEmpty)

        let absent = FakeLivestockReader()
        let absentSearch = ScriptedSearch()
        let absentStore = makeStore(reader: absent, search: absentSearch)
        absentStore.question = "Who is Maple?"
        await absentStore.askWithUnderstanding()
        XCTAssertEqual(absentStore.answer?.text, RanchOSJarvisLivestockFormatter.animalUnavailableText)
        XCTAssertTrue(absentSearch.questions.isEmpty)
    }

    @MainActor
    func testSingleTokenAndMultiWordRouting() async {
        let reader = FakeLivestockReader(animals: ["maple": currentAnimal(name: "Maple")])
        let mapleSearch = ScriptedSearch()
        let maple = makeStore(reader: reader, search: mapleSearch)
        maple.question = "Maple"
        await maple.askWithUnderstanding()
        XCTAssertEqual(reader.animalReads, ["Maple"])
        XCTAssertTrue(mapleSearch.questions.isEmpty)

        let aboutSearch = ScriptedSearch(hits: [
            RanchBrainKnowledgeHit(text: "Maple notes.", source: "maple.md", indexedAt: Date()),
        ])
        let aboutReader = FakeLivestockReader(animals: ["maple": currentAnimal(name: "Maple")])
        let about = makeStore(reader: aboutReader, search: aboutSearch)
        about.question = "tell me about Maple"
        await about.askWithUnderstanding()
        XCTAssertEqual(aboutSearch.questions, ["tell me about Maple"])
        XCTAssertTrue(aboutReader.animalReads.isEmpty)
        XCTAssertEqual(aboutReader.herdReads, 0)

        let helpSearch = ScriptedSearch(hits: [
            RanchBrainKnowledgeHit(text: "Help note.", source: "help.md", indexedAt: Date()),
        ])
        let helpReader = FakeLivestockReader()
        let help = makeStore(reader: helpReader, search: helpSearch)
        help.question = "what can you do?"
        await help.askWithUnderstanding()
        XCTAssertEqual(helpSearch.questions, ["what can you do?"])
        XCTAssertEqual(helpReader.herdReads, 0)
        XCTAssertTrue(helpReader.animalReads.isEmpty)
    }

    @MainActor
    func testHerdKeywordsBeatAnAnimalName() async {
        let reader = FakeLivestockReader(
            herd: currentHerd(), animals: ["maple": currentAnimal(name: "Maple")])
        let search = ScriptedSearch()
        let store = makeStore(reader: reader, search: search)
        store.question = "how many cattle does Maple have?"

        await store.askWithUnderstanding()

        XCTAssertEqual(reader.herdReads, 1)
        XCTAssertTrue(reader.animalReads.isEmpty)
        XCTAssertTrue(search.questions.isEmpty)
        XCTAssertEqual(store.answer?.provenance, "Livestock · live · North Ranch · Current")
    }

    @MainActor
    func testWeatherMakesZeroReads() async {
        let reader = FakeLivestockReader(herd: currentHerd())
        let search = ScriptedSearch()
        let store = makeStore(reader: reader, search: search)
        store.question = "weather tomorrow"

        await store.askWithUnderstanding()

        XCTAssertEqual(reader.herdReads, 0)
        XCTAssertTrue(reader.animalReads.isEmpty)
        XCTAssertTrue(search.questions.isEmpty)
        XCTAssertEqual(store.answer?.text, RanchBrainFacts.unsupportedSentence)
    }

    // MARK: - Fixtures

    private func currentHerd() -> RanchOSJarvisHerdFacts {
        RanchOSJarvisHerdFacts(
            ranchName: "North Ranch",
            herdCount: 4,
            cards: [
                card(id: "herd-count", title: "Herd", detail: "4 animals in this ranch", status: .current),
                card(
                    id: "fact-freshness", title: "Fact freshness", detail: "Animal facts are current",
                    status: .current),
                card(
                    id: "records-review", title: "Records review",
                    detail: "Every animal has an active identifier", status: .current),
            ])
    }

    private func currentAnimal(
        name: String,
        freshness: RanchOSLivestockFactFreshness = .current
    ) -> RanchOSJarvisAnimalFacts {
        RanchOSJarvisAnimalFacts(
            displayName: name,
            speciesCode: "rhode_island_red",
            productionTypeCode: "meat",
            breedCode: "angus",
            lifecycleStatus: "active",
            identifierKind: "ear_tag",
            identifierValue: "12",
            factFreshness: freshness)
    }

    private func card(
        id: String, title: String, detail: String, status: RanchOSLivestockSummary.Status
    ) -> RanchOSLivestockSummary {
        RanchOSLivestockSummary(id: id, title: title, detail: detail, status: status)
    }

    private func signedInHolder() -> RanchBrainSessionHolder {
        let holder = RanchBrainSessionHolder()
        holder.store(RanchBrainSession(
            token: "rbs_test", expiresAt: .distantFuture, tenantID: "tenant-1"))
        return holder
    }

    @MainActor
    private func makeStore(
        reader: (any RanchOSJarvisLivestockReading)?,
        search: any RanchBrainKnowledgeSearching,
        shaper: (any RanchFMUnderstanding)? = nil,
        fmUsableOverride: Bool? = false
    ) -> RanchOSJarvisStore {
        RanchOSJarvisStore(
            speechEngine: nil,
            shaper: shaper,
            fmUsableOverride: fmUsableOverride,
            retriever: RanchBrainRetriever(
                sessionProvider: signedInHolder(), search: search, now: { Date() }),
            livestockReader: reader)
    }
}

private func ranchBrainFailure(_ reason: RanchBrainFixtureReason) async -> RanchOSJarvisAnswer {
    let (reply, _) = await RanchFMAnswerer.answer(
        question: "pasture notes",
        shaper: EchoShaper(shaped: nil),
        fmUsableOverride: false,
        retrieval: .fixtures(reason))
    return reply
}

private final class FakeLivestockReader: RanchOSJarvisLivestockReading, @unchecked Sendable {
    var herd: RanchOSJarvisHerdFacts
    var animals: [String: RanchOSJarvisAnimalFacts]
    var herdError: RanchOSJarvisLivestockReadError?
    var animalError: RanchOSJarvisLivestockReadError?
    private(set) var herdReads = 0
    private(set) var animalReads: [String] = []

    init(
        herd: RanchOSJarvisHerdFacts = RanchOSJarvisHerdFacts(ranchName: "North Ranch", herdCount: 0, cards: []),
        animals: [String: RanchOSJarvisAnimalFacts] = [:],
        herdError: RanchOSJarvisLivestockReadError? = nil,
        animalError: RanchOSJarvisLivestockReadError? = nil
    ) {
        self.herd = herd
        self.animals = animals
        self.herdError = herdError
        self.animalError = animalError
    }

    func readHerd() async throws -> RanchOSJarvisHerdFacts {
        herdReads += 1
        if let herdError { throw herdError }
        return herd
    }

    func readAnimal(displayName: String) async throws -> RanchOSJarvisAnimalFacts {
        animalReads.append(displayName)
        if let animalError { throw animalError }
        guard let animal = animals[displayName.lowercased()] else {
            throw RanchOSJarvisLivestockReadError.missing
        }
        return animal
    }
}

private final class ScriptedSearch: RanchBrainKnowledgeSearching, @unchecked Sendable {
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

private final class EchoShaper: RanchFMUnderstanding, @unchecked Sendable {
    var shaped: String?
    private(set) var shapeCount = 0

    init(shaped: String?) { self.shaped = shaped }

    func classify(question: String) async -> RanchJarvisIntentKind? { .answerSupported }

    func extractTerms(question: String) async -> RanchFindTerms? { RanchFindTerms(terms: []) }

    func shape(
        question: String, facts: String, intent: RanchJarvisIntentKind, terms: RanchFindTerms
    ) async -> String? {
        shapeCount += 1
        return shaped
    }
}

private final class StatusTransport: RanchBrainHTTPTransport, @unchecked Sendable {
    let status: Int
    init(status: Int) { self.status = status }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])
        else {
            throw URLError(.badServerResponse)
        }
        return (Data("{}".utf8), http)
    }
}

private struct ImmediateSleeper: RanchBrainSleeper {
    func sleep(seconds: Int) async throws {}
}
