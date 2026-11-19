import Testing
@testable import OpenClawChatUI

struct AppleIntelligenceDictationTests {
    @Test func `empty utterance keeps existing text`() {
        #expect(AppleIntelligenceDictationText.completed(prefix: "Barn door", utterance: "  ") == "Barn door")
    }

    @Test func `utterance fills an empty field`() {
        #expect(AppleIntelligenceDictationText.completed(prefix: "", utterance: " Fix the gate ") == "Fix the gate")
    }

    @Test func `utterance continues existing text`() {
        #expect(
            AppleIntelligenceDictationText.completed(prefix: "Fix the", utterance: "north gate")
                == "Fix the north gate")
    }

    @Test func `utterance keeps A trailing break`() {
        #expect(
            AppleIntelligenceDictationText.completed(prefix: "Notes:\n", utterance: "Replace the belt")
                == "Notes:\nReplace the belt")
    }

    @Test func `segments commit stable text and replace the tail`() {
        var session = AppleIntelligenceDictationText.Session()
        session.applySegment(text: "Fix", isFinal: false)
        #expect(session.utterance == "Fix")
        session.applySegment(text: "Fix the", isFinal: false)
        session.applySegment(text: "Fix the", isFinal: true)
        session.applySegment(text: "gate", isFinal: false)
        #expect(session.utterance == "Fix the gate")
        session.applySegment(text: "gate", isFinal: true)
        #expect(session.utterance == "Fix the gate")
    }

    @Test func `microphone leaves the iPhone alone and uses local usb audio`() {
        let chosen = DictationMicrophonePicker.preferred(among: [
            DictationMicrophoneCandidate(name: "HD Pro Webcam C920", isDefault: true),
            DictationMicrophoneCandidate(name: "KT USB Audio", isDefault: false),
            DictationMicrophoneCandidate(name: "Andy’s iPhone Microphone", isDefault: false),
            DictationMicrophoneCandidate(name: "Microsoft Teams Audio", isDefault: false),
        ])
        #expect(chosen?.name == "KT USB Audio")
    }

    @Test func `microphone uses usb audio before the webcam`() {
        let chosen = DictationMicrophonePicker.preferred(among: [
            DictationMicrophoneCandidate(name: "HD Pro Webcam C920", isDefault: true),
            DictationMicrophoneCandidate(name: "KT USB Audio", isDefault: false),
        ])
        #expect(chosen?.name == "KT USB Audio")
    }

    @Test func `microphone can use the webcam when it is the only input`() {
        let chosen = DictationMicrophonePicker.preferred(among: [
            DictationMicrophoneCandidate(name: "HD Pro Webcam C920", isDefault: true),
            DictationMicrophoneCandidate(name: "Microsoft Teams Audio", isDefault: false),
        ])
        #expect(chosen?.name == "HD Pro Webcam C920")
    }

    @Test func `full transcript replaces the utterance`() {
        var session = AppleIntelligenceDictationText.Session()
        session.applyFullTranscript("the mower")
        session.applyFullTranscript("the mower has 12 hours")
        #expect(session.utterance == "the mower has 12 hours")
    }
}
