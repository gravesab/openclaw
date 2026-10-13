import SwiftUI
import XCTest
@testable import PropertyManager

final class SafetyTitleTests: XCTestCase {
    func testEverySafetyInATitleIsRedAndBold() {
        let title = TaskTitle.highlightingSafety("Seat belt safety and Safety Precautions")
        let highlighted = title.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized && $0.foregroundColor == .red }
            .map { String(title[$0.range].characters) }
        XCTAssertEqual(highlighted, ["safety", "Safety"])
        XCTAssertEqual(String(title.characters), "Seat belt safety and Safety Precautions")
        XCTAssertTrue(TaskTitle.highlightingSafety("Replace drive belt").runs.allSatisfy { $0.foregroundColor == nil })
    }
}

final class DictationJoinTests: XCTestCase {
    func testDictationAddsToWhatIsAlreadyTyped() {
        XCTAssertEqual(DictationButton.joined("", "Replace the belt"), "Replace the belt")
        XCTAssertEqual(DictationButton.joined("Checked oil. ", "Replace the belt"), "Checked oil. Replace the belt")
        XCTAssertEqual(DictationButton.joined("Checked oil", ""), "Checked oil")
    }
}

final class TaskBypassTests: XCTestCase {
    private let chicago: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func task(_ extra: [String: Any] = [:]) throws -> MaintenanceTask {
        var json: [String: Any] = [
            "id": "4a9f1f5e-3d6b-4b5e-9a51-0d7f8c2a1b10",
            "area": "Equipment",
            "item": "Change engine oil",
            "category_name": "Equipment",
            "priority": "Normal",
            "frequency": "Monthly",
            "next_due": "2026-10-01T17:00:00Z",
        ]
        json.merge(extra) { _, new in new }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MaintenanceTask.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testOneTimeMeterTriggerCannotBeSkipped() throws {
        XCTAssertTrue(TaskBypassPolicy.canSkip(try task()))
        XCTAssertTrue(TaskBypassPolicy.canSkip(try task(["schedule_kind": "meter", "meter_interval_value": "250"])))
        XCTAssertFalse(TaskBypassPolicy.canSkip(try task(["schedule_kind": "meter", "next_due_meter_value": "250"])))
        XCTAssertFalse(TaskBypassPolicy.offersMeterTarget(try task()))
        XCTAssertTrue(TaskBypassPolicy.offersMeterTarget(try task(["schedule_kind": "both"])))
    }

    func testMeterTargetMustBeAboveCurrentReading() throws {
        let meterTask = try task([
            "schedule_kind": "meter", "next_due_meter_value": "500", "remaining_meter": "40",
        ])
        let current = TaskBypassPolicy.currentMeter(meterTask)
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

    func testHeldMeterTaskShowsHoldInsteadOfOverdue() throws {
        let held = try task([
            "schedule_kind": "meter", "next_due_meter_value": "500", "overdue_meter": false,
            "deferred": true, "deferred_until": "2026-10-20",
        ])
        XCTAssertEqual(held.deferredUntil, "2026-10-20")
        XCTAssertTrue(held.runHoursBadge?.hasPrefix("Held until") == true)
    }

    @MainActor
    func testRescheduledTaskStaysListedWithItsNewDateUntilRefresh() throws {
        let store = PropertyStore()
        store.filter = .toDo
        store.searchText = ""
        store.originFilter = .all
        store.selectedCategory = "All"
        store.selectedTaskAssetId = nil
        store.tasks = [try task(["next_due": "2026-10-01T17:00:00Z"])]
        XCTAssertEqual(store.filteredTasks.count, 1)

        let rescheduled = try task(["next_due": "2099-10-23T17:00:00+00:00"])
        store.showBypassed(rescheduled, keepListed: true)

        XCTAssertEqual(store.filteredTasks.map(\.nextDue), [rescheduled.nextDue])
        store.searchText = "pump"
        XCTAssertTrue(store.filteredTasks.isEmpty)
        store.searchText = ""
        store.clearRecentlyBypassed()
        XCTAssertTrue(store.filteredTasks.isEmpty)
    }

    func testListsStopAtTheTwoWeekSchedulingWindow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func due(inDays days: Int, _ extra: [String: Any] = [:]) throws -> MaintenanceTask {
            let date = Calendar.current.date(byAdding: .day, value: days, to: now)!
            var fields = extra
            fields["next_due"] = ISO8601DateFormatter().string(from: date)
            return try task(fields)
        }
        XCTAssertTrue(try due(inDays: 14).isInSchedulingWindow(now: now))
        XCTAssertTrue(try due(inDays: -90).isInSchedulingWindow(now: now))
        XCTAssertFalse(try due(inDays: 15).isInSchedulingWindow(now: now))
        XCTAssertFalse(try due(inDays: 0, ["schedule_kind": "meter"]).isInSchedulingWindow(now: now))
        XCTAssertTrue(try due(inDays: 60, ["schedule_kind": "meter", "due_meter": true]).isInSchedulingWindow(now: now))
    }

    @MainActor
    func testSkippedTaskLeavesToDoAndKeepsTheBypassedMark() throws {
        let store = PropertyStore()
        store.filter = .toDo
        store.searchText = ""
        store.originFilter = .all
        store.selectedCategory = "All"
        store.selectedTaskAssetId = nil
        store.tasks = [try task(["next_due": "2026-10-01T17:00:00Z"])]

        let skipped = try task([
            "next_due": "2099-11-01T17:00:00+00:00",
            "last_bypass_action": "skip", "last_bypassed_at": "2026-10-13T14:54:17+00:00",
        ])
        store.showBypassed(skipped, keepListed: false)

        XCTAssertTrue(store.filteredTasks.isEmpty)
        XCTAssertEqual(store.tasks.first?.lastBypassAction, "skip")
        XCTAssertNotNil(store.tasks.first?.lastBypassedAt)
        XCTAssertNil(try task([:]).lastBypassedAt)
    }

    func testScheduleEventsDecodeServerTimestamps() throws {
        let json = """
        {"id": "9b2d7c1e-5f3a-4e8b-a1c2-3d4e5f607182", "task_id": "4a9f1f5e-3d6b-4b5e-9a51-0d7f8c2a1b10",
         "action": "skip", "previous_next_due": "2026-10-01T17:00:00+00:00",
         "new_next_due": "2026-11-01T17:00:00+00:00", "previous_next_due_meter_value": null,
         "new_next_due_meter_value": null, "previous_deferred_until": null, "new_deferred_until": null,
         "note": "Parts on order", "created_at": "2026-10-04T16:50:12.123456+00:00"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(TaskScheduleEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.title, "Skipped")
        XCTAssertEqual(event.note, "Parts on order")
        XCTAssertTrue(event.summary.hasPrefix("due "))
    }
}
