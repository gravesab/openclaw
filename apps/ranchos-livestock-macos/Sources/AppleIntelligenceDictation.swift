import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

#if os(macOS)
import AppKit
import AudioToolbox
import CoreAudio
#endif
#if os(iOS)
import UIKit
#endif

/// Completes a field with an on-device dictation utterance.
/// A selected range is replaced. A caret inserts at that point. Otherwise the
/// utterance continues after text the person already typed.
enum AppleIntelligenceDictationText {
    static func completed(prefix: String, utterance: String) -> String {
        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return prefix }
        guard !prefix.isEmpty else { return spoken }
        if let last = prefix.last, last.isWhitespace || last.isNewline {
            return prefix + spoken
        }
        return prefix + " " + spoken
    }

    static func completed(value: String, replacingUTF16 range: Range<Int>?, utterance: String) -> String {
        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range,
              let prefix = utf16Slice(value, start: 0, end: range.lowerBound),
              let suffix = utf16Slice(value, start: range.upperBound, end: value.utf16.count)
        else {
            return completed(prefix: value, utterance: spoken)
        }
        guard !spoken.isEmpty else { return value }
        if range.lowerBound == range.upperBound {
            return insert(spoken, between: prefix, and: suffix)
        }
        return prefix + spoken + suffix
    }

    private static func insert(_ spoken: String, between prefix: String, and suffix: String) -> String {
        let head = completed(prefix: prefix, utterance: spoken)
        guard !suffix.isEmpty else { return head }
        if let last = head.last, last.isWhitespace || last.isNewline {
            return head + suffix
        }
        if let first = suffix.first, first.isWhitespace || first.isNewline {
            return head + suffix
        }
        return head + " " + suffix
    }

    static func utf16Slice(_ value: String, start: Int, end: Int) -> String? {
        let utf16 = value.utf16
        guard start >= 0, end >= start, end <= utf16.count else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: start)
        let upper = utf16.index(utf16.startIndex, offsetBy: end)
        guard let from = String.Index(lower, within: value),
              let to = String.Index(upper, within: value) else { return nil }
        return String(value[from..<to])
    }

    struct Session: Equatable {
        private(set) var finalized = ""
        private(set) var volatileText = ""

        var utterance: String {
            AppleIntelligenceDictationText.completed(prefix: self.finalized, utterance: self.volatileText)
        }

        /// Apple Intelligence dictation delivers stable chunks plus a replaceable tail.
        mutating func applySegment(text: String, isFinal: Bool) {
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFinal {
                if !spoken.isEmpty {
                    self.finalized = AppleIntelligenceDictationText.completed(prefix: self.finalized, utterance: spoken)
                }
                self.volatileText = ""
            } else {
                self.volatileText = spoken
            }
        }

        /// Older on-device recognition reports the full utterance so far.
        mutating func applyFullTranscript(_ text: String) {
            self.finalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.volatileText = ""
        }
    }
}

@MainActor
private enum AppleIntelligenceDictationHub {
    weak static var active: AppleIntelligenceDictationController?
}

/// Microphone control that completes a text field with on-device speech.
///
/// On macOS 26 and iOS 26 this uses `DictationTranscriber`, the Apple Intelligence
/// dictation engine. Older systems use on-device `SFSpeechRecognizer` and never
/// send audio to a recognition server.
@MainActor
private final class AppleIntelligenceDictationRuntime {
    var engine: AVAudioEngine?
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var tapInstalled = false
    var activatedAudioSession = false
    var intelligenceHandle: AnyObject?
}

@MainActor
@Observable
final class AppleIntelligenceDictationController {
    private(set) var isListening = false
    private(set) var isPreparing = false
    private(set) var status = ""

    private var text: Binding<String>?
    private var baseValue = ""
    private var replacementUTF16: Range<Int>?
    private var liveUTF16: Range<Int>?
    private var composer = AppleIntelligenceDictationText.Session()
    private var generation = UUID()
    private let runtime = AppleIntelligenceDictationRuntime()

    var showsMessage: Bool {
        !self.status.isEmpty
    }

    var accessibilityLabel: String {
        if self.isListening || self.isPreparing {
            return "Stop dictation"
        }
        if #available(macOS 26, iOS 26, *) {
            return "Dictate with Apple Intelligence"
        }
        return "Dictate on this device"
    }

    func bind(_ text: Binding<String>) {
        self.text = text
    }

    /// Keeps the last selection while the field is focused. Clicking the
    /// microphone blurs the field and would otherwise drop that range.
    func noteLiveSelection(_ range: Range<Int>) {
        guard !self.isListening, !self.isPreparing else { return }
        self.liveUTF16 = range
    }

    func toggle() async {
        if self.isListening || self.isPreparing {
            self.stop()
            return
        }
        await self.start()
    }

    func stop() {
        self.generation = UUID()
        self.finishCapture(status: "")
    }

    private func start() async {
        let generation = UUID()
        self.generation = generation
        self.isPreparing = true
        self.status = "Checking speech and microphone permission…"
        self.baseValue = self.text?.wrappedValue ?? ""
        self.replacementUTF16 = self.liveUTF16.flatMap { range in
            AppleIntelligenceDictationText.utf16Slice(
                self.baseValue,
                start: range.lowerBound,
                end: range.upperBound
            ) == nil ? nil : range
        }
        self.composer = AppleIntelligenceDictationText.Session()

        if let active = AppleIntelligenceDictationHub.active, active !== self {
            active.stop()
        }
        AppleIntelligenceDictationHub.active = self

        let speechAllowed = await Self.requestSpeechAuthorization()
        guard self.generation == generation else { return }
        guard speechAllowed else {
            self.fail("Speech permission is off. You can still type.")
            return
        }
        let microphoneAllowed = await Self.requestMicrophonePermission()
        guard self.generation == generation else { return }
        guard microphoneAllowed else {
            self.fail("Microphone permission is off. You can still type.")
            return
        }

        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *), await self.startAppleIntelligence(generation: generation) {
            return
        }
        guard self.generation == generation else { return }
        #endif

        self.startLegacyRecognition(generation: generation)
    }

    private func publish() {
        guard let text = self.text else { return }
        text.wrappedValue = AppleIntelligenceDictationText.completed(
            value: self.baseValue,
            replacingUTF16: self.replacementUTF16,
            utterance: self.composer.utterance)
    }

    private func fail(_ message: String) {
        self.finishCapture(status: message)
    }

    private func finishCapture(status: String) {
        self.runtime.task?.cancel()
        self.runtime.task = nil
        self.runtime.request?.endAudio()
        self.runtime.request = nil
        if self.runtime.tapInstalled, let engine = self.runtime.engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        self.runtime.tapInstalled = false
        self.runtime.engine?.stop()
        self.runtime.engine = nil
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            let handle = self.runtime.intelligenceHandle as? AppleIntelligenceEngineHandle
            handle?.listener?.cancel()
            let engine = handle?.engine
            self.runtime.intelligenceHandle = nil
            if let engine {
                Task { await engine.stop() }
            }
        }
        #endif
        if self.runtime.activatedAudioSession {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            self.runtime.activatedAudioSession = false
        }
        self.isListening = false
        self.isPreparing = false
        self.status = status
        self.liveUTF16 = nil
        self.replacementUTF16 = nil
        if AppleIntelligenceDictationHub.active === self {
            AppleIntelligenceDictationHub.active = nil
        }
    }

    private func startLegacyRecognition(generation: UUID) {
        guard let recognizer = Self.onDeviceRecognizer() else {
            self.fail("On-device dictation isn't available. You can still type.")
            return
        }
        do {
            try self.activateRecordingSessionIfNeeded()
            let audioEngine = AVAudioEngine()
            let microphone = Self.connectedMicrophone(for: audioEngine)
            guard let microphone else {
                self.fail("No microphone is available. You can still type.")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.fail("No microphone is available. You can still type.")
                return
            }
            let box = SpeechRequestBox(request)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                box.request.append(buffer)
            }
            self.runtime.tapInstalled = true
            self.runtime.engine = audioEngine
            self.runtime.request = request
            self.runtime.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    if let transcript {
                        self.composer.applyFullTranscript(transcript)
                        self.publish()
                    }
                    if finished {
                        if error != nil, (transcript ?? "").isEmpty {
                            self.finishCapture(status: "Dictation stopped. You can still type.")
                        } else {
                            self.finishCapture(status: "")
                        }
                    }
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            self.isPreparing = false
            self.isListening = true
            self.status = Self.listeningStatus(appleIntelligence: false, microphone: microphone)
        } catch {
            self.fail("Dictation could not start. You can still type.")
        }
    }

    private static func connectedMicrophone(for engine: AVAudioEngine) -> String? {
        #if os(macOS)
        guard let input = DictationMicrophone.preferredInput() else { return nil }
        guard DictationMicrophone.attach(deviceID: input.id, to: engine) else { return nil }
        return input.name
        #else
        _ = engine
        return ""
        #endif
    }

    private static func listeningStatus(appleIntelligence: Bool, microphone: String) -> String {
        let mode = appleIntelligence
            ? "Listening with Apple Intelligence"
            : "Listening with on-device dictation"
        guard !microphone.isEmpty else { return mode + "." }
        return "\(mode) on \(microphone)."
    }

    private func activateRecordingSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        self.runtime.activatedAudioSession = true
        #endif
    }

    private static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        let locales = [Locale.current, Locale(identifier: "en_US"), Locale(identifier: "en-US")]
        for locale in locales {
            guard let recognizer = SFSpeechRecognizer(locale: locale),
                  recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else { continue }
            return recognizer
        }
        return nil
    }

    private static func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized {
            return true
        }
        guard current == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        let current = AVAudioApplication.shared.recordPermission
        if current == .granted {
            return true
        }
        guard current == .undetermined else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    #if compiler(>=6.2)
    @available(macOS 26, iOS 26, *)
    private func startAppleIntelligence(generation: UUID) async -> Bool {
        guard let locale = await Self.appleIntelligenceLocale() else { return false }
        let engine = AppleIntelligenceDictationEngine()
        let handle = AppleIntelligenceEngineHandle()
        handle.engine = engine
        self.runtime.intelligenceHandle = handle
        do {
            self.status = "Preparing Apple Intelligence dictation…"
            let started = try await engine.start(locale: locale)
            guard self.generation == generation else {
                await engine.stop()
                return false
            }
            handle.listener = Task { @MainActor [weak self] in
                for await piece in started.pieces {
                    guard let self, self.generation == generation else { return }
                    self.composer.applySegment(text: piece.text, isFinal: piece.isFinal)
                    self.publish()
                }
            }
            self.isPreparing = false
            self.isListening = true
            self.status = Self.listeningStatus(appleIntelligence: true, microphone: started.microphone)
            return true
        } catch {
            await engine.stop()
            if self.generation == generation {
                self.runtime.intelligenceHandle = nil
            }
            return false
        }
    }

    @available(macOS 26, iOS 26, *)
    private static func appleIntelligenceLocale() async -> Locale? {
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
            return match
        }
        let supported = await DictationTranscriber.supportedLocales
        return supported.first { $0.identifier.hasPrefix("en") } ?? supported.first
    }
    #endif
}

struct DictationMicrophoneCandidate: Equatable, Sendable {
    var name: String
    var isDefault: Bool
}

/// Picks a dictation input on this Mac. A local USB input wins over the webcam.
/// An iPhone Continuity microphone is skipped so the phone does not show a microphone alert.
enum DictationMicrophonePicker {
    static func preferred(among devices: [DictationMicrophoneCandidate]) -> DictationMicrophoneCandidate? {
        var best: (device: DictationMicrophoneCandidate, score: Int)?
        for device in devices {
            let score = self.score(device)
            guard score > 0 else { continue }
            guard let current = best else {
                best = (device, score)
                continue
            }
            if score > current.score {
                best = (device, score)
            }
        }
        return best?.device
    }

    static func score(_ device: DictationMicrophoneCandidate) -> Int {
        let name = device.name.lowercased()
        if name.contains("teams") || name.contains("iphone") {
            return 0
        }
        if name.contains("microphone") {
            return 300
        }
        if name.contains("webcam") || name.contains("camera") {
            return 40
        }
        if device.isDefault {
            return 120
        }
        return 80
    }
}

#if os(macOS)
enum DictationMicrophone {
    static func connectedMicrophone(for engine: AVAudioEngine) -> String? {
        guard let input = self.preferredInput() else { return nil }
        guard self.attach(deviceID: input.id, to: engine) else { return nil }
        return input.name
    }

    static func preferredInput() -> (id: AudioDeviceID, name: String)? {
        let devices = self.inputDevices()
        guard let preferred = DictationMicrophonePicker.preferred(among: devices.map {
            DictationMicrophoneCandidate(name: $0.name, isDefault: $0.isDefault)
        }) else {
            return nil
        }
        return devices.first { $0.name == preferred.name && $0.isDefault == preferred.isDefault }
            .map { ($0.id, $0.name) }
    }

    static func attach(deviceID: AudioDeviceID, to engine: AVAudioEngine) -> Bool {
        if #available(macOS 27, *) {
            return engine.inputNode.withAudioUnit { audioUnit in
                self.setCurrentDevice(deviceID, on: audioUnit)
            }
        }
        return self.setCurrentDevice(deviceID, on: engine.inputNode.audioUnit)
    }

    private static func setCurrentDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) -> Bool {
        guard let audioUnit else { return false }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }

    private static func inputDevices() -> [(id: AudioDeviceID, name: String, isDefault: Bool)] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs)
        guard status == noErr else { return [] }
        let defaultID = self.defaultInputDeviceID()
        var devices: [(id: AudioDeviceID, name: String, isDefault: Bool)] = []
        for deviceID in deviceIDs where self.deviceHasInput(deviceID) {
            let name = self.deviceName(for: deviceID) ?? "Microphone"
            devices.append((deviceID, name, deviceID == defaultID))
        }
        return devices
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer<AudioBufferList>(OpaquePointer(raw)))
        return buffers.contains { $0.mNumberChannels > 0 }
    }
}
#endif

private final class SpeechRequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

#if compiler(>=6.2)
@available(macOS 26, iOS 26, *)
private final class AppleIntelligenceEngineHandle {
    var engine: AppleIntelligenceDictationEngine?
    var listener: Task<Void, Never>?
}

private struct DictationPiece: Sendable {
    var text: String
    var isFinal: Bool
}

@available(macOS 26, iOS 26, *)
private final actor AppleIntelligenceDictationEngine {
    private struct AudioBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private let audioEngine = AVAudioEngine()
    private let converter = DictationFormatConverter()
    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var tapInstalled = false

    func start(locale: Locale) async throws -> (pieces: AsyncStream<DictationPiece>, microphone: String) {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        self.transcriber = transcriber
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        switch assetStatus {
        case .installed:
            break
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw DictationEngineError.unavailable
        @unknown default:
            throw DictationEngineError.unavailable
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationEngineError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        #if os(macOS)
        let microphone = DictationMicrophone.connectedMicrophone(for: self.audioEngine)
        guard let microphone else {
            throw DictationEngineError.noMicrophone
        }
        #else
        let microphone = ""
        #endif
        let input = self.audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationEngineError.noMicrophone
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let copy = DictationAudioCopy.copy(buffer) else { return }
            let boxed = AudioBox(buffer: copy)
            Task { await self?.consume(boxed, target: format) }
        }
        self.tapInstalled = true
        let (pieces, pieceContinuation) = AsyncStream<DictationPiece>.makeStream()
        self.resultTask = Task {
            do {
                for try await result in transcriber.results {
                    pieceContinuation.yield(
                        DictationPiece(
                            text: String(result.text.characters),
                            isFinal: result.isFinal))
                }
            } catch {
                pieceContinuation.finish()
            }
            pieceContinuation.finish()
        }
        self.audioEngine.prepare()
        try self.audioEngine.start()
        try await analyzer.start(inputSequence: inputs)
        return (pieces, microphone)
    }

    func stop() async {
        self.resultTask?.cancel()
        self.resultTask = nil
        self.inputContinuation?.finish()
        self.inputContinuation = nil
        if self.tapInstalled {
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.tapInstalled = false
        }
        self.audioEngine.stop()
        try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
        self.analyzer = nil
        self.transcriber = nil
    }

    private func consume(_ box: AudioBox, target: AVAudioFormat) {
        guard let converted = self.converter.convert(box.buffer, to: target) else { return }
        self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
    }
}

private enum DictationEngineError: Error {
    case unavailable
    case noMicrophone
}

private final class DictationFormatConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }
        if self.converter == nil || self.outputFormat != format {
            self.converter = AVAudioConverter(from: buffer.format, to: format)
            self.outputFormat = format
        }
        guard let converter = self.converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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

private enum DictationAudioCopy {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        let channels = Int(buffer.format.channelCount)
        let count = Int(frames)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: count)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: count)
            }
            return copy
        }
        return nil
    }
}

private struct AppleIntelligenceDictationModifier: ViewModifier {
    @Binding var text: String
    @State private var controller = AppleIntelligenceDictationController()

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                content
                    .layoutPriority(1)
                    .background {
                        DictationSelectionProbe { range in
                            self.controller.noteLiveSelection(range)
                        }
                    }
                Button {
                    Task { await self.controller.toggle() }
                } label: {
                    if self.controller.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: self.controller.isListening ? "mic.fill" : "mic")
                            .foregroundStyle(self.controller.isListening ? Color.red : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(self.controller.accessibilityLabel)
                .help(self.controller.accessibilityLabel + ". Speech stays on this device.")
            }
            if self.controller.showsMessage {
                Text(self.controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { self.controller.bind(self.$text) }
        .onDisappear { self.controller.stop() }
    }
}

/// Watches the adjacent text field so a selected word is still known after
/// the microphone click blurs the field.
private struct DictationSelectionProbe: View {
    var onRange: (Range<Int>) -> Void

    var body: some View {
        DictationSelectionProbeView(onRange: onRange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
private struct DictationSelectionProbeView: NSViewRepresentable {
    var onRange: (Range<Int>) -> Void

    func makeNSView(context: Context) -> DictationSelectionNSView {
        let view = DictationSelectionNSView()
        view.onRange = onRange
        return view
    }

    func updateNSView(_ view: DictationSelectionNSView, context: Context) {
        view.onRange = onRange
    }

    static func dismantleNSView(_ view: DictationSelectionNSView, coordinator: ()) {
        view.stop()
    }
}

private final class DictationSelectionNSView: NSView {
    var onRange: ((Range<Int>) -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handle(note)
        }
        reportIfActive()
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handle(_ note: Notification) {
        guard let textView = note.object as? NSTextView else { return }
        guard textView.window === window else { return }
        guard textView === textView.window?.firstResponder else { return }
        guard nearbyTextInputs().contains(where: { input in
            if let field = input as? NSTextField {
                return textView === field.currentEditor()
            }
            return input === textView
        }) else { return }
        let range = textView.selectedRange()
        guard range.location != NSNotFound else { return }
        onRange?(range.location..<(range.location + range.length))
    }

    private func reportIfActive() {
        guard let textView = window?.firstResponder as? NSTextView else { return }
        handle(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    }

    private func nearbyTextInputs() -> [NSView] {
        var node: NSView? = self.superview
        var depth = 0
        while let current = node, depth < 6 {
            var found: [NSView] = []
            collectTextInputs(in: current, into: &found)
            if !found.isEmpty { return found }
            node = current.superview
            depth += 1
        }
        return []
    }

    private func collectTextInputs(in view: NSView, into found: inout [NSView]) {
        if view is NSTextField || view is NSTextView {
            found.append(view)
            return
        }
        for sub in view.subviews {
            collectTextInputs(in: sub, into: &found)
        }
    }
}
#else
private struct DictationSelectionProbeView: UIViewRepresentable {
    var onRange: (Range<Int>) -> Void

    func makeUIView(context: Context) -> DictationSelectionUIView {
        let view = DictationSelectionUIView()
        view.onRange = onRange
        return view
    }

    func updateUIView(_ view: DictationSelectionUIView, context: Context) {
        view.onRange = onRange
    }

    static func dismantleUIView(_ view: DictationSelectionUIView, coordinator: ()) {
        view.stop()
    }
}

private final class DictationSelectionUIView: UIView {
    var onRange: ((Range<Int>) -> Void)?
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stop()
        guard window != nil else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] note in
                self?.editingChanged(note.object as? UIView, began: true)
            },
            center.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] note in
                self?.editingChanged(note.object as? UIView, began: true)
            },
            center.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] note in
                self?.editingChanged(note.object as? UIView, began: false)
            },
            center.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] note in
                self?.editingChanged(note.object as? UIView, began: false)
            },
        ]
        reportIfFirstResponder()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    deinit {
        displayLink?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func editingChanged(_ view: UIView?, began: Bool) {
        guard let view, nearbyTextInputs().contains(where: { $0 === view }) else { return }
        if began {
            startLink()
            report(from: view)
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func startLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        reportIfFirstResponder()
    }

    private func reportIfFirstResponder() {
        guard let input = nearbyTextInputs().first(where: { $0.isFirstResponder }) else { return }
        report(from: input)
    }

    private func report(from view: UIView) {
        guard let input = view as? UITextInput,
              let selected = input.selectedTextRange else { return }
        let start = input.offset(from: input.beginningOfDocument, to: selected.start)
        let end = input.offset(from: input.beginningOfDocument, to: selected.end)
        onRange?(start..<end)
    }

    private func nearbyTextInputs() -> [UIView] {
        var node: UIView? = self.superview
        var depth = 0
        while let current = node, depth < 6 {
            var found: [UIView] = []
            collectTextInputs(in: current, into: &found)
            if !found.isEmpty { return found }
            node = current.superview
            depth += 1
        }
        return []
    }

    private func collectTextInputs(in view: UIView, into found: inout [UIView]) {
        if view is UITextField || view is UITextView {
            found.append(view)
            return
        }
        for sub in view.subviews {
            collectTextInputs(in: sub, into: &found)
        }
    }
}
#endif

extension View {
    /// Adds a microphone that completes this text with on-device Apple Intelligence dictation.
    public func appleIntelligenceDictation(_ text: Binding<String>) -> some View {
        self.modifier(AppleIntelligenceDictationModifier(text: text))
    }
}
