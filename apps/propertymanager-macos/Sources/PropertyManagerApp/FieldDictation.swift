import AVFoundation
import Speech
import SwiftUI

/// One dictation session shared by every text box, so only one microphone tap runs at a time.
/// Recognition is on-device only and never falls back to a server.
/// ObservableObject rather than @Observable because the Mac app still supports macOS 13.
@MainActor
final class FieldDictation: ObservableObject {
    static let shared = FieldDictation()

    @Published private(set) var activeFieldID: UUID?
    @Published private(set) var failure: (fieldID: UUID, message: String)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func toggle(fieldID: UUID, onText: @escaping (String) -> Void) async {
        if activeFieldID == fieldID {
            stop()
            return
        }
        stop()
        await start(fieldID: fieldID, onText: onText)
    }

    func clearFailure() {
        failure = nil
    }

    func stop() {
        activeFieldID = nil
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func fail(_ fieldID: UUID, _ message: String) {
        stop()
        failure = (fieldID, message)
    }

    private func start(fieldID: UUID, onText: @escaping (String) -> Void) async {
        activeFieldID = fieldID
        failure = nil
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard activeFieldID == fieldID else { return }
        guard speechAuthorized else {
            fail(fieldID, "Speech Recognition permission is off. Turn it on in Settings, or type instead.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            fail(fieldID, "On-device speech recognition isn't available for this language. You can still type.")
            return
        }
        guard await Self.microphoneAllowed() else {
            fail(fieldID, "Microphone permission is off. Turn it on in Settings, or type instead.")
            return
        }
        guard activeFieldID == fieldID else { return }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            #endif
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail(fieldID, "No usable microphone input. You can still type.")
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
                    guard let self, self.activeFieldID == fieldID else { return }
                    if let text { onText(text) }
                    if finished { self.stop() }
                }
            }
            engine.prepare()
            try engine.start()
        } catch {
            fail(fieldID, "Dictation couldn't start. You can still type.")
        }
    }

    private static func microphoneAllowed() async -> Bool {
        #if os(iOS)
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

/// Mic button that dictates into a text box, adding to what is already typed.
struct DictationButton: View {
    @Binding var text: String
    @State private var fieldID = UUID()
    @ObservedObject private var dictation = FieldDictation.shared

    var body: some View {
        let isListening = dictation.activeFieldID == fieldID
        Button {
            let base = text
            let binding = $text
            Task {
                await dictation.toggle(fieldID: fieldID) { spoken in
                    binding.wrappedValue = Self.joined(base, spoken)
                }
            }
        } label: {
            Image(systemName: isListening ? "stop.circle.fill" : "mic.circle")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isListening ? Color.red : Color.accentColor)
        .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")
        .help(isListening ? "Stop dictation" : "Dictate with your voice (stays on this device)")
        .alert(
            "Dictation",
            isPresented: Binding(
                get: { dictation.failure?.fieldID == fieldID },
                set: { if !$0 { dictation.clearFailure() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.failure?.message ?? "")
        }
        .onDisappear {
            if dictation.activeFieldID == fieldID { dictation.stop() }
        }
    }

    static func joined(_ base: String, _ spoken: String) -> String {
        let typed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return spoken }
        guard !spoken.isEmpty else { return base }
        return "\(typed) \(spoken)"
    }
}

extension View {
    /// Free-text box: on-device dictation button beside it. Spell check and Writing Tools stay on.
    func voiceInput(_ text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            self
            DictationButton(text: text)
        }
    }

    /// The full Apple Intelligence Writing Tools experience where the device supports it.
    @ViewBuilder
    func fullWritingTools() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            writingToolsBehavior(.complete)
        } else {
            self
        }
    }

    /// URLs, keys, and part numbers: rewriting them would corrupt the value.
    @ViewBuilder
    func noWritingTools() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}
