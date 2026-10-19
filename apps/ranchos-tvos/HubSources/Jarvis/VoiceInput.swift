#if !os(tvOS)
import Foundation
import Observation
@preconcurrency import Speech
@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Keeps callbacks from a canceled recording out of the next draft.
struct VoiceDraft {
    private(set) var token: UUID?
    private(set) var text = ""
    mutating func begin() -> UUID {
        let id = UUID()
        token = id
        text = ""
        return id
    }
    mutating func receive(_ text: String, token: UUID) {
        guard self.token == token else { return }
        self.text = String(text.prefix(500))
    }
    mutating func finish() { token = nil }
    mutating func cancel() { token = nil; text = "" }
}

@MainActor @Observable final class VoiceInput {
    enum Phase { case idle, permission, listening }
    private(set) var phase: Phase = .idle
    private(set) var status = "On-device speech only. Review your transcript before sending."
    private(set) var draft = VoiceDraft()
    var isActive: Bool { phase != .idle }
    private var tapInstalled = false
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timeout: Task<Void, Never>?

    func start() async {
        guard !isActive else { return }
        let token = draft.begin()
        phase = .permission
        status = "Checking speech and microphone permission…"
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
        guard draft.token == token else { return }
        guard speech else { fail("Speech permission is unavailable. You can still type."); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail("On-device English (US) recognition is unavailable. You can still type.")
            return
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard draft.token == token else { return }
        guard microphone else { fail("Microphone permission is unavailable. You can still type."); return }
        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
            #endif
            #if os(macOS)
            guard Self.isLogitechDefaultInput() else {
                fail("Select HD Pro Webcam C920 as the Mac sound input, then retry.")
                return
            }
            #endif
            let engine = AVAudioEngine()
            self.engine = engine
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("No usable microphone input. You can still type.")
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.draft.token == token else { return }
                    if let text { self.draft.receive(text, token: token) }
                    if failed { self.fail("Recognition stopped. Retry or type your question.") }
                    else if final { self.stop() }
                }
            }
            engine.prepare()
            try engine.start()
            phase = .listening
            status = "Listening on this device · stops after 30 seconds"
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.stop()
            }
        } catch {
            fail("Audio input could not start. You can still type.")
        }
    }
    #if os(macOS)
    private static func isLogitechDefaultInput() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioObjectPropertyName
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard result == noErr else { return false }
        return name as String == "HD Pro Webcam C920"
    }
    #endif
    func stop() {
        guard isActive else { return }
        draft.finish()
        releaseAudio()
        status = draft.text.isEmpty ? "No speech captured. Retry or type." : "Review the transcript, then use it as your question."
    }
    func cancel() {
        draft.cancel()
        releaseAudio()
        status = "Recording canceled. You can type or start again."
    }
    private func fail(_ message: String) {
        draft.cancel()
        releaseAudio()
        status = message
    }
    private func releaseAudio() {
        timeout?.cancel()
        timeout = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine = nil
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        phase = .idle
    }
}


/// Speech output seam for DEV Jarvis replies. The live engine talks through
/// AVSpeechSynthesizer with the closest system voice (DEV placeholder);
/// a licensed Jarvis voice swaps in behind RanchVASpeechEngine later.
protocol RanchVASpeechEngine: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?)
    func stop()
}

final class RanchVAAVSpeechEngine: NSObject, RanchVASpeechEngine {
    private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking: Bool { synthesizer.isSpeaking }
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }
    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

@MainActor @Observable final class RanchVASpeaker {
    private(set) var isSpeaking = false
    private var engine: any RanchVASpeechEngine
    init(engine: (any RanchVASpeechEngine)? = nil) {
        self.engine = engine ?? RanchVAAVSpeechEngine()
    }
    /// Closest system voice to the Jarvis delivery: British English male
    /// when present, else any British English voice, else the system default.
    nonisolated static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { $0.language.hasPrefix("en-GB") && $0.name.localizedCaseInsensitiveContains("Daniel") }
            ?? voices.first { $0.language.hasPrefix("en-GB") }
    }
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        isSpeaking = true
        engine.speak(String(trimmed.prefix(800)), voice: Self.preferredVoice())
    }
    func stop() {
        engine.stop()
        isSpeaking = false
    }
}

#endif
