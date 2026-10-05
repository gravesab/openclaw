import Foundation

/// One RanchBrain search line plus the source file it came from.
struct RanchBrainFact: Equatable, Sendable {
    var text: String
    var sourceBasename: String
    var indexedAt: Date
}

/// What retrieval decided before any model call.
enum RanchBrainRetrievalOutcome: Equatable, Sendable {
    case facts([RanchBrainFact])
    case fixtures(RanchBrainFixtureReason)
}

enum RanchBrainFixtureReason: Equatable, Sendable {
    case noSession
    case missingTenant
    case transportFailure
    case zeroHits
    case retryExhausted(String)
    case sessionExpired
}

/// Opaque `rbs_` session from POST /v1/session. JSON keys are the landed
/// P3.1 names: token, expires_at, tenant_id.
struct RanchBrainSession: Equatable, Sendable {
    var token: String
    var expiresAt: Date
    var tenantID: String
}

protocol RanchBrainSessionProviding: Sendable {
    func currentSession() -> RanchBrainSession?
}

/// Memory-only session. Never logged. Purged on 401, logout, tenant switch, or expiry.
final class RanchBrainSessionHolder: RanchBrainSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var session: RanchBrainSession?
    private let now: @Sendable () -> Date

    init(now: @Sendable @escaping () -> Date = { Date() }) {
        self.now = now
    }

    func currentSession() -> RanchBrainSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return nil }
        if session.expiresAt <= now() {
            self.session = nil
            return nil
        }
        return session
    }

    func store(_ session: RanchBrainSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func purge() {
        lock.lock()
        session = nil
        lock.unlock()
    }
}

struct RanchBrainKnowledgeHit: Equatable, Sendable {
    var text: String
    var source: String
    var indexedAt: Date
}

protocol RanchBrainKnowledgeSearching: Sendable {
    func searchKnowledge(question: String) async throws -> [RanchBrainKnowledgeHit]
}

enum RanchBrainRetrievalError: Error, Equatable {
    case sessionExpired
    case transport
    case retryExhausted(String)
}

/// Fact text and the pinned provenance string. No transport and no model types.
enum RanchBrainFacts {
    static let staleAfterDays = 30
    static let maxFactCharacters = 2000
    static let tenantDisplayName = "Ranch OS DEV"
    static let signInSentence = "Sign in to Ranch OS DEV."
    static let sessionExpiredSentence = "session expired — sign in again"
    static let rateLimitFallbackReason = "RanchBrain was rate limited. Showing the sample herd."
    static let unavailableFallbackReason = "RanchBrain was unavailable. Showing the sample herd."

    static func unavailable(_ reason: String) -> String {
        "on-device understanding unavailable: \(reason)"
    }

    static func joinedText(_ facts: [RanchBrainFact]) -> String {
        let joined = facts.map(\.text).joined(separator: " ")
        guard joined.count > maxFactCharacters else { return joined }
        return String(joined.prefix(maxFactCharacters))
    }

    static func joinedProvenance(_ facts: [RanchBrainFact], now: Date) -> String {
        facts.map { provenance(sourceBasename: $0.sourceBasename, indexedAt: $0.indexedAt, now: now) }
            .joined(separator: " | ")
    }

    static func provenance(sourceBasename: String, indexedAt: Date, now: Date) -> String {
        var label = "RanchBrain · \(sourceBasename) · indexed \(ageLabel(indexedAt: indexedAt, now: now))"
        if dayCount(from: indexedAt, to: now) >= staleAfterDays {
            label += " · verify"
        }
        return label
    }

    static func ageLabel(indexedAt: Date, now: Date) -> String {
        let days = dayCount(from: indexedAt, to: now)
        if days <= 0 { return "today" }
        return "\(days)d ago"
    }

    static func dayCount(from indexedAt: Date, to now: Date) -> Int {
        let start = utcCalendar.startOfDay(for: indexedAt)
        let end = utcCalendar.startOfDay(for: now)
        return utcCalendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func utcDate(year: Int, month: Int, day: Int) -> Date {
        let parts = DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: year, month: month, day: day)
        return utcCalendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}

struct RanchBrainRetriever: Sendable {
    var sessionProvider: any RanchBrainSessionProviding
    var search: any RanchBrainKnowledgeSearching
    var now: @Sendable () -> Date

    func fetch(question: String) async -> RanchBrainRetrievalOutcome {
        guard let session = sessionProvider.currentSession() else {
            return .fixtures(.noSession)
        }
        if session.tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .fixtures(.missingTenant)
        }
        do {
            let hits = try await search.searchKnowledge(question: question)
            if hits.isEmpty { return .fixtures(.zeroHits) }
            let facts = hits.map {
                RanchBrainFact(text: $0.text, sourceBasename: $0.source, indexedAt: $0.indexedAt)
            }
            return .facts(facts)
        } catch let error as RanchBrainRetrievalError {
            switch error {
            case .sessionExpired:
                return .fixtures(.sessionExpired)
            case .transport:
                return .fixtures(.transportFailure)
            case .retryExhausted(let reason):
                return .fixtures(.retryExhausted(reason))
            }
        } catch {
            return .fixtures(.transportFailure)
        }
    }

    /// DEV read service on the SSH-Dev Tailscale address. No session is stored
    /// here, so questions stay on the sample herd until a session is issued.
    static func devService() -> RanchBrainRetriever {
        let holder = RanchBrainSessionHolder()
        let client = RanchBrainClient(
            baseURL: URL(string: "http://100.85.188.74:5063")!,
            tenantID: "",
            token: { holder.currentSession()?.token },
            sessionHolder: holder)
        return RanchBrainRetriever(sessionProvider: holder, search: client, now: { Date() })
    }
}
