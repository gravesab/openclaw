import XCTest

final class RanchOSLivestockStoreTests: XCTestCase {
    private let liveDashboard = RanchOSLivestockDashboard(
        ranchName: "Authorized read",
        herdCount: 3,
        summaries: [
            RanchOSLivestockSummary(
                id: "authorized",
                title: "Authorized herd",
                detail: "Read only",
                status: .current),
        ])

    private let laterDashboard = RanchOSLivestockDashboard(
        ranchName: "Later authorized read",
        herdCount: 7,
        summaries: [
            RanchOSLivestockSummary(
                id: "later",
                title: "Later herd",
                detail: "Read only",
                status: .review),
        ])

    @MainActor
    func testNoProviderStaysOnTheLabeledFixture() async {
        let store = RanchOSLivestockStore()

        XCTAssertEqual(store.presentation, .fixture(.developmentFixture))
        XCTAssertFalse(store.presentation.isLive)
        XCTAssertEqual(store.presentation.banner, RanchOSLivestockConnection.pendingLabel)

        await store.load()

        XCTAssertEqual(store.presentation, .fixture(.developmentFixture))
        XCTAssertFalse(store.presentation.isLive)
        XCTAssertFalse(store.canRetry)
    }

    @MainActor
    func testInFlightProviderLoadUsesLoadingNotFixtureOrLive() async {
        let provider = ControllableLivestockReadProvider()
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))
        XCTAssertEqual(store.presentation, .loading)

        let load = Task { await store.load() }
        let request = await provider.nextRequest()
        addTeardownBlock { await request.release() }

        XCTAssertEqual(store.presentation, .loading)
        XCTAssertFalse(store.presentation.isLive)

        await request.complete(.success(liveDashboard))
        await load.value

        XCTAssertEqual(store.presentation, .available(liveDashboard))
        XCTAssertTrue(store.presentation.isLive)
        let captured = await request.capturedOutcome()
        XCTAssertEqual(captured, .success(liveDashboard))
    }

    @MainActor
    func testProviderSuccessIsAvailableAndNotTheFixture() async {
        let provider = ImmediateLivestockReadProvider(outcome: .success(liveDashboard))
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))

        await store.load()

        XCTAssertEqual(store.presentation, .available(liveDashboard))
        XCTAssertTrue(store.presentation.isLive)
        XCTAssertEqual(store.presentation.banner, RanchOSLivestockConnection.liveReadOnlyLabel)
        XCTAssertNotEqual(store.presentation, .fixture(.developmentFixture))
    }

    @MainActor
    func testProviderFailureClearsLiveDataAndRetryCanSucceed() async {
        let provider = ImmediateLivestockReadProvider(outcome: .success(liveDashboard))
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))
        await store.load()
        XCTAssertEqual(store.presentation, .available(liveDashboard))

        await provider.setOutcome(.failure)
        await store.load()

        XCTAssertEqual(
            store.presentation,
            .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage))
        XCTAssertFalse(store.presentation.isLive)
        XCTAssertTrue(store.canRetry)

        await provider.setOutcome(.success(laterDashboard))
        await store.load()

        XCTAssertEqual(store.presentation, .available(laterDashboard))
        XCTAssertTrue(store.presentation.isLive)
    }

    @MainActor
    func testCurrentCancellationEndsLoadingAndRetrySucceeds() async {
        let provider = ControllableLivestockReadProvider()
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))
        let load = Task { await store.load() }
        let request = await provider.nextRequest()
        addTeardownBlock { await request.release() }

        load.cancel()
        await load.value

        XCTAssertEqual(store.presentation, .retryable)
        XCTAssertTrue(store.canRetry)
        XCTAssertFalse(store.presentation.isLive)
        XCTAssertEqual(store.presentation.banner, "")
        XCTAssertNotEqual(store.presentation, .available(liveDashboard))
        XCTAssertNotEqual(
            store.presentation,
            .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage))
        await request.release()

        let retry = Task { await store.load() }
        let retryRequest = await provider.nextRequest()
        addTeardownBlock { await retryRequest.release() }
        await retryRequest.complete(.success(laterDashboard))
        await retry.value

        XCTAssertEqual(store.presentation, .available(laterDashboard))
        XCTAssertTrue(store.presentation.isLive)
        let capturedRetry = await retryRequest.capturedOutcome()
        XCTAssertEqual(capturedRetry, .success(laterDashboard))
    }

    @MainActor
    func testLaterRequestCompletingFirstCannotBeOverwrittenByEarlierRequest() async {
        let provider = ControllableLivestockReadProvider()
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))

        let first = Task { await store.load() }
        let requestA = await provider.nextRequest()
        addTeardownBlock { await requestA.release() }
        await requestA.setIgnoresCancellation(true)

        let second = Task { await store.load() }
        let requestB = await provider.nextRequest()
        addTeardownBlock { await requestB.release() }

        await requestB.complete(.success(laterDashboard))
        await second.value

        XCTAssertEqual(store.presentation, .available(laterDashboard))
        let capturedB = await requestB.capturedOutcome()
        XCTAssertEqual(capturedB, .success(laterDashboard))

        await requestA.complete(.success(liveDashboard))
        await first.value

        XCTAssertEqual(store.presentation, .available(laterDashboard))
        XCTAssertNotEqual(store.presentation, .available(liveDashboard))
        let capturedA = await requestA.capturedOutcome()
        XCTAssertEqual(capturedA, .success(liveDashboard))
    }

    @MainActor
    func testInvalidationRejectsALateResult() async {
        let provider = ControllableLivestockReadProvider()
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))
        let load = Task { await store.load() }
        let request = await provider.nextRequest()
        addTeardownBlock { await request.release() }
        await request.setIgnoresCancellation(true)

        store.invalidate()

        XCTAssertEqual(store.presentation, .unavailable(RanchOSLivestockStore.invalidatedMessage))
        XCTAssertFalse(store.presentation.isLive)

        await request.complete(.success(liveDashboard))
        await load.value

        XCTAssertEqual(store.presentation, .unavailable(RanchOSLivestockStore.invalidatedMessage))
        XCTAssertNotEqual(store.presentation, .available(liveDashboard))
        let capturedLate = await request.capturedOutcome()
        XCTAssertEqual(capturedLate, .success(liveDashboard))
    }

    @MainActor
    func testCancellationIsSafeWhenProviderIgnoresCancellation() async {
        let provider = ControllableLivestockReadProvider()
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))
        let load = Task { await store.load() }
        let request = await provider.nextRequest()
        addTeardownBlock { await request.release() }
        await request.setIgnoresCancellation(true)
        await request.waitUntilAwaitingCompletion()

        load.cancel()
        await load.value

        XCTAssertEqual(store.presentation, .retryable)
        XCTAssertTrue(store.canRetry)
        XCTAssertFalse(store.presentation.isLive)
        XCTAssertNotEqual(store.presentation, .available(liveDashboard))
        XCTAssertNotEqual(
            store.presentation,
            .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage))

        await request.complete(.success(liveDashboard))
        let capturedIgnored = await request.capturedOutcome()
        XCTAssertEqual(capturedIgnored, .success(liveDashboard))
        XCTAssertEqual(store.presentation, .retryable)
    }

    @MainActor
    func testCallerCancellationShowsRetryableBeforeIgnoredRequestCompletesAndLateResultCannotOverwriteRetry() async {
        let provider = ControllableLivestockReadProvider()
        let store = RanchOSLivestockStore(connection: RanchOSLivestockConnection(authorizedProvider: provider))

        let loadA = Task { await store.load() }
        let requestA = await provider.nextRequest()
        await requestA.setIgnoresCancellation(true)
        await requestA.waitUntilAwaitingCompletion()
        addTeardownBlock { await requestA.release() }

        loadA.cancel()
        await loadA.value

        XCTAssertEqual(store.presentation, .retryable)
        XCTAssertNotEqual(store.presentation, .loading)
        XCTAssertNotEqual(
            store.presentation,
            .unavailable(RanchOSLivestockConnection.authorizedReadUnavailableMessage))
        XCTAssertNotEqual(store.presentation, .available(liveDashboard))
        XCTAssertNotEqual(store.presentation, .fixture(.developmentFixture))
        XCTAssertFalse(store.presentation.isLive)
        XCTAssertEqual(store.presentation.banner, "")
        XCTAssertTrue(store.canRetry)
        let awaitingA = await requestA.isAwaitingCompletion()
        XCTAssertTrue(awaitingA)
        let capturedBeforeRetry = await requestA.capturedOutcome()
        XCTAssertNil(capturedBeforeRetry)

        let loadB = Task { await store.load() }
        let requestB = await provider.nextRequest()
        addTeardownBlock { await requestB.release() }
        await requestB.complete(.success(laterDashboard))
        await loadB.value

        XCTAssertEqual(store.presentation, .available(laterDashboard))
        XCTAssertTrue(store.presentation.isLive)
        let capturedB = await requestB.capturedOutcome()
        XCTAssertEqual(capturedB, .success(laterDashboard))

        await requestA.complete(.success(liveDashboard))
        let capturedA = await requestA.capturedOutcome()
        XCTAssertEqual(capturedA, .success(liveDashboard))
        XCTAssertEqual(store.presentation, .available(laterDashboard))
        XCTAssertNotEqual(store.presentation, .available(liveDashboard))
        XCTAssertNotEqual(store.presentation, .retryable)
    }

    @MainActor
    func testInvalidateWithoutProviderRestoresTheFixture() async {
        let store = RanchOSLivestockStore()
        await store.load()
        store.invalidate()

        XCTAssertEqual(store.presentation, .fixture(.developmentFixture))
        XCTAssertFalse(store.presentation.isLive)
    }
}

private struct LivestockStoreTestFailure: Error, Equatable {}

private enum LivestockReadOutcome: Equatable, Sendable {
    case success(RanchOSLivestockDashboard)
    case failure
}

private actor ImmediateLivestockReadProvider: RanchOSLivestockAuthorizedReadProvider {
    private var outcome: LivestockReadOutcome

    init(outcome: LivestockReadOutcome) {
        self.outcome = outcome
    }

    func setOutcome(_ outcome: LivestockReadOutcome) {
        self.outcome = outcome
    }

    func readDashboard() async throws -> RanchOSLivestockDashboard {
        switch outcome {
        case .success(let dashboard): return dashboard
        case .failure: throw LivestockStoreTestFailure()
        }
    }
}

private actor ControllableLivestockReadProvider: RanchOSLivestockAuthorizedReadProvider {
    private var ready: [LivestockReadRequest] = []
    private var waiters: [CheckedContinuation<LivestockReadRequest, Never>] = []
    private var nextID = 1

    func nextRequest() async -> LivestockReadRequest {
        if !ready.isEmpty {
            return ready.removeFirst()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func readDashboard() async throws -> RanchOSLivestockDashboard {
        let request = LivestockReadRequest(id: nextID)
        nextID += 1
        if waiters.isEmpty {
            ready.append(request)
        } else {
            waiters.removeFirst().resume(returning: request)
        }
        return try await request.value()
    }
}

private actor LivestockReadRequest {
    let id: Int
    private var ignoresCancellation = false
    private var continuation: CheckedContinuation<RanchOSLivestockDashboard, Error>?
    private var captured: LivestockReadOutcome?
    private var released = false
    private var awaitingWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: Int) {
        self.id = id
    }

    func capturedOutcome() -> LivestockReadOutcome? { captured }

    func isAwaitingCompletion() -> Bool {
        continuation != nil && captured == nil && !released
    }

    func waitUntilAwaitingCompletion() async {
        if isAwaitingCompletion() { return }
        if captured != nil || released { return }
        await withCheckedContinuation { awaitingWaiters.append($0) }
    }

    func setIgnoresCancellation(_ ignores: Bool) {
        ignoresCancellation = ignores
    }

    func complete(_ outcome: LivestockReadOutcome) {
        captured = outcome
        resumeAwaitingWaiters()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result(for: outcome))
    }

    func release() {
        released = true
        resumeAwaitingWaiters()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    func value() async throws -> RanchOSLivestockDashboard {
        if released { throw CancellationError() }
        if let captured {
            try Task.checkCancellation()
            return try result(for: captured).get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RanchOSLivestockDashboard, Error>) in
                if released {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let captured {
                    continuation.resume(with: result(for: captured))
                    return
                }
                self.continuation = continuation
                self.resumeAwaitingWaiters()
            }
        } onCancel: {
            Task { await cancelIfNeeded() }
        }
    }

    private func cancelIfNeeded() {
        guard !ignoresCancellation else { return }
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func resumeAwaitingWaiters() {
        let waiters = awaitingWaiters
        awaitingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func result(for outcome: LivestockReadOutcome) -> Result<RanchOSLivestockDashboard, Error> {
        switch outcome {
        case .success(let dashboard): .success(dashboard)
        case .failure: .failure(LivestockStoreTestFailure())
        }
    }
}
