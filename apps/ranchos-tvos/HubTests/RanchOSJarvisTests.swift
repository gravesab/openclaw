import XCTest

final class RanchOSJarvisTests: XCTestCase {
    func testHerdQuestionAnswersFromFixtureWithProvenance() {
        let fixture = RanchOSLivestockDashboard.developmentFixture
        let answer = RanchOSJarvis.answer("How is the herd?")

        XCTAssertTrue(answer.text.contains("\(fixture.herdCount) animals"), answer.text)
        XCTAssertTrue(answer.text.contains("Care reminders"), answer.text)
        XCTAssertEqual(answer.provenance, RanchOSJarvis.provenanceLabel)
    }

    func testAnimalLookupGroundsDetailInCatalog() {
        let answer = RanchOSJarvis.answer("Who is Maple?")

        XCTAssertTrue(answer.text.contains("Maple"), answer.text)
        XCTAssertTrue(answer.text.contains("Cattle"), answer.text)
        XCTAssertTrue(answer.text.contains("SA-104"), answer.text)
        XCTAssertEqual(answer.provenance, RanchOSJarvis.provenanceLabel)
    }

    func testAnimalLookupIsCaseInsensitive() {
        let answer = RanchOSJarvis.answer("tell me about oak")

        XCTAssertTrue(answer.text.contains("Oak"), answer.text)
        XCTAssertTrue(answer.text.contains("SA-221"), answer.text)
    }

    func testCapabilitiesAnswerStatesFixtureBoundary() {
        let answer = RanchOSJarvis.answer("What can you do?")

        XCTAssertTrue(answer.text.contains("sample herd"), answer.text)
        XCTAssertTrue(answer.text.contains("don't have live ranch records"), answer.text)
    }

    func testUnsupportedQuestionFailsClosedWithoutInventing() {
        let answer = RanchOSJarvis.answer("What is the weather on Mars?")

        XCTAssertTrue(answer.text.contains("don't have that"), answer.text)
        XCTAssertFalse(answer.text.contains("12"))
        XCTAssertEqual(answer.provenance, RanchOSJarvis.provenanceLabel)
    }

    func testEmptyQuestionPromptsInsteadOfAnswering() {
        let answer = RanchOSJarvis.answer("   ")

        XCTAssertTrue(answer.text.contains("Ask me about the sample herd"), answer.text)
    }

    func testSampleQuestionsAllAnswerFromFixture() {
        XCTAssertFalse(RanchOSJarvis.sampleQuestions.isEmpty)

        for question in RanchOSJarvis.sampleQuestions {
            let answer = RanchOSJarvis.answer(question)

            XCTAssertEqual(answer.provenance, RanchOSJarvis.provenanceLabel, question)
            XCTAssertFalse(answer.text.isEmpty, question)
            XCTAssertFalse(answer.text.contains("don't have that"), question)
        }
    }

    func testIntroductionStatesFixtureBoundary() {
        XCTAssertFalse(RanchOSJarvis.introduction.isEmpty)
        XCTAssertTrue(RanchOSJarvis.introduction.contains("sample herd"))
        XCTAssertTrue(RanchOSJarvis.introduction.contains("don't have live ranch records"))
    }

    @MainActor
    func testSpeakIntroductionStartsPlayback() {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)

        store.speakIntroduction()

        XCTAssertTrue(store.isSpeaking)
    }

    @MainActor
    func testTalkStartsListeningOnce() {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)

        XCTAssertTrue(store.canTalk)
        store.startTalking()
        store.startTalking()

        XCTAssertEqual(engine.startedCount, 1)
        XCTAssertEqual(store.speechState, .listening(partial: ""))
        XCTAssertFalse(store.canTalk)
    }

    @MainActor
    func testPartialTranscriptDisplaysWithoutSubmitting() async {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)
        store.startTalking()

        engine.emit(.partialTranscript("how is the"))
        await drainSpeechEvents()

        XCTAssertEqual(store.speechState, .listening(partial: "how is the"))
        XCTAssertTrue(store.question.isEmpty)
        XCTAssertNil(store.answer)
    }

    @MainActor
    func testFinalTranscriptHandsOffToAnswer() async {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine, fmUsableOverride: false)
        store.startTalking()

        engine.emit(.finalTranscript("How is the herd?"))
        await waitForAnswer(store)

        XCTAssertEqual(store.speechState, .idle)
        XCTAssertEqual(store.question, "How is the herd?")
        let answer = try? XCTUnwrap(store.answer)
        XCTAssertTrue(answer?.text.contains("12 animals") == true)
        XCTAssertTrue(store.canTalk)
    }

    @MainActor
    func testCancelAbandonsUtteranceWithoutAnswer() {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)
        store.startTalking()

        store.cancelTalking()

        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertEqual(store.speechState, .idle)
        XCTAssertTrue(store.question.isEmpty)
        XCTAssertNil(store.answer)
        XCTAssertTrue(store.canTalk)
    }

    @MainActor
    func testStopForwardsToEngine() {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)
        store.startTalking()

        store.stopTalking()

        XCTAssertEqual(engine.stopCount, 1)
    }

    @MainActor
    func testDeniedStateAllowsTypedRetry() async {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)
        store.startTalking()

        engine.emit(.denied)
        await drainSpeechEvents()

        XCTAssertEqual(store.speechState, .denied)
        XCTAssertNil(store.answer)
        XCTAssertTrue(store.canTalk)

        store.startTalking()
        XCTAssertEqual(engine.startedCount, 2)
    }

    @MainActor
    func testUnavailableMessageIsPreserved() async {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)
        store.startTalking()

        engine.emit(.unavailable("On-device dictation isn't available."))
        await drainSpeechEvents()

        XCTAssertEqual(store.speechState, .unavailable("On-device dictation isn't available."))
        XCTAssertNil(store.answer)
    }

    @MainActor
    func testTalkStopsPlaybackBeforeListening() {
        let engine = FakeJarvisSpeechEngine()
        let store = RanchOSJarvisStore(speechEngine: engine)
        store.question = "How is the herd?"
        store.ask()
        store.toggleSpeech()
        XCTAssertTrue(store.isSpeaking)

        store.startTalking()

        XCTAssertFalse(store.isSpeaking)
        XCTAssertEqual(engine.startedCount, 1)
    }

    @MainActor
    private func drainSpeechEvents() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// The voice path answers asynchronously; poll bounded so the test stays
    /// deterministic regardless of Task scheduling.
    @MainActor
    private func waitForAnswer(_ store: RanchOSJarvisStore) async {
        for _ in 0..<500 where store.answer == nil { await Task.yield() }
    }
}

private final class FakeJarvisSpeechEngine: RanchOSJarvisSpeechEngine {
    var startedCount = 0
    var stopCount = 0
    var cancelCount = 0
    var handler: (@Sendable (RanchOSJarvisSpeechEvent) -> Void)?

    func startListening(eventHandler: @escaping @Sendable (RanchOSJarvisSpeechEvent) -> Void) {
        startedCount += 1
        handler = eventHandler
    }

    func stopListening() {
        stopCount += 1
    }

    func cancelListening() {
        cancelCount += 1
    }

    func emit(_ event: RanchOSJarvisSpeechEvent) {
        handler?(event)
    }
}
