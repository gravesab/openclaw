import XCTest
@testable import PropertyManagerApp

final class TaskCompletionPolicyTests: XCTestCase {
    private func asset(_ json: String) throws -> MacRanchAsset {
        try JSONDecoder().decode(MacRanchAsset.self, from: Data(json.utf8))
    }

    private var meteredAsset: MacRanchAsset {
        get throws {
            try asset("""
            {"id":"6d504692-7be4-4891-b5c5-0ffd2ecd8c40","name":"Tractor",
             "meter":{"meter_type":"runtime_hours","current_value":"412.5","unit":"hrs","activated":true},
             "meter_activated_at":"2026-09-01T12:00:00Z"}
            """)
        }
    }

    func testCalendarTaskWithoutAssetNeedsNoReading() {
        let requirement = TaskCompletionPolicy.requirement(scheduleKind: "calendar", hasLinkedAsset: false, asset: nil)
        XCTAssertEqual(requirement, .none)
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(requirement: requirement, confirmedCurrent: false, enteredValue: ""))
    }

    func testMeterTaskWithoutAssetCannotComplete() {
        let requirement = TaskCompletionPolicy.requirement(scheduleKind: "meter", hasLinkedAsset: false, asset: nil)
        guard case .unavailable = requirement else { return XCTFail("expected unavailable") }
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(requirement: requirement, confirmedCurrent: true, enteredValue: "5"))
    }

    func testActiveMeterRequiresConfirmationOrReading() throws {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "calendar",
            hasLinkedAsset: true,
            asset: try meteredAsset
        )
        XCTAssertEqual(requirement, .confirmationRequired(currentValue: 412.5, unit: "hrs"))
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(requirement: requirement, confirmedCurrent: false, enteredValue: ""))
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(requirement: requirement, confirmedCurrent: true, enteredValue: ""))
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(requirement: requirement, confirmedCurrent: false, enteredValue: "420,5"))
    }

    func testZeroConfirmsCurrentReadingAndValueIsSent() throws {
        let requirement = TaskCompletionMeterRequirement.confirmationRequired(currentValue: 412.5, unit: "hrs")

        let zero = TaskCompletionPolicy.meterSubmission(requirement: requirement, confirmedCurrent: false, enteredValue: "0")
        XCTAssertNil(zero.value)
        XCTAssertTrue(zero.confirmCurrent)

        let entered = TaskCompletionPolicy.meterSubmission(requirement: requirement, confirmedCurrent: false, enteredValue: "420.5")
        XCTAssertEqual(entered.value, 420.5)
        XCTAssertFalse(entered.confirmCurrent)
    }

    func testProposedMeterMustBeActivatedFirst() throws {
        let proposed = try asset("""
        {"id":"6d504692-7be4-4891-b5c5-0ffd2ecd8c41","name":"Chipper",
         "proposed_meter":{"meter_type":"runtime_hours","unit":"hrs"}}
        """)
        let requirement = TaskCompletionPolicy.requirement(scheduleKind: "calendar", hasLinkedAsset: true, asset: proposed)
        XCTAssertEqual(requirement, .activationRequired(meterType: "runtime_hours", unit: "hrs"))
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(requirement: requirement, confirmedCurrent: true, enteredValue: "1"))
    }

    func testInitialNoteSkipsGeneratedCompletionText() {
        XCTAssertEqual(TaskCompletionPolicy.initialNote(resultNotes: "Completed on 2026-09-01."), "")
        XCTAssertEqual(TaskCompletionPolicy.initialNote(resultNotes: " Replaced filter. "), "Replaced filter.")
    }
}
