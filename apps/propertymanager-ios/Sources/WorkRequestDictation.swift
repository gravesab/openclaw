import AVFoundation
import Foundation
import Observation
import Speech

/// On-device transcript for a work request. Recognition never falls back to a server.
@MainActor
@Observable
final class WorkRequestDictation {
    private(set) var transcript = ""
    private(set) var status = "Dictation stays on this device. You can edit the transcript before adding it."
    private(set) var isListening = false
    private var token: UUID?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func toggle() async {
        if isListening {
            stop(status: "Dictation stopped. Review the transcript before adding it.")
        } else {
            await start()
        }
    }

    func stop(status: String? = nil) {
        token = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        if let status { self.status = status }
    }

    private func start() async {
        let current = UUID()
        token = current
        status = "Checking speech and microphone permission…"
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard token == current else { return }
        guard speechAuthorized else {
            stop(status: "Speech permission is unavailable. You can still type the report.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            stop(status: "On-device English (US) recognition is unavailable. You can still type the report.")
            return
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard token == current else { return }
        guard microphone else {
            stop(status: "Microphone permission is unavailable. You can still type the report.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                stop(status: "No usable microphone input. You can still type the report.")
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            self.engine = engine
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self, self.token == current else { return }
                    if let text { self.transcript = text }
                    if finished, error != nil {
                        self.stop(status: "Dictation stopped. Review the transcript or type the report.")
                    } else if finished {
                        self.stop(status: "Dictation finished. Review the transcript before adding it.")
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isListening = true
            status = "Listening on this device."
        } catch {
            stop(status: "Dictation could not start. You can still type the report.")
        }
    }
}
