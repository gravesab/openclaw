import AVFoundation
import Foundation
import Observation
#if !os(tvOS)
@preconcurrency import Speech
#endif
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answer produced by the DEV Jarvis fixture answerer. Every answer carries
/// explicit provenance; fixtures are never presented as live ranch facts.
struct RanchOSJarvisAnswer: Equatable, Sendable {
    let text: String
    let provenance: String
}

/// Deterministic fixture-backed answerer for the M1 Jarvis slice.
/// Read-only: it only reads DEV fixture structs, never ranch records.
enum RanchOSJarvis {
    nonisolated static let provenanceLabel = "DEV fixture · sample herd · read only"

    /// Fixed sample questions for the Jarvis workspace. Each must answer
    /// from the fixture (covered by RanchOSJarvisTests).
    nonisolated static let sampleQuestions = [
        "How is the herd?",
        "Who is Maple?",
        "What can you do?",
    ]

    /// Fixed spoken introduction for the Jarvis persona. Fixture-honest like
    /// every other answer: it states the sample-herd boundary out loud.
    nonisolated static let introduction =
        "Hello, I'm Jarvis. I can tell you about the sample herd and look up sample animals like Maple or Oak. "
        + "I don't have live ranch records in this DEV slice."

    nonisolated static func answer(_ question: String) -> RanchOSJarvisAnswer {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return RanchOSJarvisAnswer(
                text: "Ask me about the sample herd, or name a sample animal like Maple.",
                provenance: provenanceLabel)
        }
        let lowered = query.lowercased()
        if lowered.contains("what can you do") || lowered.contains("help") || lowered.contains("capabilit") {
            return RanchOSJarvisAnswer(text: capabilitiesText, provenance: provenanceLabel)
        }
        if let animal = RanchOSLivestockSampleCatalog.developmentSamples.first(where: {
            lowered.contains($0.displayName.lowercased())
        }) {
            return RanchOSJarvisAnswer(text: animalText(for: animal), provenance: provenanceLabel)
        }
        if lowered.contains("herd") || lowered.contains("livestock") || lowered.contains("cattle")
            || lowered.contains("animals") || lowered.contains("how many")
        {
            return RanchOSJarvisAnswer(text: herdText(), provenance: provenanceLabel)
        }
        return RanchOSJarvisAnswer(
            text: "I don't have that in this DEV slice. I can only answer from the labeled sample herd.",
            provenance: provenanceLabel)
    }

    nonisolated private static var capabilitiesText: String {
        "I can tell you about the sample herd and look up sample animals like Maple or Oak. "
            + "I don't have live ranch records in this DEV slice."
    }

    nonisolated private static func herdText() -> String {
        let dashboard = RanchOSLivestockDashboard.developmentFixture
        let summaries = dashboard.summaries.map { "\($0.title): \($0.detail)." }.joined(separator: " ")
        return "The sample herd has \(dashboard.herdCount) animals. \(summaries)"
    }

    nonisolated private static func animalText(for animal: RanchOSLivestockSampleAnimal) -> String {
        let breed = animal.breed?.label ?? "no listed breed"
        let identifier = animal.identifier?.summary ?? "No identifier recorded."
        return "\(animal.displayName) is a \(animal.species.label) (\(animal.productionType.label), \(breed)). "
            + "Status: \(animal.lifecycleStatus.label). \(identifier)"
    }
}

/// Typed sign-in failures. Carries no tokens and no user data.
enum RanchOSJarvisSignInError: Error, Equatable, Sendable {
    case cancelled
    case denied
    case alreadySigningIn
    case misconfigured
    case noPresentationAnchor
    case badCallback
    case tokenExchangeFailed
    /// HTTP 403 from POST /v1/session: the Google subject is not linked yet.
    case forbiddenNotLinked
    /// HTTP 401 from POST /v1/session: claims missing or stale.
    case unauthorized
    case transport
}

/// Fills the memory-only session holder via Google sign-in, then the existing
/// issueSession. The live implementation is AuthenticationServices-based and
/// lives in RanchOSJarvisSessionProvider.swift (not compiled on tvOS); tests
/// inject a fake. Compiles on every target so the store stays cross-platform.
protocol RanchOSJarvisSessionSigning: Sendable {
    @MainActor func signIn() async throws -> RanchBrainSession
    @MainActor func cancelSignIn()
    @MainActor func signOut() async
}

/// M1 Jarvis conversation state: typed question, labeled fixture answer,
/// explicit read-aloud via system text-to-speech. No recording, no listening.
@MainActor
@Observable
final class RanchOSJarvisStore {
    enum SpeechState: Equatable {
        case idle
        case listening(partial: String)
        case denied
        case unavailable(String)
        case failed(String)
    }

    var question = ""
    private(set) var answer: RanchOSJarvisAnswer?
    private(set) var isSpeaking = false
    private(set) var speechState: SpeechState = .idle
    private(set) var understandingLabel: String?
    private(set) var isSigningIn = false

    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = RanchOSJarvisSpeechDelegate()
    private let speechEngine: (any RanchOSJarvisSpeechEngine)?
    private let shaper: any RanchFMUnderstanding
    private let fmUsableOverride: Bool?
    private let retriever: RanchBrainRetriever?
    private let sessionSigner: (any RanchOSJarvisSessionSigning)?

    init(
        speechEngine: (any RanchOSJarvisSpeechEngine)? = nil,
        shaper: (any RanchFMUnderstanding)? = nil,
        fmUsableOverride: Bool? = nil,
        retriever: RanchBrainRetriever? = nil,
        sessionSigner: (any RanchOSJarvisSessionSigning)? = nil
    ) {
        self.speechEngine = speechEngine ?? Self.defaultSpeechEngine()
        self.shaper = shaper ?? RanchLiveFMUnderstanding()
        self.fmUsableOverride = fmUsableOverride
        self.retriever = retriever
        self.sessionSigner = sessionSigner
        synthesizer.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in
            Task { @MainActor [weak self] in self?.isSpeaking = false }
        }
    }

    private static func defaultSpeechEngine() -> (any RanchOSJarvisSpeechEngine)? {
#if os(tvOS)
        return nil
#else
        return RanchOSJarvisLiveSpeechEngine()
#endif
    }

    var canTalk: Bool {
        guard speechEngine != nil else { return false }
        switch speechState {
        case .idle, .denied, .unavailable, .failed: return true
        case .listening: return false
        }
    }

    func ask() {
        stopSpeaking()
        answer = RanchOSJarvis.answer(question)
        understandingLabel = nil
    }

    /// Async understanding path. When a retriever is injected, RanchBrain
    /// retrieval runs first and the answer plus understanding label are set
    /// from that result. With no retriever, the fixture path is unchanged.
    func askWithUnderstanding() async {
        stopSpeaking()
        let retrieval = await retriever?.fetch(question: question)
        let (reply, decision) = await RanchFMAnswerer.answer(
            question: question,
            shaper: shaper,
            fmUsableOverride: fmUsableOverride,
            retrieval: retrieval)
        answer = reply
        understandingLabel = decision.label
    }

    /// Holder truth: a session exists, is unexpired, and has not been purged.
    /// A 401 on any data call purges the holder, which flips this off with no
    /// extra bookkeeping.
    var isSignedIn: Bool {
        retriever?.sessionProvider.currentSession() != nil
    }

    /// Runs the injected signer. Any failed issue (401 claims, 403 unlinked,
    /// transport) leaves the holder empty and shows the sign-in sentence, so
    /// the app never looks signed in without a session. Backing out of the
    /// browser leaves the label alone.
    func signIn() async {
        guard !isSigningIn, let sessionSigner else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            _ = try await sessionSigner.signIn()
        } catch let error as RanchOSJarvisSignInError where error == .cancelled || error == .denied {
            return
        } catch {
            understandingLabel = RanchBrainFacts.signInSentence
        }
    }

    func cancelSignIn() {
        sessionSigner?.cancelSignIn()
    }

    func signOut() async {
        await sessionSigner?.signOut()
    }

    /// Caption above the conversation: the fixture label until an answer
    /// exists, then that answer's provenance. A live hit is visibly
    /// RanchBrain provenance, never the fixture string.
    var captionText: String {
        answer?.provenance ?? RanchOSJarvis.provenanceLabel
    }

    /// Workspace status line. Session state comes from the holder; listening
    /// and speaking keep their existing precedence.
    func workspaceStatusText() -> String {
        if case .listening = speechState { return "Listening…" }
        if isSpeaking { return "Speaking…" }
        if isSignedIn { return "Ready · RanchBrain" }
        return "Ready · Fixture"
    }

#if !os(tvOS)
    /// DEV store: one holder shared by the retriever and the live signer, so
    /// sign-in fills exactly the session the next question reads. The client
    /// carries the named DEV tenant id; tvOS keeps devService() instead.
    static func makeDevStore() -> RanchOSJarvisStore {
        let holder = RanchBrainSessionHolder()
        let client = RanchBrainClient(
            baseURL: RanchOSJarvisDevSession.serviceBaseURL,
            tenantID: RanchOSJarvisDevSession.tenantID,
            token: { holder.currentSession()?.token },
            sessionHolder: holder)
        let retriever = RanchBrainRetriever(sessionProvider: holder, search: client, now: { Date() })
        let signer = RanchOSJarvisLiveSessionProvider(client: client)
        return RanchOSJarvisStore(retriever: retriever, sessionSigner: signer)
    }
#endif

    /// Explicit push-to-talk start. Stops any playback first so recording and
    /// speech never compete. Only a final transcript submits — partials display only.
    func startTalking() {
        guard let speechEngine, canTalk else { return }
        stopSpeaking()
        speechState = .listening(partial: "")
        speechEngine.startListening { [weak self] event in
            Task { @MainActor [weak self] in self?.handleSpeechEvent(event) }
        }
    }

    /// Ends the utterance and transcribes what was captured.
    func stopTalking() {
        speechEngine?.stopListening()
    }

    /// Abandons the utterance: no transcript, no answer. No-op unless
    /// listening, so error and guidance states are left undisturbed.
    func cancelTalking() {
        guard case .listening = speechState else { return }
        speechEngine?.cancelListening()
        speechState = .idle
    }

    /// Speaks the fixed Jarvis introduction. Explicit only — never auto-plays.
    /// Cancels any in-progress listening first so capture and speech never overlap.
    func speakIntroduction() {
        cancelTalking()
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: RanchOSJarvis.introduction)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func handleSpeechEvent(_ event: RanchOSJarvisSpeechEvent) {
        switch event {
        case .partialTranscript(let text):
            if case .listening = speechState {
                speechState = .listening(partial: text)
            }
        case .finalTranscript(let text):
            speechState = .idle
            question = text
            Task { [weak self] in await self?.askWithUnderstanding() }
        case .denied:
            speechState = .denied
        case .unavailable(let message):
            speechState = .unavailable(message)
        case .failed(let message):
            speechState = .failed(message)
        case .stopped:
            speechState = .idle
        }
    }

    func toggleSpeech() {
        if isSpeaking {
            stopSpeaking()
        } else {
            speakAnswer()
        }
    }

    private func speakAnswer() {
        guard let answer else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: answer.text)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}

private final class RanchOSJarvisSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    // Set once on the main actor before any speech starts.
    nonisolated(unsafe) var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}

/// One bounded utterance produces any number of partials, then exactly one
/// terminal event. Cancel produces no event; the store resets to idle itself.
enum RanchOSJarvisSpeechEvent: Equatable, Sendable {
    case partialTranscript(String)
    case finalTranscript(String)
    case denied
    case unavailable(String)
    case failed(String)
    case stopped
}

protocol RanchOSJarvisSpeechEngine: AnyObject {
    func startListening(eventHandler: @escaping @Sendable (RanchOSJarvisSpeechEvent) -> Void)
    func stopListening()
    func cancelListening()
}

#if !os(tvOS)
/// Push-to-talk capture via AVAudioEngine + SFSpeechRecognizer. All mutable
/// state lives on a private serial queue; nothing is recorded outside one
/// explicit utterance, nothing is saved, and partials never submit.
// All mutable state is confined to the private serial queue.
private final class RanchOSJarvisLiveSpeechEngine: NSObject, @unchecked Sendable, RanchOSJarvisSpeechEngine {
    private let queue = DispatchQueue(label: "dev.ranchos.jarvis.speech")
    private var generation = 0
    private var eventHandler: (@Sendable (RanchOSJarvisSpeechEvent) -> Void)?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    deinit {
        queue.sync { self.tearDownAudio() }
    }

    func startListening(eventHandler: @escaping @Sendable (RanchOSJarvisSpeechEvent) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.eventHandler = eventHandler
            self.beginUtterance(generation: self.generation)
        }
    }

    func stopListening() {
        queue.async { [weak self] in
            guard let self, self.eventHandler != nil else { return }
            // End audio and stop capture; the final transcript or an error
            // still arrives through the result handler.
            self.request?.endAudio()
            self.audioEngine?.stop()
            self.audioEngine?.inputNode.removeTap(onBus: 0)
        }
    }

    func cancelListening() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.eventHandler = nil
            self.tearDownAudio()
        }
    }

    private func beginUtterance(generation: Int) {
        guard let locale = Self.preferredLocale() else {
            return finish(.unavailable("Speech recognition doesn't support this device's language."), generation: generation)
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return finish(
                .unavailable("Speech recognition isn't available right now. Typed questions work the same."),
                generation: generation)
        }
        // On-device is API-verifiable on iOS and macOS (the property is
        // API_AVAILABLE(ios(13)), which leaves macOS available); refuse
        // remote recognition on both.
        guard recognizer.supportsOnDeviceRecognition else {
            return finish(.unavailable(Self.onDeviceUnavailableMessage), generation: generation)
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            self.queue.async {
                guard status == .authorized else {
                    return self.finish(.denied, generation: generation)
                }
                self.requestMicrophonePermission(recognizer: recognizer, generation: generation)
            }
        }
    }

    private func requestMicrophonePermission(recognizer: SFSpeechRecognizer, generation: Int) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            self.queue.async {
                guard granted else {
                    return self.finish(.denied, generation: generation)
                }
                self.startCapture(recognizer: recognizer, generation: generation)
            }
        }
    }

    private func startCapture(recognizer: SFSpeechRecognizer, generation: Int) {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            return finish(.failed("Couldn't start audio capture. Try again or type your question."), generation: generation)
        }
#endif
        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = RanchOSLivestockSampleCatalog.developmentSamples.map(\.displayName)
            + ["herd", "livestock", "cattle"]

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        self.audioEngine = audioEngine
        self.request = request
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Extract Sendable values before hopping queues; the result object stays behind.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = result == nil && error != nil
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleRecognition(transcript: transcript, isFinal: isFinal, failed: failed, generation: generation)
            }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            finish(.failed("Couldn't start audio capture. Try again or type your question."), generation: generation)
        }
    }

    private func handleRecognition(transcript: String?, isFinal: Bool, failed: Bool, generation: Int) {
        guard generation == self.generation, eventHandler != nil else { return }
        if let transcript {
            if isFinal {
                finish(.finalTranscript(transcript), generation: generation)
            } else {
                eventHandler?(.partialTranscript(transcript))
            }
            return
        }
        if failed {
            finish(.failed("I didn't catch that. Try again or type your question."), generation: generation)
        }
    }

    private func finish(_ event: RanchOSJarvisSpeechEvent, generation: Int) {
        guard generation == self.generation else { return }
        self.generation += 1
        let handler = eventHandler
        eventHandler = nil
        tearDownAudio()
        handler?(event)
    }

    private func tearDownAudio() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
#endif
    }

    private static var onDeviceUnavailableMessage: String {
#if os(macOS)
        "On-device dictation isn't available on this Mac. Typed questions work the same."
#else
        "On-device dictation isn't available on this iPhone or iPad. Typed questions work the same."
#endif
    }

    private static func preferredLocale() -> Locale? {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        for identifier in ["en-US", Locale.current.identifier] where supported.contains(identifier) {
            return Locale(identifier: identifier)
        }
        return nil
    }
}
#endif

/// Shared Jarvis conversation UI: typed ask, explicit push-to-talk, labeled
/// fixture answer, explicit read-aloud. The store is owned by the parent so
/// the Home card and the full workspace share one implementation.
struct RanchOSJarvisConversationView: View {
    @Bindable var store: RanchOSJarvisStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.captionText)
                .font(.caption.weight(.medium))
                .foregroundStyle(detailColor)
                .accessibilityLabel(store.captionText)

            HStack(spacing: 10) {
                TextField("Ask about the sample herd", text: $store.question)
#if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    .accessibilityLabel("Ask Jarvis a question")
                    .accessibilityHint("Type a question about the DEV sample herd")
                    .onSubmit { Task { await store.askWithUnderstanding() } }
                Button("Ask") { Task { await store.askWithUnderstanding() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            signInRow

#if !os(tvOS)
            talkControls
#endif

            if let answer = store.answer {
                Text(answer.text)
                    .font(.subheadline)
                Button(store.isSpeaking ? "Stop" : "Read aloud") { store.toggleSpeech() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Speaks the Jarvis answer aloud")
            }
        }
    }

    /// Sign-in control beside the understanding label. tvOS renders the label
    /// only and compiles no control.
    @ViewBuilder
    private var signInRow: some View {
        HStack(spacing: 10) {
#if !os(tvOS)
            signInControl
#endif
            if let understandingLabel = store.understandingLabel {
                Text(understandingLabel)
                    .font(.caption)
                    .foregroundStyle(detailColor)
            }
        }
    }

#if !os(tvOS)
    @ViewBuilder
    private var signInControl: some View {
        if store.isSigningIn {
            Text("Signing in…")
                .font(.caption)
                .foregroundStyle(detailColor)
            Button("Cancel") { store.cancelSignIn() }
                .buttonStyle(.bordered)
                .accessibilityHint("Stops this sign-in")
        } else if store.isSignedIn {
            Text("Signed in to Ranch OS DEV")
                .font(.caption)
                .foregroundStyle(detailColor)
            Button("Sign out") { Task { await store.signOut() } }
                .buttonStyle(.bordered)
                .accessibilityHint("Ends the RanchBrain session on this device")
        } else {
            Button("Sign in") { Task { await store.signIn() } }
                .buttonStyle(.bordered)
                .accessibilityHint("Signs in to Ranch OS DEV")
        }
    }

    @ViewBuilder
    private var talkControls: some View {
        switch store.speechState {
        case .idle, .unavailable, .failed, .denied:
            HStack(spacing: 10) {
                Button {
                    store.startTalking()
                } label: {
                    Label("Start listening", systemImage: "mic")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canTalk)
                .accessibilityHint("Records one spoken question, then transcribes it")
                Text(talkCaption)
                    .font(.caption)
                    .foregroundStyle(detailColor)
            }
            if case .unavailable(let message) = store.speechState {
                Text(message).font(.subheadline).foregroundStyle(detailColor)
            }
            if case .failed(let message) = store.speechState {
                Text(message).font(.subheadline).foregroundStyle(detailColor)
            }
            if case .denied = store.speechState {
                Text(deniedGuidance).font(.subheadline).foregroundStyle(detailColor)
            }
        case .listening(let partial):
            Label("Listening… speak now, then tap Stop.", systemImage: "waveform.circle.fill")
                .font(.subheadline.weight(.semibold))
            if !partial.isEmpty {
                Text("Hearing: \(partial)")
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
            }
            HStack(spacing: 10) {
                Button("Stop listening") { store.stopTalking() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Ends recording and transcribes the question")
                Button("Cancel") { store.cancelTalking() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Discards this recording without transcribing")
            }
        }
    }

    private var talkCaption: String { "Start listening uses on-device dictation." }

#if os(macOS)
    private var deniedGuidance: String {
        "Microphone or speech recognition is off. Enable both in System Settings > Privacy & Security, or keep typing."
    }
#else
    private var deniedGuidance: String {
        "Microphone or speech recognition is off. Enable both in Settings > Privacy & Security, or keep typing."
    }
#endif
#endif

#if os(tvOS)
    private var detailColor: Color { .white.opacity(0.72) }
#else
    private var detailColor: Color { Color(red: 0.28, green: 0.33, blue: 0.27) }
#endif
}

struct RanchOSJarvisCard: View {
#if os(tvOS)
    @State private var store = RanchOSJarvisStore(retriever: RanchBrainRetriever.devService())
#else
    @State private var store = RanchOSJarvisStore.makeDevStore()
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ask Jarvis", systemImage: "waveform")
                .font(.headline)

            RanchOSJarvisConversationView(store: store)
        }
        .foregroundStyle(titleColor)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

#if os(tvOS)
    private var titleColor: Color { .white }
    private var cardBackground: Color { .white.opacity(0.13) }
#else
    private var titleColor: Color { Color(red: 0.09, green: 0.13, blue: 0.10) }
    private var cardBackground: Color { .white.opacity(0.72) }
#endif
}

#if !os(tvOS)
/// Full Jarvis workspace behind the sidebar/compact entry (Mac/iOS only).
/// Same store and read-only answerer as the Home card, plus sample
/// questions and an availability-only Apple Intelligence disclosure.
/// RanchBrain is contacted only after a session exists. No background listening.
struct RanchOSJarvisWorkspace: View {
    @State private var store = RanchOSJarvisStore.makeDevStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isActive: Bool {
        store.isSpeaking || store.speechState != .idle
    }

    private var statusText: String {
        store.workspaceStatusText()
    }

    var body: some View {
        ZStack {
            hudBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("RanchOS · Jarvis", systemImage: "sparkle")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("DEV · SAMPLE DATA")
                                .font(.caption.bold())
                                .foregroundStyle(.cyan)
                            Text(RanchOSBuildInfo.display)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .accessibilityLabel("Application version")
                        }
                    }

                    HStack(spacing: 20) {
                        jarvisCore
                        VStack(alignment: .leading, spacing: 8) {
                            Text(statusText)
                                .font(.headline)
                                .foregroundStyle(.cyan)
                            Text(RanchOSJarvis.introduction)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.75))
                            Button("Meet Jarvis") { store.speakIntroduction() }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Jarvis introduces himself aloud")
                        }
                    }

                    RanchOSJarvisConversationView(store: store)
                        .foregroundStyle(titleColor)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try a sample question")
                            .font(.headline)
                            .foregroundStyle(.white)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { suggestionButtons }
                            VStack(alignment: .leading, spacing: 10) { suggestionButtons }
                        }
                    }

                    DisclosureGroup("Apple Intelligence readiness") {
                        Text(Self.modelReadiness)
                            .font(.footnote)
                        Text(Self.modelFootnote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)

                    Text("Speech stays on this device. Typed questions never leave this device. Live records are disconnected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
        .tint(.cyan)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onDisappear { store.cancelTalking() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.cancelTalking() }
        }
    }

    private var jarvisCore: some View {
        ZStack {
            Circle()
                .stroke(.cyan.opacity(0.35), lineWidth: 1)
            Circle()
                .inset(by: 9)
                .stroke(.cyan, style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
            Circle()
                .inset(by: 20)
                .fill(.cyan.opacity(isActive ? (pulse ? 0.45 : 0.25) : 0.18))
            Text("JARVIS")
                .font(.caption)
                .tracking(3)
                .foregroundStyle(.white)
        }
        .frame(width: 120, height: 120)
        .scaleEffect(isActive && !reduceMotion && pulse ? 1.05 : 1.0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        ForEach(RanchOSJarvis.sampleQuestions, id: \.self) { sample in
            Button(sample) { askSuggestion(sample) }
                .buttonStyle(.bordered)
        }
    }

    private func askSuggestion(_ text: String) {
        store.cancelTalking()
        store.question = text
        Task { await store.askWithUnderstanding() }
    }

    private var hudBackground: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.02, green: 0.05, blue: 0.07), Color(red: 0.035, green: 0.07, blue: 0.09)],
            startPoint: .top,
            endPoint: .bottom)
    }

    private var titleColor: Color { Color(red: 0.09, green: 0.13, blue: 0.10) }

    private static var modelReadiness: String {
#if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "On-device language model is available; replies are shaped on-device from sample-herd facts."
            case .unavailable: return "On-device language model is unavailable. Sample controls remain usable."
            @unknown default: return "Model availability is unknown. Sample controls remain usable."
            }
        }
#endif
        return "On-device model integration requires a supported system. Sample controls remain usable."
    }

    private static var modelFootnote: String {
        if ModelRouter.isFMUsable() {
            return "Understanding and shaping run on-device over retrieved facts. No third-party remote calls."
        }
        if ModelRouter.isDeviceNotEligible() {
            return "On-device Apple Intelligence when available. When device not eligible, routes to Apple Private Cloud Compute (PCC) \u{2014} approved by owner \u{2014} otherwise keyword fallback. No third-party remote calls."
        }
        return "On-device understanding unavailable; keyword answers with honest labels. No third-party remote calls."
    }
}
#endif
