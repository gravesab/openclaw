import AVFoundation
import XCTest

final class RanchVADEVQueryTests: XCTestCase {
    private func tasks() throws -> [RanchOSPropertyLiveTask] {
        try RanchOSPropertyLiveDashboard.decode(from: Data(#"[{"id":"dev-2","item":"Inspect pump","area":"Barn","is_active":false},{"id":"dev-1","item":"Inspect fence","area":"North","is_active":true}]"#.utf8)).tasks
    }
    func testActiveQueryUsesOnlyReturnedActiveRecords() throws {
        let filter = try XCTUnwrap(RanchVADEVFilter.parse("Show active tasks?"))
        XCTAssertEqual(filter.apply(to: try tasks()).map(\.id), ["dev-1"])
    }
    func testFindMatchesTitleAreaAndIDWithoutInventingRecords() throws {
        let items = try tasks()
        for query in ["Find pump", "Find BARN", "Find dev-2"] {
            XCTAssertEqual(try XCTUnwrap(RanchVADEVFilter.parse(query)).apply(to: items).map(\.id), ["dev-2"])
        }
        XCTAssertTrue(try XCTUnwrap(RanchVADEVFilter.parse("Find unknown")).apply(to: items).isEmpty)
    }
    func testSpendingAndMutationRequestsAreUnsupported() {
        for query in ["What have we spent on it?", "Delete dev-1", "Complete all tasks", "", "Find ", String(repeating: "x", count: 501)] {
            XCTAssertNil(RanchVADEVFilter.parse(query))
        }
    }
    func testAllResultsAreDeterministicAndEmptyFeedStaysEmpty() throws {
        XCTAssertEqual(RanchVADEVFilter.all.apply(to: try tasks()).map(\.id), ["dev-1", "dev-2"])
        XCTAssertTrue(RanchVADEVFilter.all.apply(to: []).isEmpty)
    }
}

// MARK: - RanchVASpeaker (voice replies)
private final class FakeSpeechEngine: RanchVASpeechEngine {
    var spoken: [String] = []
    var stoppedCount = 0
    var speaking = false
    var isSpeaking: Bool { speaking }
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?) {
        spoken.append(text)
        speaking = true
    }
    func stop() {
        stoppedCount += 1
        speaking = false
    }
}

@MainActor final class RanchVASpeakerTests: XCTestCase {
    func testSpeakSkipsBlankText() {
        let engine = FakeSpeechEngine()
        let speaker = RanchVASpeaker(engine: engine)
        speaker.speak("   ")
        XCTAssertTrue(engine.spoken.isEmpty)
        XCTAssertFalse(speaker.isSpeaking)
    }
    func testSpeakStopsPreviousAndMarksSpeaking() {
        let engine = FakeSpeechEngine()
        let speaker = RanchVASpeaker(engine: engine)
        speaker.speak("Found 3 matching records.")
        XCTAssertEqual(engine.spoken, ["Found 3 matching records."])
        XCTAssertEqual(engine.stoppedCount, 1)
        XCTAssertTrue(speaker.isSpeaking)
        speaker.stop()
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertEqual(engine.stoppedCount, 2)
    }
    func testPreferredVoicePrefersEnglishWhenVoicesExist() {
        if let voice = RanchVASpeaker.preferredVoice() {
            XCTAssertTrue(voice.language.hasPrefix("en"))
        }
    }
}
