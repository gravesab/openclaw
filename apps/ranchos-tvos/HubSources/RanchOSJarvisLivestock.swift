import Foundation

/// Jarvis livestock read seam. Tests inject a fake. Production passes nil
/// until Gate 4. This protocol does not open a URL, a database, or a credential.
protocol RanchOSJarvisLivestockReading: Sendable {
    func readHerd() async throws -> RanchOSJarvisHerdFacts
    func readAnimal(displayName: String) async throws -> RanchOSJarvisAnimalFacts
}

struct RanchOSJarvisHerdFacts: Equatable, Sendable {
    var ranchName: String
    var herdCount: Int
    var cards: [RanchOSLivestockSummary]
}

struct RanchOSJarvisAnimalFacts: Equatable, Sendable {
    var displayName: String
    var speciesCode: String
    var productionTypeCode: String
    var breedCode: String?
    var lifecycleStatus: String
    var identifierKind: String?
    var identifierValue: String?
    var factFreshness: RanchOSLivestockFactFreshness
}

enum RanchOSJarvisLivestockReadError: Error, Equatable, Sendable {
    case unauthorized
    case missing
    case foreignID
    case crossTenant
    case transport
    case sessionExpired
}

enum RanchOSJarvisClassification: Equatable, Sendable {
    case unsupported
    case herdSummary
    case unresolvedAnimal(String)
    case ranchBrain
}

/// Deterministic question class. No model call. First match wins.
enum RanchOSJarvisClassifier {
    nonisolated static func classify(_ question: String) -> RanchOSJarvisClassification {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if trimmed.isEmpty || lowered.contains("weather") {
            return .unsupported
        }
        if lowered.contains("herd") || lowered.contains("livestock") || lowered.contains("cattle")
            || lowered.contains("animals") || lowered.contains("how many")
        {
            return .herdSummary
        }
        if lowered.hasPrefix("who is ") {
            return .unresolvedAnimal(normalizedCandidate(String(trimmed.dropFirst("who is ".count))))
        }
        let token = normalizedCandidate(trimmed)
        if !token.isEmpty, token.split(whereSeparator: \.isWhitespace).count == 1 {
            return .unresolvedAnimal(token)
        }
        return .ranchBrain
    }

    /// Trims whitespace, then drops trailing punctuation only.
    nonisolated static func normalizedCandidate(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, last.isPunctuation {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RanchOSJarvisLivestockFormatter {
    nonisolated static let herdUnavailableText = "The live herd summary is not available."
    nonisolated static let animalUnavailableText = "That animal is not in the authorized herd."
    nonisolated static let unavailableCaption = "Livestock · not available"

    nonisolated static func herdUnavailable() -> RanchOSJarvisAnswer {
        RanchOSJarvisAnswer(text: herdUnavailableText, provenance: unavailableCaption)
    }

    nonisolated static func animalUnavailable() -> RanchOSJarvisAnswer {
        RanchOSJarvisAnswer(text: animalUnavailableText, provenance: unavailableCaption)
    }

    nonisolated static func herdAnswer(_ facts: RanchOSJarvisHerdFacts) -> RanchOSJarvisAnswer {
        let body = "The \(facts.ranchName) herd has \(facts.herdCount) animals. "
            + facts.cards.map { "\($0.title): \($0.detail)." }.joined(separator: " ")
        let status = facts.cards.first { $0.id == "fact-freshness" }?.status ?? .current
        return RanchOSJarvisAnswer(
            text: body + freshnessSuffix(status),
            provenance: "Livestock · live · \(facts.ranchName) · \(status.rawValue)")
    }

    nonisolated static func animalAnswer(_ facts: RanchOSJarvisAnimalFacts) -> RanchOSJarvisAnswer {
        let breed = spokenBreed(facts.breedCode)
        let identifier = spokenIdentifier(kind: facts.identifierKind, value: facts.identifierValue)
        let body = "\(facts.displayName) is a \(spokenCode(facts.speciesCode)) "
            + "(\(spokenCode(facts.productionTypeCode)), \(breed)). "
            + "Status: \(spokenCode(facts.lifecycleStatus)). \(identifier)"
        let status = animalStatus(facts.factFreshness)
        return RanchOSJarvisAnswer(
            text: body + freshnessSuffix(status),
            provenance: "Livestock · live · \(facts.displayName) · \(status.rawValue)")
    }

    nonisolated static func spokenCode(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: " ")
    }

    nonisolated private static func spokenBreed(_ breedCode: String?) -> String {
        guard let breedCode, !breedCode.isEmpty else { return "no listed breed" }
        return spokenCode(breedCode)
    }

    nonisolated private static func spokenIdentifier(kind: String?, value: String?) -> String {
        guard let kind, let value, !kind.isEmpty, !value.isEmpty else {
            return "No identifier recorded."
        }
        return "\(spokenCode(kind)): \(value)"
    }

    nonisolated private static func animalStatus(
        _ freshness: RanchOSLivestockFactFreshness
    ) -> RanchOSLivestockSummary.Status {
        switch freshness {
        case .current:
            return .current
        case .stale:
            return .careDue
        case .incomplete, .conflicting:
            return .review
        }
    }

    nonisolated private static func freshnessSuffix(_ status: RanchOSLivestockSummary.Status) -> String {
        switch status {
        case .current:
            return ""
        case .careDue:
            return " Care due."
        case .review:
            return " Needs review."
        }
    }
}

/// Read-aloud uses the same string the screen shows.
enum RanchOSJarvisSpoken {
    nonisolated static func string(for answer: RanchOSJarvisAnswer) -> String {
        answer.text
    }
}
