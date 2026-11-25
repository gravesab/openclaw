import SwiftUI
#if os(macOS)
import AppKit
#endif
#if !os(tvOS)
import AVFoundation
import Speech
#endif

/// What a text field holds. Every kind checks spelling. The kind only picks
/// the iPhone keyboard.
enum RanchEntryKind: Sendable {
    case words
    case address
    case number
}

/// Joins dictated words onto text already in the field.
enum RanchOSEntryText {
    static func completed(prefix: String, utterance: String) -> String {
        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return prefix }
        guard !prefix.isEmpty else { return spoken }
        if let last = prefix.last, last.isWhitespace || last.isNewline {
            return prefix + spoken
        }
        return prefix + " " + spoken
    }
}

extension View {
    /// Spell checking, and a microphone that dictates on this device.
    /// Apple TV compiles the call and shows the field unchanged.
    func ranchEntry(_ text: Binding<String>, kind: RanchEntryKind = .words) -> some View {
        modifier(RanchEntryModifier(text: text, kind: kind))
    }
}

private struct RanchEntryModifier: ViewModifier {
    @Binding var text: String
    var kind: RanchEntryKind
#if !os(tvOS)
    @State private var controller = RanchDictationController()
#endif

    func body(content: Content) -> some View {
#if os(tvOS)
        content
#else
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                content
                    .layoutPriority(1)
#if os(iOS)
                    .autocorrectionDisabled(false)
                    .textInputAutocapitalization(.sentences)
                    .keyboardType(keyboard)
#endif
#if os(macOS)
                    .background(RanchSpellingProbe())
#endif
                Button {
                    Task { await controller.toggle() }
                } label: {
                    if controller.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: controller.isListening ? "mic.fill" : "mic")
                            .foregroundStyle(controller.isListening ? Color.red : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.accessibilityLabel)
                .help("Dictate into this field. Speech stays on this device.")
            }
            if controller.showsMessage {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { controller.bind($text) }
        .onDisappear { controller.stop() }
#endif
    }

#if os(iOS)
    /// The normal keyboard, so spelling suggestions stay available on an
    /// address or an amount as well as on a name.
    private var keyboard: UIKeyboardType {
        switch kind {
        case .words: .default
        case .address: .default
        case .number: .default
        }
    }
#endif
}

#if os(macOS)
/// Turns spell checking on for whatever field is being edited in this window.
/// SwiftUI's text field does not check spelling on its own, and it resets the
/// field editor, so this applies again on each change.
private struct RanchSpellingProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> RanchSpellingView {
        RanchSpellingView()
    }

    func updateNSView(_ view: RanchSpellingView, context: Context) {}
}

private final class RanchSpellingView: NSView {
    private var applying = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        for name: Notification.Name in [
            NSText.didBeginEditingNotification,
            NSText.didChangeNotification,
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidChangeNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: name, object: nil)
        }
    }

    /// The first version only turned checking on when the field editor sat
    /// inside this probe. SwiftUI does not nest them that way, so New category
    /// never showed a misspelling. Any field in this window is checked.
    @objc private func editingChanged(_ note: Notification) {
        guard let editor = Self.editor(from: note), editor.window === window else { return }
        apply(editor)
        DispatchQueue.main.async { [weak editor] in
            guard let editor, editor.window != nil else { return }
            self.apply(editor)
        }
    }

    private static func editor(from note: Notification) -> NSTextView? {
        if let editor = note.object as? NSTextView { return editor }
        return note.userInfo?["NSFieldEditor"] as? NSTextView
    }

    private func apply(_ editor: NSTextView) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        editor.isContinuousSpellCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.grammar.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue
        if let field = editor.delegate as? NSTextField {
            field.isAutomaticTextCompletionEnabled = true
        }
        editor.checkTextInDocument(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
#endif

#if !os(tvOS)
@MainActor
private enum RanchDictationHub {
    weak static var active: RanchDictationController?
}

@MainActor
@Observable
private final class RanchDictationController {
    private(set) var isListening = false
    private(set) var isPreparing = false
    private(set) var status = ""

    private var text: Binding<String>?
    private var prefix = ""
    private var utterance = ""
    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
#if compiler(>=6.2)
    private var intelligenceEngine: AnyObject?
    private var intelligenceListener: Task<Void, Never>?
#endif

    var showsMessage: Bool { !status.isEmpty }

    var accessibilityLabel: String {
        if isListening || isPreparing { return "Stop dictation" }
        if #available(macOS 26, iOS 26, *) { return "Dictate with Apple Intelligence" }
        return "Dictate on this device"
    }

    func bind(_ text: Binding<String>) {
        self.text = text
    }

    func toggle() async {
        if isListening || isPreparing {
            stop()
        } else {
            await start()
        }
    }

    func stop() {
        generation = UUID()
        finish(status: "")
    }

    private func start() async {
        let generation = UUID()
        self.generation = generation
        isPreparing = true
        status = "Checking the microphone…"
        prefix = text?.wrappedValue ?? ""
        utterance = ""
        if let active = RanchDictationHub.active, active !== self { active.stop() }
        RanchDictationHub.active = self

        guard await Self.speechAllowed() else {
            finish(status: "Speech permission is off. You can still type.")
            return
        }
        guard generation == self.generation else { return }
        guard await Self.microphoneAllowed() else {
            finish(status: "Microphone permission is off. You can still type.")
            return
        }
        guard generation == self.generation else { return }

#if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *), await startIntelligence(generation) { return }
        guard generation == self.generation else { return }
#endif
        startLegacy(generation)
    }

    private func publish() {
        text?.wrappedValue = RanchOSEntryText.completed(prefix: prefix, utterance: utterance)
    }

    private func finish(status: String) {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine?.stop()
        engine = nil
#if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            let engine = intelligenceEngine as? RanchIntelligenceEngine
            intelligenceListener?.cancel()
            intelligenceEngine = nil
            intelligenceListener = nil
            if let engine { Task { await engine.stop() } }
        }
#endif
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        isListening = false
        isPreparing = false
        self.status = status
        if RanchDictationHub.active === self { RanchDictationHub.active = nil }
    }

    private func startLegacy(_ generation: UUID) {
        guard let recognizer = Self.onDeviceRecognizer() else {
            finish(status: "On-device dictation isn't available. You can still type.")
            return
        }
        let audio = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            finish(status: "No microphone is available. You can still type.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        engine = audio
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let finished = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if let transcript {
                    self.utterance = transcript
                    self.publish()
                }
                if finished {
                    self.finish(status: error != nil && (transcript ?? "").isEmpty
                        ? "Dictation stopped. You can still type."
                        : "")
                }
            }
        }
        audio.prepare()
        do {
#if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
#endif
            try audio.start()
            isPreparing = false
            isListening = true
            status = "Listening on this device."
        } catch {
            finish(status: "Dictation could not start. You can still type.")
        }
    }

    private static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.current, Locale(identifier: "en_US")] {
            guard let recognizer = SFSpeechRecognizer(locale: locale),
                recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
            else { continue }
            return recognizer
        }
        return nil
    }

    private static func speechAllowed() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        guard current == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func microphoneAllowed() async -> Bool {
        let current = AVAudioApplication.shared.recordPermission
        if current == .granted { return true }
        guard current == .undetermined else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

#if compiler(>=6.2)
    @available(macOS 26, iOS 26, *)
    private func startIntelligence(_ generation: UUID) async -> Bool {
        guard let locale = await RanchIntelligenceEngine.locale() else { return false }
        let engine = RanchIntelligenceEngine()
        intelligenceEngine = engine
        do {
            status = "Preparing Apple Intelligence dictation…"
            let pieces = try await engine.start(locale: locale)
            guard self.generation == generation else {
                await engine.stop()
                return false
            }
            intelligenceListener = Task { @MainActor [weak self] in
                for await piece in pieces {
                    guard let self, self.generation == generation else { return }
                    self.utterance = piece
                    self.publish()
                }
            }
            isPreparing = false
            isListening = true
            status = "Listening with Apple Intelligence."
            return true
        } catch {
            await engine.stop()
            if self.generation == generation { intelligenceEngine = nil }
            return false
        }
    }
#endif
}

#if compiler(>=6.2)
@available(macOS 26, iOS 26, *)
private final actor RanchIntelligenceEngine {
    private let audio = AVAudioEngine()
    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapInstalled = false

    static func locale() async -> Locale? {
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: .current) { return match }
        let supported = await DictationTranscriber.supportedLocales
        return supported.first { $0.identifier.hasPrefix("en") } ?? supported.first
    }

    func start(locale: Locale) async throws -> AsyncStream<String> {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        self.transcriber = transcriber
        let assets = await AssetInventory.status(forModules: [transcriber])
        switch assets {
        case .installed:
            break
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw RanchDictationError.unavailable
        @unknown default:
            throw RanchDictationError.unavailable
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RanchDictationError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        let input = audio.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RanchDictationError.unavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let copy = RanchAudioCopy.copy(buffer) else { return }
            let box = RanchAudioBox(copy)
            Task { await self?.consume(box, target: format) }
        }
        tapInstalled = true
        let (pieces, pieceContinuation) = AsyncStream<String>.makeStream()
        Task {
            do {
                for try await result in transcriber.results {
                    pieceContinuation.yield(String(result.text.characters))
                }
            } catch {
                pieceContinuation.finish()
            }
            pieceContinuation.finish()
        }
        audio.prepare()
        try audio.start()
        try await analyzer.start(inputSequence: inputs)
        return pieces
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audio.stop()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        transcriber = nil
    }

    private func consume(_ box: RanchAudioBox, target: AVAudioFormat) {
        guard let converted = RanchAudioCopy.convert(box.buffer, to: target) else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: converted))
    }
}

private final class RanchAudioBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private enum RanchDictationError: Error {
    case unavailable
}

private enum RanchAudioCopy {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames) else {
            return nil
        }
        copy.frameLength = frames
        let count = Int(frames)
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: count)
            }
            return copy
        }
        return nil
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0, let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var didProvide = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return converted
    }
}
#endif
#endif
