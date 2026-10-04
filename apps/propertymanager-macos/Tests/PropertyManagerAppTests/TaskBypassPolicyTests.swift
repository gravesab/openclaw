import XCTest
@testable import PropertyManagerApp

final class TaskBypassPolicyTests: XCTestCase {
    private let chicago: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func task(
        kind: TaskKind = .scheduled,
        isActive: Bool = true,
        scheduleKind: String = "calendar",
        interval: Decimal? = nil,
        trigger: Decimal? = nil,
        remaining: Decimal? = nil
    ) -> MaintenanceTask {
        MaintenanceTask(
            area: "Equipment",
            item: "Change engine oil",
            category: "Equipment",
            kind: kind,
            priority: .medium,
            frequency: .monthly,
            taskDescription: "",
            responseInstructions: "",
            warningDays: 7,
            criticalDays: 14,
            lastDone: nil,
            nextDue: Date(timeIntervalSince1970: 1_790_874_000),
            isActive: isActive,
            scheduleKind: scheduleKind,
            meterIntervalValue: interval,
            nextDueMeterValue: trigger,
            remainingMeter: remaining
        )
    }

    func testWorkRequestsAndInactiveTasksCannotBeBypassed() {
        XCTAssertTrue(TaskBypassPolicy.canBypass(task()))
        XCTAssertFalse(TaskBypassPolicy.canBypass(task(kind: .workRequest)))
        XCTAssertFalse(TaskBypassPolicy.canBypass(task(isActive: false)))
        XCTAssertFalse(TaskBypassPolicy.canSkip(task(kind: .workRequest)))
    }

    func testOneTimeMeterTriggerCannotBeSkipped() {
        XCTAssertTrue(TaskBypassPolicy.canSkip(task()))
        XCTAssertTrue(TaskBypassPolicy.canSkip(task(scheduleKind: "meter", interval: 250)))
        XCTAssertFalse(TaskBypassPolicy.canSkip(task(scheduleKind: "meter", trigger: 250)))
        XCTAssertFalse(TaskBypassPolicy.offersMeterTarget(task()))
        XCTAssertTrue(TaskBypassPolicy.offersMeterTarget(task(scheduleKind: "both")))
    }

    func testMeterTargetMustBeAboveCurrentReading() {
        let current = TaskBypassPolicy.currentMeter(task(scheduleKind: "meter", trigger: 500, remaining: 40))
        XCTAssertEqual(current, Decimal(460))
        XCTAssertNil(TaskBypassPolicy.meterTarget("460", above: current))
        XCTAssertNil(TaskBypassPolicy.meterTarget("", above: current))
        XCTAssertEqual(TaskBypassPolicy.meterTarget("520,5", above: current), Decimal(string: "520.5"))
    }

    func testReschedulePayloadSendsTheCivilDateAndTrimmedNote() throws {
        let picked = try XCTUnwrap(chicago.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30)))
        let body = try XCTUnwrap(TaskBypassPolicy.reschedulePayload(
            target: .date, date: picked, meterValue: nil, note: "  Waiting on parts ", calendar: chicago
        ))
        XCTAssertEqual(body["next_due"] as? String, "2026-10-20")
        XCTAssertEqual(body["note"] as? String, "Waiting on parts")
        XCTAssertNil(body["next_due_meter_value"])

        let meterBody = try XCTUnwrap(TaskBypassPolicy.reschedulePayload(
            target: .meter, date: picked, meterValue: Decimal(string: "520.5"), note: " ", calendar: chicago
        ))
        XCTAssertEqual(meterBody["next_due_meter_value"] as? String, "520.5")
        XCTAssertNil(meterBody["note"])
        XCTAssertNil(TaskBypassPolicy.reschedulePayload(target: .meter, date: picked, meterValue: nil, note: ""))
    }

    func testServerTaskDecodesHoldAndShowsItInsteadOfOverdue() throws {
        let json = """
        {"id": "4a9f1f5e-3d6b-4b5e-9a51-0d7f8c2a1b10", "area": "Equipment", "item": "Change engine oil",
         "category_name": "Equipment", "priority": "Medium", "frequency": "Monthly",
         "warning_days": 7, "critical_days": 14, "next_due": "2026-10-01T17:00:00+00:00",
         "schedule_kind": "meter", "next_due_meter_value": "500.000", "overdue_meter": false,
         "deferred": true, "deferred_until": "2026-10-20"}
        """
        let held = try PropertyAPIClient(baseURLString: "http://127.0.0.1:1").decodeTask(Data(json.utf8))
        XCTAssertEqual(held.deferredUntil, "2026-10-20")
        XCTAssertEqual(held.deferred, true)
        XCTAssertEqual(held.meterBadge(assets: []), "Held until 2026-10-20")
    }

    func testScheduleEventsDecodeServerTimestamps() throws {
        let json = """
        {"id": "9b2d7c1e-5f3a-4e8b-a1c2-3d4e5f607182", "task_id": "4a9f1f5e-3d6b-4b5e-9a51-0d7f8c2a1b10",
         "action": "reschedule", "previous_next_due": "2026-10-01T17:00:00+00:00",
         "new_next_due": "2026-10-01T17:00:00+00:00", "previous_next_due_meter_value": "500.000",
         "new_next_due_meter_value": "500.000", "previous_deferred_until": null,
         "new_deferred_until": "2026-10-20", "note": "Parts on order",
         "created_at": "2026-10-04T16:50:12.123456+00:00"}
        """
        let event = try JSONDecoder().decode(TaskScheduleEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.title, "Rescheduled")
        XCTAssertEqual(event.note, "Parts on order")
        XCTAssertEqual(event.summary, "held until 2026-10-20")
    }
}
