import Foundation

/// Authorized Livestock DEV reads only. Hub does not ship a provider, URL, or credentials.
protocol RanchOSLivestockAuthorizedReadProvider: Sendable {
    func readDashboard() async throws -> RanchOSLivestockDashboard
}

/// Read-only Livestock connection boundary. Write verbs are intentionally absent.
enum RanchOSLivestockConnectionOperation: String, CaseIterable, Sendable {
    case readDashboard
}

/// HTTP methods this boundary may ever declare. POST, PATCH, PUT, and DELETE are not included.
enum RanchOSLivestockConnectionRequestMethod: String, CaseIterable, Sendable {
    case get = "GET"

    var isWrite: Bool { false }
}

enum RanchOSLivestockSession: Equatable, Sendable {
    case fixture(RanchOSLivestockDashboard)
    case unavailable(String)
    case live(RanchOSLivestockDashboard)
    case cancelled

    var isLive: Bool {
        switch self {
        case .live: true
        case .fixture, .unavailable, .cancelled: false
        }
    }

    var banner: String {
        switch self {
        case .fixture: RanchOSLivestockConnection.pendingLabel
        case .unavailable(let message): message
        case .live: RanchOSLivestockConnection.liveReadOnlyLabel
        case .cancelled: ""
        }
    }
}

/// Read-only Livestock DEV connection. No endpoint, credentials, or mutation surface.
struct RanchOSLivestockConnection: Sendable {
    static let pendingLabel = "DEV fixture — live Livestock connection pending."
    static let liveReadOnlyLabel = "Live DEV data · read only. RanchOS cannot change Livestock records."
    static let authorizedReadUnavailableMessage = "The authorized Livestock read API is not available."
    static let writeRequestMethods: [String] = []

    private let authorizedProvider: (any RanchOSLivestockAuthorizedReadProvider)?

    init(authorizedProvider: (any RanchOSLivestockAuthorizedReadProvider)? = nil) {
        self.authorizedProvider = authorizedProvider
    }

    static let pending = RanchOSLivestockConnection()

    var hasAuthorizedProvider: Bool { authorizedProvider != nil }

    /// Sync placeholder only. Live presentation is owned by the resolved session or store.
    var presentationSession: RanchOSLivestockSession {
        guard authorizedProvider == nil else {
            return .unavailable(Self.authorizedReadUnavailableMessage)
        }
        return .fixture(.developmentFixture)
    }

    func resolve() async -> RanchOSLivestockSession {
        guard let authorizedProvider else {
            return .fixture(.developmentFixture)
        }
        do {
            try Task.checkCancellation()
            let dashboard = try await authorizedProvider.readDashboard()
            try Task.checkCancellation()
            return .live(dashboard)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Task.isCancelled {
                return .cancelled
            }
            return .unavailable(Self.authorizedReadUnavailableMessage)
        }
    }
}
