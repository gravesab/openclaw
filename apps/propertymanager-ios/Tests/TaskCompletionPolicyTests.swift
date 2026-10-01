import XCTest
@testable import PropertyManager

final class TaskCompletionPolicyTests: XCTestCase {
    func testZeroIsAValidExplicitMeterReading() {
        XCTAssertEqual(TaskCompletionPolicy.meterValue("0"), 0)
        XCTAssertEqual(TaskCompletionPolicy.meterValue(" 0.0 "), 0)
        XCTAssertNil(TaskCompletionPolicy.meterValue(""))
        XCTAssertNil(TaskCompletionPolicy.meterValue("-1"))
        XCTAssertNil(TaskCompletionPolicy.meterValue("not a reading"))
    }

    func testActiveRuntimeMeterRequiresConfirmationForCalendarTask() throws {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "calendar",
            hasLinkedAsset: true,
            asset: try asset(
                meterType: "runtime_hours",
                activatedAt: "2026-08-29T12:00:00Z"
            )
        )

        XCTAssertEqual(
            requirement,
            .confirmationRequired(currentValue: 0, unit: "hrs")
        )
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: false,
            enteredValue: ""
        ))
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: false,
            enteredValue: "0"
        ))
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: true,
            enteredValue: ""
        ))
    }

    func testZeroMeansNoChangeAndConfirmsTheCurrentReading() {
        let requirement = TaskCompletionMeterRequirement.confirmationRequired(currentValue: 412, unit: "hrs")
        func submit(_ text: String, confirmed: Bool = false) -> (Double?, Bool) {
            let result = TaskCompletionPolicy.meterSubmission(
                requirement: requirement, confirmedCurrent: confirmed, enteredValue: text
            )
            return (result.value, result.confirmCurrent)
        }

        XCTAssertTrue(submit("0") == (nil, true))
        XCTAssertTrue(submit("415.5") == (415.5, false))
        XCTAssertTrue(submit("", confirmed: true) == (nil, true))
        XCTAssertTrue(submit("") == (nil, false))
        let none = TaskCompletionPolicy.meterSubmission(requirement: .none, confirmedCurrent: false, enteredValue: "0")
        XCTAssertNil(none.value)
        XCTAssertFalse(none.confirmCurrent)
    }

    func testProposedRuntimeMeterRequiresExplicitActivation() throws {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "calendar",
            hasLinkedAsset: true,
            asset: try asset(meterType: "none", proposedType: "runtime_hours")
        )

        XCTAssertEqual(
            requirement,
            .activationRequired(meterType: "runtime_hours", unit: "hrs")
        )
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: true,
            enteredValue: "0"
        ))
    }

    func testMeterScheduledTaskWithoutAssetFailsClosed() {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "meter",
            hasLinkedAsset: false,
            asset: nil
        )

        guard case .unavailable = requirement else {
            return XCTFail("Meter-scheduled task must fail closed without an asset")
        }
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: true,
            enteredValue: "0"
        ))
    }

    private func asset(
        meterType: String,
        activatedAt: String? = nil,
        proposedType: String? = nil
    ) throws -> RanchAsset {
        var json: [String: Any] = [
            "id": UUID().uuidString,
            "external_id": "TEST-ASSET",
            "name": "Test asset",
            "meter": [
                "meter_type": meterType,
                "current_value": 0,
                "unit": meterType == "runtime_hours" ? "hrs" : "",
                "activated": meterType != "none",
            ],
        ]
        if let activatedAt {
            json["meter_activated_at"] = activatedAt
        }
        if let proposedType {
            json["proposed_meter"] = [
                "meter_type": proposedType,
                "unit": proposedType == "runtime_hours" ? "hrs" : "",
            ]
        }
        return try JSONDecoder.propertyManager.decode(
            RanchAsset.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }
}

private extension JSONDecoder {
    static var propertyManager: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class TaskToDoFilterTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-01T15:00:00Z")!
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testCompletedMonthlyTaskLeavesToDoEvenWithLongWarningWindow() throws {
        let completed = try task(nextDue: "2026-11-01T15:00:00Z", warningDays: 30)
        XCTAssertFalse(completed.isToDo(now: now, calendar: utc))
    }

    func testCompletedDailyTaskLeavesToDoUntilTomorrow() throws {
        XCTAssertFalse(try task(nextDue: "2026-10-02T15:00:00Z").isToDo(now: now, calendar: utc))
        XCTAssertFalse(try task(nextDue: "2026-10-02T00:00:00Z").isToDo(now: now, calendar: utc))
    }

    func testPastDueAndDueLaterTodayStayInToDo() throws {
        XCTAssertTrue(try task(nextDue: "2026-09-20T12:00:00Z").isToDo(now: now, calendar: utc))
        XCTAssertTrue(try task(nextDue: "2026-10-01T23:59:00Z").isToDo(now: now, calendar: utc))
    }

    func testRunHourDueTaskStaysInToDo() throws {
        XCTAssertTrue(try task(nextDue: "2027-06-01T12:00:00Z", dueMeter: true).isToDo(now: now, calendar: utc))
    }

    func testToDoIsTheDefaultFilter() {
        XCTAssertEqual(TaskFilter.allCases.first, .toDo)
    }

    private func task(nextDue: String, warningDays: Int = 7, dueMeter: Bool = false) throws -> MaintenanceTask {
        let json: [String: Any] = [
            "id": UUID().uuidString, "area": "Equipment", "item": "Adjust wear plate", "category_name": "Equipment",
            "priority": "Medium", "frequency": "Monthly", "next_due": nextDue, "warning_days": warningDays,
            "is_active": true, "due_meter": dueMeter,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MaintenanceTask.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
