import Foundation
#if !os(macOS)
import BackgroundTasks
#endif

// RanchBrain P3 Swift client (read-only). No views in this file.
// Transport: HTTPS required. DEV over Tailscale: add an ATS exception for
// domain "ts.net" with NSIncludesSubdomains (covers *.ts.net) until
// `tailscale serve` HTTPS lands. No production exception.

/// Memory summary from GET /v1/memory/list. Never carries a body or path.
struct RanchBrainMemorySummary: Codable, Equatable, Sendable {
    let id: String
    let module: String
    let category: String
    let title: String
    let memoryType: String
    let tags: [String]
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, module, category, title, tags
        case memoryType = "memory_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RanchBrainReference: Codable, Equatable, Sendable {
    let type: String
    let value: String
    let title: String
}

/// Full memory from GET /v1/memory/fetch/{id}.
struct RanchBrainMemoryDetail: Codable, Equatable, Sendable {
    let id: String
    let module: String
    let category: String
    let title: String
    let memoryType: String
    let tags: [String]
    let createdAt: String
    let updatedAt: String
    let body: String
    let references: [RanchBrainReference]
    let sourceType: String
    let tenantID: String

    private enum CodingKeys: String, CodingKey {
        case id, module, category, title, tags, body, references
        case memoryType = "memory_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceType = "source_type"
        case tenantID = "tenant_id"
    }
}

struct RanchBrainSearchHit: Codable, Equatable, Sendable {
    let source: String
    let line: Int
    let text: String
    let modifiedAt: String
    let indexedAt: String

    private enum CodingKeys: String, CodingKey {
        case source, line, text
        case modifiedAt = "modified_at"
        case indexedAt = "indexed_at"
    }
}

struct RanchBrainListResult: Codable, Equatable, Sendable {
    let tenantID: String
    let count: Int
    let memories: [RanchBrainMemorySummary]

    private enum CodingKeys: String, CodingKey {
        case count, memories
        case tenantID = "tenant_id"
    }
}

struct RanchBrainSearchResult: Codable, Equatable, Sendable {
    let tenantID: String
    let profile: String
    let total: Int
    let hits: [RanchBrainSearchHit]

    private enum CodingKeys: String, CodingKey {
        case profile, total, hits
        case tenantID = "tenant_id"
    }
}

struct RanchBrainRateLimit: Equatable, Sendable {
    let limit: Int
    let remaining: Int
    let resetSeconds: Int
}

enum RanchBrainError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case ambiguousID
    case invalidRequest(code: String, message: String)
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(retryAfterSeconds: Int)
    case server(status: Int, code: String)
    case transport(String)
    case decoding(String)
    case missingToken
}

protocol RanchBrainHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct RanchBrainURLSessionTransport: RanchBrainHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

protocol RanchBrainSleeper: Sendable {
    func sleep(seconds: Int) async throws
}

struct RanchBrainContinuousSleeper: RanchBrainSleeper {
    func sleep(seconds: Int) async throws {
        let seconds = UInt64(max(seconds, 0))
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
}

/// P3 client. One instance per tenant: caches are tenant-scoped by
/// construction and purged on logout, tenant switch, 401, or 403.
/// Bodies are memory-only unless `offlineBodiesEnabled` is true (explicit
/// user opt-in); nothing is written to disk by this client.
actor RanchBrainClient: RanchBrainKnowledgeSearching {
    private let baseURL: URL
    private let tenantID: String
    private let token: @Sendable () -> String?
    private let offlineBodiesEnabled: Bool
    private let transport: any RanchBrainHTTPTransport
    private let sleeper: any RanchBrainSleeper
    let sessionHolder: RanchBrainSessionHolder
    private var responseCache: [String: Data] = [:]
    private var bodyCache: [String: RanchBrainMemoryDetail] = [:]
    private(set) var lastRateLimit: RanchBrainRateLimit?

    init(
        baseURL: URL,
        tenantID: String,
        token: @Sendable @escaping () -> String?,
        offlineBodiesEnabled: Bool = false,
        session: URLSession = .shared,
        transport: (any RanchBrainHTTPTransport)? = nil,
        sleeper: any RanchBrainSleeper = RanchBrainContinuousSleeper(),
        sessionHolder: RanchBrainSessionHolder = RanchBrainSessionHolder()
    ) {
        self.baseURL = baseURL
        self.tenantID = tenantID
        self.token = token
        self.offlineBodiesEnabled = offlineBodiesEnabled
        self.transport = transport ?? RanchBrainURLSessionTransport(session: session)
        self.sleeper = sleeper
        self.sessionHolder = sessionHolder
    }

    /// Clears every cached response, retained body, and the memory-only session.
    /// Call on logout or tenant switch; also runs automatically on 401.
    func purge() {
        responseCache.removeAll()
        bodyCache.removeAll()
        sessionHolder.purge()
    }

    func listMemories(
        module: String? = nil, memoryType: String? = nil,
        category: String? = nil, tag: String? = nil, limit: Int? = nil
    ) async throws -> RanchBrainListResult {
        var items: [URLQueryItem] = []
        if let module { items.append(URLQueryItem(name: "module", value: module)) }
        if let memoryType { items.append(URLQueryItem(name: "memory_type", value: memoryType)) }
        if let category { items.append(URLQueryItem(name: "category", value: category)) }
        if let tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(path: "/v1/memory/list", query: items)
    }

    func fetchMemory(id: String) async throws -> RanchBrainMemoryDetail {
        if let cached = bodyCache[id] { return cached }
        let detail: RanchBrainMemoryDetail = try await get(
            path: "/v1/memory/fetch/\(id)", query: [])
        if offlineBodiesEnabled { bodyCache[id] = detail }
        return detail
    }

    func search(profile: String, question: String, limit: Int? = nil) async throws -> RanchBrainSearchResult {
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let path = "/v1/search/\(Self.percentEncodePathSegment(profile))/\(Self.percentEncodePathSegment(question))"
        return try await get(path: path, query: items)
    }

    /// Knowledge search for Jarvis. Percent-encodes the question segment,
    /// requests limit=5, and honors Retry-After exactly once on 429 or 503.
    func searchKnowledge(question: String) async throws -> [RanchBrainKnowledgeHit] {
        do {
            return try await knowledgeHits(question)
        } catch let error as RanchBrainError {
            switch error {
            case .rateLimited(let seconds):
                try await sleeper.sleep(seconds: seconds)
                return try await knowledgeHitsAfterOneRetry(question, exhausted: RanchBrainFacts.rateLimitFallbackReason)
            case .unavailable(let seconds):
                try await sleeper.sleep(seconds: seconds)
                return try await knowledgeHitsAfterOneRetry(question, exhausted: RanchBrainFacts.unavailableFallbackReason)
            case .unauthorized:
                throw RanchBrainRetrievalError.sessionExpired
            default:
                throw RanchBrainRetrievalError.transport
            }
        }
    }

    /// Exchanges a fresh Google token for an `rbs_` session. The Google token
    /// is not stored; later data calls use the session bearer only.
    func issueSession(googleToken: String, tenantID: String) async throws -> RanchBrainSession {
        let data = try await post(path: "/v1/session", bearer: googleToken, tenantID: tenantID)
        let decoded = try JSONDecoder().decode(RanchBrainSessionPayload.self, from: data)
        guard let expiresAt = Self.parseServerDate(decoded.expiresAt) else {
            throw RanchBrainError.decoding("expires_at is not a date")
        }
        let session = RanchBrainSession(token: decoded.token, expiresAt: expiresAt, tenantID: decoded.tenantID)
        sessionHolder.store(session)
        return session
    }

    // -- pipeline ---------------------------------------------------

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        guard let token = token() else { throw RanchBrainError.missingToken }
        guard let url = Self.url(baseURL: baseURL, path: path, query: query) else {
            throw RanchBrainError.invalidRequest(code: "bad_url", message: "Could not build request URL.")
        }
        if let cached = responseCache[url.absoluteString] {
            return try decode(cached)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let headerTenant = sessionHolder.currentSession()?.tenantID ?? tenantID
        request.setValue(headerTenant, forHTTPHeaderField: "X-Ranch-Tenant")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw RanchBrainError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RanchBrainError.transport("Non-HTTP response.")
        }
        lastRateLimit = Self.rateLimit(from: http)
        switch http.statusCode {
        case 200:
            responseCache[url.absoluteString] = data
            return try decode(data)
        case 401:
            purge()
            throw RanchBrainError.unauthorized
        case 403:
            purge()
            throw RanchBrainError.forbidden
        case 404:
            throw RanchBrainError.notFound
        case 409:
            throw RanchBrainError.ambiguousID
        case 429:
            throw RanchBrainError.rateLimited(retryAfterSeconds: Self.retryAfter(from: http))
        case 503:
            throw RanchBrainError.unavailable(retryAfterSeconds: Self.retryAfter(from: http))
        case 400...499:
            let envelope = (try? JSONDecoder().decode(RanchBrainErrorEnvelope.self, from: data))
            throw RanchBrainError.invalidRequest(
                code: envelope?.code ?? "bad_request",
                message: envelope?.message ?? "Request rejected.")
        default:
            let envelope = (try? JSONDecoder().decode(RanchBrainErrorEnvelope.self, from: data))
            throw RanchBrainError.server(status: http.statusCode, code: envelope?.code ?? "server")
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RanchBrainError.decoding(error.localizedDescription)
        }
    }

    private nonisolated static func rateLimit(from response: HTTPURLResponse) -> RanchBrainRateLimit? {
        guard let limit = headerInt(response, "X-RateLimit-Limit"),
            let remaining = headerInt(response, "X-RateLimit-Remaining"),
            let reset = headerInt(response, "X-RateLimit-Reset")
        else { return nil }
        return RanchBrainRateLimit(limit: limit, remaining: remaining, resetSeconds: reset)
    }

    private nonisolated static func retryAfter(from response: HTTPURLResponse) -> Int {
        headerInt(response, "Retry-After") ?? 5
    }

    private nonisolated static func headerInt(_ response: HTTPURLResponse, _ name: String) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: name) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    private func knowledgeHits(_ question: String) async throws -> [RanchBrainKnowledgeHit] {
        let result = try await search(profile: "knowledge", question: question, limit: 5)
        var hits: [RanchBrainKnowledgeHit] = []
        for hit in result.hits {
            guard let indexedAt = Self.parseServerDate(hit.indexedAt) else {
                throw RanchBrainError.decoding("indexed_at is not a date")
            }
            hits.append(RanchBrainKnowledgeHit(text: hit.text, source: hit.source, indexedAt: indexedAt))
        }
        return hits
    }

    private func knowledgeHitsAfterOneRetry(_ question: String, exhausted: String) async throws -> [RanchBrainKnowledgeHit] {
        do {
            return try await knowledgeHits(question)
        } catch let error as RanchBrainError {
            switch error {
            case .rateLimited, .unavailable:
                throw RanchBrainRetrievalError.retryExhausted(exhausted)
            case .unauthorized:
                throw RanchBrainRetrievalError.sessionExpired
            default:
                throw RanchBrainRetrievalError.transport
            }
        }
    }

    private func post(path: String, bearer: String, tenantID: String) async throws -> Data {
        guard let url = Self.url(baseURL: baseURL, path: path, query: []) else {
            throw RanchBrainError.invalidRequest(code: "bad_url", message: "Could not build request URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(tenantID, forHTTPHeaderField: "X-Ranch-Tenant")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw RanchBrainError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RanchBrainError.transport("Non-HTTP response.")
        }
        switch http.statusCode {
        case 200:
            return data
        case 401:
            purge()
            throw RanchBrainError.unauthorized
        default:
            throw RanchBrainError.server(status: http.statusCode, code: "session")
        }
    }

    nonisolated static func url(baseURL: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.percentEncodedPath
        let prefix = basePath == "/" ? "" : basePath
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.percentEncodedPath = prefix + suffix
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    nonisolated static func percentEncodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated static func parseServerDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private struct RanchBrainSessionPayload: Decodable {
    let token: String
    let expiresAt: String
    let tenantID: String

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case tenantID = "tenant_id"
    }
}

private struct RanchBrainErrorEnvelope: Decodable {
    let code: String
    let message: String
}

/// Background task IDs for RanchBrain memory sync. Registration and
/// submission exist on iOS/tvOS only (BGTask is API-unavailable on macOS).
enum RanchBrainBackgroundTasks {
    /// Lightweight list/search cache refresh (BGAppRefreshTask, ~30s budget).
    static let refreshID = "ai.openclaw.ranchos.memory-refresh"
    /// Off-peak index warmup hint (BGProcessingTask, requires power+network).
    static let warmupID = "ai.openclaw.ranchos.memory-warmup"

#if !os(macOS)
    /// Register both tasks. Call once at app launch (iOS/tvOS only).
    static func register(
        refresh: sending @Sendable @escaping () async -> Void,
        warmup: sending @Sendable @escaping () async -> Void
    ) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            Task { [box = RanchBrainTaskBox(work: refresh, task: task)] in
                await box.work()
                box.task.setTaskCompleted(success: true)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: warmupID, using: nil) { task in
            Task { [box = RanchBrainTaskBox(work: warmup, task: task)] in
                await box.work()
                box.task.setTaskCompleted(success: true)
            }
        }
    }

    /// Holds one background work item across the Task boundary. Sound:
    /// `work` is @Sendable, and `task` only ever receives setTaskCompleted,
    /// which Apple's BackgroundTasks samples call from arbitrary queues.
    private final class RanchBrainTaskBox: @unchecked Sendable {
        let work: @Sendable () async -> Void
        let task: BGTask

        init(work: @Sendable @escaping () async -> Void, task: BGTask) {
            self.work = work
            self.task = task
        }
    }

    /// Schedule a cache refresh (reads only, no uploads).
    static func submitRefresh(earliestIn seconds: TimeInterval = 15 * 60) throws {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try BGTaskScheduler.shared.submit(request)
    }

    /// Schedule an index warmup (deferrable off-peak work).
    static func submitWarmup(earliestIn seconds: TimeInterval = 60 * 60) throws {
        let request = BGProcessingTaskRequest(identifier: warmupID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try BGTaskScheduler.shared.submit(request)
    }
#endif
}
