import Foundation
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Single routing decision for one Jarvis question. The router never calls a
/// model itself: it reports which path produced the reply text, plus an honest
/// user-facing label. Route raw values are the approved chain-step markers.
struct RanchModelDecision: Equatable, Sendable {
    enum Route: String, Equatable, Sendable {
        /// Reply text was shaped on-device by FoundationModels over retrieved facts.
        case onDeviceUnderstanding = "1_apple_on_device"
        /// Reply text was shaped via Apple Private Cloud Compute (PCC approved
        /// by owner 20260930; same LanguageModelSession API, Apple routes).
        case applePCC = "2_apple_pcc_APPROVED"
        /// Reply text came from the deterministic keyword path.
        case deterministicOnly = "deterministic_only"
    }

    let route: Route
    let label: String
    /// Intent the model assigned, when classification ran.
    let intent: RanchJarvisIntentKind?
    /// Find terms the model extracted, when extraction ran.
    let terms: [String]

    nonisolated static func deterministic(label: String) -> RanchModelDecision {
        RanchModelDecision(route: .deterministicOnly, label: label, intent: nil, terms: [])
    }
}

/// Intent labels the model may assign. String-backed so the deterministic
/// core and the tests never need FoundationModels.
enum RanchJarvisIntentKind: String, Equatable, Sendable {
    case answerSupported
    case findRecords
    case weather
    case unsupported
}

/// Animal names / find terms extracted from one question.
struct RanchFindTerms: Equatable, Sendable {
    let terms: [String]
}

/// Model chain (phase 2 — PCC APPROVED by owner 20260930):
/// 1. FoundationModels `.available` -> on-device LanguageModelSession.
/// 2. `.unavailable(.deviceNotEligible)` -> Apple Private Cloud Compute via
///    the same LanguageModelSession API (Apple routes); the session attempt
///    is the probe — any failure falls through to deterministic with an
///    honest label. Ranch facts leave the device on this route by owner approval.
/// 3. Any other `.unavailable` reason -> deterministic keyword path, never a
///    silent remote or local-LLM fallback (none authorized; the approved
///    sketch's external-LLM echo stub is deliberately not installed — it
///    fabricates output).
/// 4. RanchFMAnswerer produces the unified output for every route.
enum ModelRouter {
    /// Unified routing decision. `fmUsableOverride` is a test seam meaning
    /// "no model at all" when false (PCC is skipped, not probed); production
    /// always passes nil so the real availability gates decide.
    nonisolated static func decide(fmUsableOverride: Bool? = nil) -> RanchModelDecision {
        if fmUsableOverride ?? isFMUsable() {
            return RanchModelDecision(
                route: .onDeviceUnderstanding,
                label: "Reply shaped on-device from sample-herd facts.",
                intent: nil,
                terms: [])
        }
        if fmUsableOverride == nil, isDeviceNotEligible() {
            return RanchModelDecision(
                route: .applePCC,
                label: "Reply shaped with Apple Private Cloud Compute from sample-herd facts.",
                intent: nil,
                terms: [])
        }
        return .deterministic(label: fallbackLabel())
    }

    /// Per-reason honest label for the deterministic route.
    nonisolated static func fallbackLabel() -> String {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "On-device understanding became unavailable. Keyword answers only."
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device can't run on-device understanding. Keyword answers only; nothing was sent anywhere."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is off, so on-device understanding is unavailable. Keyword answers only."
                case .modelNotReady:
                    return "The on-device model isn't ready yet. Keyword answers only."
                @unknown default:
                    return "On-device understanding is unavailable. Keyword answers only."
                }
            }
        }
#endif
        return "On-device understanding needs a supported system. Keyword answers only."
    }

    nonisolated static func isFMUsable() -> Bool {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
#endif
        return false
    }

    /// True only when the on-device model reports
    /// `.unavailable(.deviceNotEligible)` — the PCC-approved precondition.
    /// There is no separate PCC availability gate: per the approved pattern
    /// the LanguageModelSession attempt itself is the probe.
    nonisolated static func isDeviceNotEligible() -> Bool {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
                return true
            }
        }
#endif
        return false
    }
}

/// Model understanding over one question. Implementations return nil on ANY
/// failure (unavailable, error, refusal, invalid output) so the caller always
/// falls back to the deterministic reply. The live implementation makes no
/// network calls itself; on the PCC route Apple routes the session.
protocol RanchFMUnderstanding: Sendable {
    func classify(question: String) async -> RanchJarvisIntentKind?
    func extractTerms(question: String) async -> RanchFindTerms?
    func shape(question: String, facts: String, intent: RanchJarvisIntentKind, terms: RanchFindTerms) async -> String?
}

#if canImport(FoundationModels) && !os(tvOS)
/// Structured intent for the classify call. The model must return exactly one
/// of these labels; anything else fails decoding and falls back.
@available(macOS 26, iOS 26, *)
@Generable
enum RanchGenerableIntent: String {
    case answerSupported
    case findRecords
    case weather
    case unsupported
}

/// Structured find terms for the extraction call.
@available(macOS 26, iOS 26, *)
@Generable
struct RanchGenerableTerms {
    var terms: [String]
}
#endif

/// Live Apple-model implementation. Each call creates its own session (no stored
/// session, no cross-task sharing) with facts-only instructions. On systems
/// without FoundationModels every method returns nil -> deterministic fallback.
/// On device-ineligible systems the same session API is used for the PCC route
/// (Apple routes; owner-approved) — a throw still falls back.
struct RanchLiveFMUnderstanding: RanchFMUnderstanding {
    func classify(question: String) async -> RanchJarvisIntentKind? {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: Self.classifyInstructions)
                let response = try await session.respond(
                    to: "Classify this ranch question: \(question)",
                    generating: RanchGenerableIntent.self)
                return RanchJarvisIntentKind(rawValue: response.content.rawValue)
            } catch {
                return nil
            }
        }
#endif
        return nil
    }

    func extractTerms(question: String) async -> RanchFindTerms? {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: Self.extractInstructions)
                let response = try await session.respond(
                    to: "Find terms in this ranch question: \(question)",
                    generating: RanchGenerableTerms.self)
                return RanchFindTerms(terms: response.content.terms)
            } catch {
                return nil
            }
        }
#endif
        return nil
    }

    func shape(question: String, facts: String, intent: RanchJarvisIntentKind, terms: RanchFindTerms) async -> String? {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: Self.shapeInstructions)
                let prompt = """
                    Question: \(question)
                    Intent: \(intent.rawValue)
                    Find terms: \(terms.terms.joined(separator: ", "))
                    Facts: \(facts)
                    Reply:
                    """
                let response = try await session.respond(to: prompt)
                return response.content
            } catch {
                return nil
            }
        }
#endif
        return nil
    }

    nonisolated private static let classifyInstructions =
        "You classify ranch questions. Reply with exactly one label and nothing else."

    nonisolated private static let extractInstructions =
        "You list animal names or find terms from ranch questions. Reply with the terms only, empty when there are none."

    nonisolated private static let shapeInstructions =
        "You restate ONLY the given sample-herd facts as one short spoken reply, two sentences max. "
        + "Never add facts, names, or numbers that are not in the facts."
}

/// Unified answering: deterministic retrieval FIRST (unchanged authority),
/// then optional Apple-model shaping (on-device or PCC) over those facts.
/// Every failure — model error, refusal, invalid output, ungrounded shaping —
/// lands on the deterministic reply with an honest, route-accurate label.
enum RanchFMAnswerer {
    /// Hard cap on shaped replies (spoken-length bound).
    nonisolated static let maxShapedLength = 600

    nonisolated static func answer(
        question: String,
        shaper: any RanchFMUnderstanding,
        fmUsableOverride: Bool? = nil,
        retrieval: RanchBrainRetrievalOutcome? = nil,
        now: Date = Date(),
        routeOverride: RanchModelDecision.Route? = nil
    ) async -> (RanchOSJarvisAnswer, RanchModelDecision) {
        if let retrieval {
            switch retrieval {
            case .facts(let facts):
                return await answerLive(
                    question: question,
                    facts: facts,
                    shaper: shaper,
                    fmUsableOverride: fmUsableOverride,
                    now: now,
                    routeOverride: routeOverride)
            case .fixtures(let reason):
                switch reason {
                case .noSession, .missingTenant:
                    let (reply, decision) = await answerFixtureShaped(
                        question: question,
                        shaper: shaper,
                        fmUsableOverride: fmUsableOverride,
                        routeOverride: routeOverride)
                    return (reply, RanchModelDecision(
                        route: decision.route,
                        label: RanchBrainFacts.signInSentence,
                        intent: decision.intent,
                        terms: decision.terms))
                case .sessionExpired:
                    return (RanchOSJarvis.answer(question), .deterministic(label: RanchBrainFacts.sessionExpiredSentence))
                case .retryExhausted(let reason):
                    return (RanchOSJarvis.answer(question), .deterministic(label: reason))
                case .transportFailure, .zeroHits:
                    break
                }
            }
        }
        return await answerFixtureShaped(
            question: question,
            shaper: shaper,
            fmUsableOverride: fmUsableOverride,
            routeOverride: routeOverride)
    }

    nonisolated private static func answerFixtureShaped(
        question: String,
        shaper: any RanchFMUnderstanding,
        fmUsableOverride: Bool?,
        routeOverride: RanchModelDecision.Route?
    ) async -> (RanchOSJarvisAnswer, RanchModelDecision) {
        let facts = RanchOSJarvis.answer(question)
        let route = resolvedRoute(fmUsableOverride: fmUsableOverride, routeOverride: routeOverride)
        guard route.route != .deterministicOnly else {
            return (facts, route)
        }
        let viaPCC = route.route == .applePCC
        let failedLabel = viaPCC
            ? "Apple Private Cloud Compute couldn't shape a reply; showing the keyword answer."
            : "On-device understanding failed; showing the keyword answer."
        let rejectedLabel = viaPCC
            ? "Private Cloud reply rejected (ungrounded); showing the keyword answer."
            : "On-device reply rejected (ungrounded); showing the keyword answer."
        guard let intent = await shaper.classify(question: question),
            let terms = await shaper.extractTerms(question: question)
        else {
            return (facts, .deterministic(label: failedLabel))
        }
        guard let shaped = await shaper.shape(question: question, facts: facts.text, intent: intent, terms: terms),
            !shaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (facts, .deterministic(label: failedLabel))
        }
        let capped = cap(shaped)
        guard isGrounded(capped, in: facts.text) else {
            return (facts, .deterministic(label: rejectedLabel))
        }
        let reply = RanchOSJarvisAnswer(text: capped, provenance: facts.provenance)
        let decision = RanchModelDecision(
            route: route.route,
            label: viaPCC
                ? "Reply shaped with Apple Private Cloud Compute from sample-herd facts."
                : "Reply shaped on-device from sample-herd facts.",
            intent: intent,
            terms: terms.terms)
        return (reply, decision)
    }

    /// Live hits never fall through to the sample-herd keyword answer.
    /// Private Cloud Compute stays fixture-only: this path does not call the shaper on that route.
    nonisolated private static func answerLive(
        question: String,
        facts: [RanchBrainFact],
        shaper: any RanchFMUnderstanding,
        fmUsableOverride: Bool?,
        now: Date,
        routeOverride: RanchModelDecision.Route?
    ) async -> (RanchOSJarvisAnswer, RanchModelDecision) {
        let factText = RanchBrainFacts.joinedText(facts)
        let provenance = RanchBrainFacts.joinedProvenance(facts, now: now)
        let live = RanchOSJarvisAnswer(text: factText, provenance: provenance)
        let route = resolvedRoute(fmUsableOverride: fmUsableOverride, routeOverride: routeOverride)
        if route.route == .applePCC {
            return (live, .deterministic(label: RanchBrainFacts.unavailable("Private Cloud Compute stays fixture-only")))
        }
        if route.route == .deterministicOnly {
            return (live, .deterministic(label: RanchBrainFacts.unavailable(ModelRouter.fallbackLabel())))
        }
        let rejectedLabel = "On-device reply rejected (ungrounded); showing the keyword answer."
        guard let intent = await shaper.classify(question: question),
            let terms = await shaper.extractTerms(question: question)
        else {
            return (live, .deterministic(label: RanchBrainFacts.unavailable("shaping failed")))
        }
        guard let shaped = await shapeOnDevice(
            route: route.route, question: question, facts: factText, intent: intent, terms: terms, shaper: shaper),
            !shaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (live, .deterministic(label: RanchBrainFacts.unavailable("shaping failed")))
        }
        let capped = cap(shaped)
        guard isGrounded(capped, in: factText) else {
            return (live, .deterministic(label: rejectedLabel))
        }
        let reply = RanchOSJarvisAnswer(text: capped, provenance: provenance)
        let decision = RanchModelDecision(
            route: .onDeviceUnderstanding,
            label: "Reply shaped on-device from RanchBrain facts.",
            intent: intent,
            terms: terms.terms)
        return (reply, decision)
    }

    nonisolated private static func shapeOnDevice(
        route: RanchModelDecision.Route,
        question: String,
        facts: String,
        intent: RanchJarvisIntentKind,
        terms: RanchFindTerms,
        shaper: any RanchFMUnderstanding
    ) async -> String? {
        precondition(route != .applePCC, "PCC must not receive live RanchBrain facts")
        return await shaper.shape(question: question, facts: facts, intent: intent, terms: terms)
    }

    nonisolated private static func resolvedRoute(
        fmUsableOverride: Bool?,
        routeOverride: RanchModelDecision.Route?
    ) -> RanchModelDecision {
        if let routeOverride {
            return RanchModelDecision(route: routeOverride, label: "", intent: nil, terms: [])
        }
        return ModelRouter.decide(fmUsableOverride: fmUsableOverride)
    }

    /// Truncates to `limit` characters at a word boundary. Pure; unit-tested.
    nonisolated static func cap(_ text: String, limit: Int = maxShapedLength) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit - 1)
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    /// Grounding check: every content word in the shaped reply must appear in
    /// the retrieved facts or the fixed glue-word list. Short words pass unless
    /// the original token contains a digit or starts uppercase — those must
    /// occur in the facts (compared lowercased). Anything unrecognized fails
    /// SAFE. Pure; unit-tested.
    nonisolated static func isGrounded(_ shaped: String, in facts: String) -> Bool {
        let factWords = Set(wordTokens(facts))
        for original in originalWordTokens(shaped) {
            let word = original.lowercased()
            if word.count <= 3 {
                let needsProof = original.contains { $0.isNumber } || (original.first?.isUppercase == true)
                if needsProof && !factWords.contains(word) { return false }
                continue
            }
            if Self.glueWords.contains(word) { continue }
            if !factWords.contains(word) { return false }
        }
        return true
    }

    nonisolated private static func originalWordTokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    nonisolated private static func wordTokens(_ text: String) -> [String] {
        originalWordTokens(text).map { $0.lowercased() }
    }

    /// Generic connectors a shaped reply may use that the terse fixture texts
    /// may not contain. Deliberately narrow: misses fail safe to fallback.
    nonisolated private static let glueWords: Set<String> = [
        "about", "after", "again", "also", "because", "before", "being", "between", "both",
        "could", "does", "doing", "down", "during", "each", "from", "have", "having", "here",
        "into", "just", "know", "like", "look", "made", "make", "many", "more", "most", "much",
        "only", "other", "over", "said", "same", "sample", "should", "some", "such", "tell",
        "than", "that", "their", "them", "then", "there", "these", "they", "thing", "this",
        "those", "through", "under", "very", "were", "what", "when", "where", "which", "while",
        "with", "would", "your",
    ]
}
