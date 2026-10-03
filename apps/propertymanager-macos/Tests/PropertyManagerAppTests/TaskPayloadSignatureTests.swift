import XCTest
@testable import PropertyManagerApp

final class TaskPayloadSignatureTests: XCTestCase {
    func testPhotoOnlyChangeDoesNotRequireAnotherTaskUpsert() {
        let client = PropertyAPIClient(baseURLString: "http://127.0.0.1:5062")
        var task = MaintenanceTask(
            area: "Equipment",
            item: "Inspect hydraulic fluid",
            category: "Equipment",
            priority: .medium,
            frequency: .monthly,
            taskDescription: "Inspect the fluid level.",
            responseInstructions: "Record the result.",
            warningDays: 30,
            criticalDays: 45,
            lastDone: nil,
            nextDue: Date(timeIntervalSince1970: 0)
        )
        let before = client.taskPayloadSignature(task)

        task.photoFileNames.append("opaque-photo-id.jpg")

        XCTAssertEqual(before, client.taskPayloadSignature(task))
    }

    func testCalendarNextDueRecalculatesFromLastDoneAndFrequency() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let lastDone = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        var task = MaintenanceTask(
            area: "Equipment",
            item: "Change engine oil",
            category: "Equipment",
            priority: .medium,
            frequency: .monthly,
            taskDescription: "Change the engine oil.",
            responseInstructions: "Drain and refill.",
            warningDays: 30,
            criticalDays: 45,
            lastDone: lastDone,
            nextDue: Date(timeIntervalSince1970: 0)
        )

        task.recalculateCalendarDueIfApplicable()

        XCTAssertEqual(task.nextDue, TaskFrequency.monthly.nextDue(after: lastDone))
    }
}
