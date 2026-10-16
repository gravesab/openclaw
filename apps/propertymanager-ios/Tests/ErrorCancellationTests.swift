import XCTest
@testable import PropertyManager

final class ErrorCancellationTests: XCTestCase {
    func testCancelledLoadsAreNotFailures() {
        XCTAssertTrue(CancellationError().isCancellation)
        XCTAssertTrue(URLError(.cancelled).isCancellation)
    }

    func testRealFailuresStillReport() {
        XCTAssertFalse(URLError(.timedOut).isCancellation)
        XCTAssertFalse(URLError(.notConnectedToInternet).isCancellation)
        XCTAssertFalse(PropertyAPIError.serverMessage("Task not found").isCancellation)
    }
}
