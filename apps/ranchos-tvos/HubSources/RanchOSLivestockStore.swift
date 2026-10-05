import Foundation
import Observation

enum RanchOSLivestockPresentation: Equatable, Sendable {
    case fixture(RanchOSLivestockDashboard)
    case loading
    case available(RanchOSLivestockDashboard)
    case unavailable(String)
    case retryable

    var isLive: Bool {
        switch self {
        case .available: true
        case .fixture, .loading, .unavailable, .retryable: false
        }
    }

    var banner: String {
        switch self {
        case .fixture: RanchOSLivestockConnection.pendingLabel
        case .loading, .retryable: ""
        case .available: RanchOSLivestockConnection.liveReadOnlyLabel
        case .unavailable(let message): message
        }
    }
}

/// Observable Livestock presentation. Live data exists only after a resolved provider read.
@MainActor
@Observable
final class RanchOSLivestockStore {
    static let invalidatedMessage = "Livestock data was cleared."

    private let connection: RanchOSLivestockConnection
    private(set) var presentation: RanchOSLivestockPresentation
    private var generation = 0
    private var inFlight: Task<RanchOSLivestockSession, Never>?

    init(connection: RanchOSLivestockConnection = .pending) {
        self.connection = connection
        if connection.hasAuthorizedProvider {
            presentation = .loading
        } else {
            presentation = .fixture(.developmentFixture)
        }
    }

    var canRetry: Bool {
        switch presentation {
        case .unavailable, .retryable: true
        case .fixture, .loading, .available: false
        }
    }

    func load() async {
        inFlight?.cancel()
        generation += 1
        let current = generation

        guard connection.hasAuthorizedProvider else {
            applyIfCurrent(current, .fixture(.developmentFixture))
            return
        }

        applyIfCurrent(current, .loading)

        let work = Task { await connection.resolve() }
        inFlight = work

        let session: RanchOSLivestockSession
        do {
            session = try await waitForWorkOrCallerCancellation(work)
        } catch {
            applyIfCurrent(current, .retryable)
            Task { @MainActor in
                _ = await work.value
                self.clearCompletedInFlight(for: current)
            }
            return
        }

        clearCompletedInFlight(for: current)
        guard current == generation else { return }
        if Task.isCancelled || work.isCancelled || session == .cancelled {
            presentation = .retryable
            return
        }

        switch session {
        case .fixture(let dashboard):
            presentation = .fixture(dashboard)
        case .unavailable(let message):
            presentation = .unavailable(message)
        case .live(let dashboard):
            presentation = .available(dashboard)
        case .cancelled:
            presentation = .retryable
        }
    }

    private func waitForWorkOrCallerCancellation(
        _ work: Task<RanchOSLivestockSession, Never>
    ) async throws -> RanchOSLivestockSession {
        let state = LivestockLoadWaitState()
        return try await withTaskCancellationHandler {
            Task {
                let session = await work.value
                await state.finish(.success(session))
            }
            return try await state.wait()
        } onCancel: {
            work.cancel()
            Task {
                await state.finish(.failure(CancellationError()))
            }
        }
    }

    /// Future session/tenant changes can clear live data without inventing authentication.
    func invalidate() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        if connection.hasAuthorizedProvider {
            presentation = .unavailable(Self.invalidatedMessage)
        } else {
            presentation = .fixture(.developmentFixture)
        }
    }

    private func applyIfCurrent(_ current: Int, _ next: RanchOSLivestockPresentation) {
        guard current == generation else { return }
        presentation = next
    }

    private func clearCompletedInFlight(for current: Int) {
        guard generation == current else { return }
        inFlight = nil
    }
}

/// First finish wins so a late cancelled-request result cannot resume load().
private actor LivestockLoadWaitState {
    private var continuation: CheckedContinuation<RanchOSLivestockSession, Error>?
    private var pending: Result<RanchOSLivestockSession, Error>?

    func finish(_ result: Result<RanchOSLivestockSession, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
            return
        }
        if pending == nil {
            pending = result
        }
    }

    func wait() async throws -> RanchOSLivestockSession {
        if let pending {
            self.pending = nil
            return try pending.get()
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
