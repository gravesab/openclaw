import XCTest

final class RanchModelRouterTests: XCTestCase {
    func testRouterFallbackRouteCarriesHonestLabel() {
        let decision = ModelRouter.decide(fmUsableOverride: false)

        XCTAssertEqual(decision.route, .deterministicOnly)
        XCTAssertTrue(decision.label.contains("Keyword"), decision.label)
        XCTAssertNil(decision.intent)
        XCTAssertTrue(decision.terms.isEmpty)
    }

    func testRouterOnDeviceRouteWhenUsable() {
        let decision = ModelRouter.decide(fmUsableOverride: true)

        XCTAssertEqual(decision.route, .onDeviceUnderstanding)
        XCTAssertTrue(decision.label.contains("on-device"), decision.label)
    }

    func testRouterNeverClaimsRemoteProvider() {
        for usable in [true, false] {
            let label = ModelRouter.decide(fmUsableOverride: usable).label.lowercased()

            XCTAssertFalse(label.contains("remote"), label)
            XCTAssertFalse(label.contains("cloud"), label)
            XCTAssertFalse(label.contains("server"), label)
        }
    }

    func testFallbackAnswerMatchesDeterministicWithoutTouchingModel() async {
        let shaper = FakeFMUnderstanding()
        let expected = RanchOSJarvis.answer("Who is Maple?")

        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?", shaper: shaper, fmUsableOverride: false)

        XCTAssertEqual(reply, expected)
        XCTAssertEqual(decision.route, .deterministicOnly)
        XCTAssertTrue(shaper.calls.isEmpty)
    }

    func testShapedReplyKeepsFixtureProvenance() async {
        let shaper = FakeFMUnderstanding(
            intent: .findRecords,
            terms: RanchFindTerms(terms: ["Maple"]),
            shaped: "Maple is a Cattle.")

        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?", shaper: shaper, fmUsableOverride: true)

        XCTAssertEqual(reply.text, "Maple is a Cattle.")
        XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel)
        XCTAssertEqual(decision.route, .onDeviceUnderstanding)
        XCTAssertEqual(decision.intent, .findRecords)
        XCTAssertEqual(decision.terms, ["Maple"])
    }

    func testClassificationGoldensFlowToDecision() async {
        let goldens: [(RanchJarvisIntentKind, String)] = [
            (.answerSupported, "How is the herd?"),
            (.findRecords, "Who is Maple?"),
            (.weather, "Will it rain on the herd?"),
            (.unsupported, "What is the weather on Mars?"),
        ]

        for (intent, question) in goldens {
            let facts = RanchOSJarvis.answer(question).text
            let shaper = FakeFMUnderstanding(intent: intent, shaped: facts)

            let (reply, decision) = await RanchFMAnswerer.answer(
                question: question, shaper: shaper, fmUsableOverride: true)

            XCTAssertEqual(decision.intent, intent, question)
            XCTAssertEqual(reply.provenance, RanchOSJarvis.provenanceLabel, question)
        }
    }

    func testFailedUnderstandingFallsBackToDeterministic() async {
        let shaper = FakeFMUnderstanding(intent: nil, terms: nil, shaped: nil)
        let expected = RanchOSJarvis.answer("How is the herd?")

        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "How is the herd?", shaper: shaper, fmUsableOverride: true)

        XCTAssertEqual(reply, expected)
        XCTAssertEqual(decision.route, .deterministicOnly)
        XCTAssertTrue(decision.label.contains("failed"), decision.label)
    }

    func testUngroundedShapingFallsBackWithRejectedLabel() async {
        let shaper = FakeFMUnderstanding(shaped: "Zebra is a striped grazer of the savanna.")
        let expected = RanchOSJarvis.answer("Who is Maple?")

        let (reply, decision) = await RanchFMAnswerer.answer(
            question: "Who is Maple?", shaper: shaper, fmUsableOverride: true)

        XCTAssertEqual(reply, expected)
        XCTAssertEqual(decision.route, .deterministicOnly)
        XCTAssertTrue(decision.label.contains("rejected"), decision.label)
    }

    func testLongShapingIsCappedAtWordBoundary() {
        let long = String(repeating: "Maple Cattle ", count: 100)

        let capped = RanchFMAnswerer.cap(long)

        XCTAssertLessThanOrEqual(capped.count, RanchFMAnswerer.maxShapedLength)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertFalse(capped.dropLast().hasSuffix(" "))
    }

    func testShortTextPassesCapUnchanged() {
        XCTAssertEqual(RanchFMAnswerer.cap("Maple is a Cattle."), "Maple is a Cattle.")
    }

    func testGroundedCheckAcceptsFixtureWordsRejectsNewNames() {
        let facts = RanchOSJarvis.answer("Who is Maple?").text

        XCTAssertTrue(RanchFMAnswerer.isGrounded("Maple is a Cattle.", in: facts))
        XCTAssertFalse(RanchFMAnswerer.isGrounded("Ridge is a Cattle.", in: facts))
    }

    func testShortTokensWithDigitOrCapitalMustOccurInFacts() {
        let facts = "Maple is a Cattle in pasture Al with tag B12."

        XCTAssertFalse(RanchFMAnswerer.isGrounded("Al is missing.", in: "Maple is a Cattle."))
        XCTAssertFalse(RanchFMAnswerer.isGrounded("Give B12 now.", in: "Maple is a Cattle."))
        XCTAssertTrue(RanchFMAnswerer.isGrounded("Al has tag B12.", in: facts))
        XCTAssertTrue(RanchFMAnswerer.isGrounded("the herd", in: "the herd"))
    }

    @MainActor
    func testStoreUnderstandingFallbackSetsAnswerAndLabel() async {
        let store = RanchOSJarvisStore(speechEngine: nil, fmUsableOverride: false)
        store.question = "Who is Maple?"

        await store.askWithUnderstanding()

        XCTAssertEqual(store.answer?.text.contains("Maple"), true)
        XCTAssertEqual(store.understandingLabel?.contains("Keyword"), true)
    }

    @MainActor
    func testStoreUnderstandingShapesWithFake() async {
        let shaper = FakeFMUnderstanding(
            intent: .findRecords,
            terms: RanchFindTerms(terms: ["Maple"]),
            shaped: "Maple is a Cattle.")
        let store = RanchOSJarvisStore(shaper: shaper, fmUsableOverride: true)
        store.question = "Who is Maple?"

        await store.askWithUnderstanding()

        XCTAssertEqual(store.answer?.text, "Maple is a Cattle.")
        XCTAssertEqual(store.understandingLabel?.contains("on-device"), true)
    }
}

/// Canned understanding: records which steps ran so fallback tests can prove
/// the model path was never touched.
private final class FakeFMUnderstanding: RanchFMUnderstanding, @unchecked Sendable {
    var intent: RanchJarvisIntentKind?
    var terms: RanchFindTerms?
    var shaped: String?
    private(set) var calls: [String] = []

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
        return intent
    }

    func extractTerms(question: String) async -> RanchFindTerms? {
        calls.append("extract")
        return terms
    }

    func shape(question: String, facts: String, intent: RanchJarvisIntentKind, terms: RanchFindTerms) async -> String? {
        calls.append("shape")
        return shaped
    }
}
