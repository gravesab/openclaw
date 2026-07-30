import XCTest
@testable import PropertyManagerApp

final class CalendarSyncServiceTests: XCTestCase {
    func testMarkerSeparatesDevelopmentAndProduction() {
        let taskID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

        XCTAssertEqual(
            CalendarSyncService.marker(taskId: taskID, env: .dev),
            "propertymanager://task/12345678-1234-1234-1234-1234567890AB?env=dev"
        )
        XCTAssertEqual(
            CalendarSyncService.marker(taskId: taskID, env: .prod),
            "propertymanager://task/12345678-1234-1234-1234-1234567890AB?env=prod"
        )
    }

    func testEnvironmentMatchingDoesNotCrossDelete() {
        let taskID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let developmentNotes = "Operator note\n\(CalendarSyncService.marker(taskId: taskID, env: .dev))"

        XCTAssertTrue(CalendarSyncService.hasPMMarker(developmentNotes, env: .dev))
        XCTAssertFalse(CalendarSyncService.hasPMMarker(developmentNotes, env: .prod))
        XCTAssertTrue(CalendarSyncService.hasAnyPMMarker(developmentNotes))
        XCTAssertFalse(CalendarSyncService.hasAnyPMMarker("ordinary calendar event"))
        XCTAssertFalse(CalendarSyncService.hasAnyPMMarker(nil))
    }

    func testCalendarTitleResolutionIsExactButWhitespaceTolerant() {
        XCTAssertEqual(
            CalendarAppleScriptPush.resolveOpenClawTitle(
                from: ["Home", "OpenClaw DEV", "Work"],
                env: .dev
            ),
            "OpenClaw DEV"
        )
        XCTAssertEqual(
            CalendarAppleScriptPush.resolveOpenClawTitle(
                from: ["Home", " OpenClaw ", "Work"],
                env: .prod
            ),
            " OpenClaw "
        )
        XCTAssertNil(
            CalendarAppleScriptPush.resolveOpenClawTitle(
                from: ["Home", "OpenClaw", "Work"],
                env: .dev
            )
        )
    }

    func testEnvironmentUsesSeparateCalendarTitles() {
        XCTAssertEqual(CalendarSyncService.calendarTitle(for: .dev), "OpenClaw DEV")
        XCTAssertEqual(CalendarSyncService.calendarTitle(for: .prod), "OpenClaw")
    }
}
