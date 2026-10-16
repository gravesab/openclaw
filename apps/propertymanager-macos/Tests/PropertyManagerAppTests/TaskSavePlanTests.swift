import XCTest
@testable import PropertyManagerApp

final class TaskSavePlanTests: XCTestCase {
    private func task(lastDone: Date? = Date(timeIntervalSince1970: 1_790_000_000)) -> MaintenanceTask {
        MaintenanceTask(
            area: "Tractor",
            item: "Change engine oil",
            category: "Equipment",
            priority: .medium,
            frequency: .monthly,
            taskDescription: "Change the oil.",
            responseInstructions: "1. Drain. 2. Refill.",
            completionHistory: ["2026-09-01 — Completed on 2026-09-01."],
            warningDays: 30,
            criticalDays: 45,
            lastDone: lastDone,
            nextDue: Date(timeIntervalSince1970: 1_792_000_000),
            parts: [PartRequirement(name: "Oil filter", partNumber: "AM125424", quantity: 2, vendor: "Deere", notes: "OEM")]
        )
    }

    func testUnchangedTaskSendsNothing() {
        let baseline = task()
        XCTAssertTrue(TaskSavePlan(baseline: baseline, edited: baseline).isEmpty)
    }

    func testPatchableEditsUsePatchOnly() {
        let baseline = task()
        var edited = baseline
        edited.notes = "Use 15W-40"
        edited.assetId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        edited.meterIntervalValue = 50

        let plan = TaskSavePlan(baseline: baseline, edited: edited)

        XCTAssertEqual(plan.patchFields["notes"] as? String, "Use 15W-40")
        XCTAssertEqual(plan.patchFields["asset_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(plan.patchFields["meter_interval_value"] as? String, "50")
        XCTAssertEqual(Set(plan.patchFields.keys), ["notes", "asset_id", "meter_interval_value"])
        XCTAssertFalse(plan.partsChanged)
        XCTAssertTrue(plan.fullSaveFields.isEmpty)
    }

    func testClearingAnOptionalPatchFieldSendsNull() {
        var baseline = task()
        baseline.meterIntervalUnit = "hrs"
        var edited = baseline
        edited.meterIntervalUnit = nil

        let plan = TaskSavePlan(baseline: baseline, edited: edited)

        XCTAssertTrue(plan.patchFields["meter_interval_unit"] is NSNull)
    }

    func testPartEditIsSentAsPartsReplacementKeepingVendorAndNotes() {
        let baseline = task()
        var edited = baseline
        edited.parts[0].cost = 12.5

        let plan = TaskSavePlan(baseline: baseline, edited: edited)

        XCTAssertTrue(plan.partsChanged)
        XCTAssertTrue(plan.patchFields.isEmpty)
        let payload = PartRequirement.apiPayload(edited.parts)
        XCTAssertEqual(payload.first?["vendor"] as? String, "Deere")
        XCTAssertEqual(payload.first?["notes"] as? String, "OEM")
        XCTAssertEqual(payload.first?["quantity"] as? Double, 2)
    }

    func testFullSaveAppliesOnlyChangedFieldsOntoFreshServerCopy() {
        let baseline = task()
        var edited = baseline
        edited.priority = .high

        var fresh = baseline
        fresh.completionHistory.insert("2026-10-02 — Completed on iPhone.", at: 0)
        fresh.lastDone = Date(timeIntervalSince1970: 1_791_000_000)
        fresh.nextDue = Date(timeIntervalSince1970: 1_793_600_000)

        let plan = TaskSavePlan(baseline: baseline, edited: edited)
        let merged = plan.applyFullSaveFields(from: edited, onto: fresh)

        XCTAssertEqual(plan.fullSaveFields, [.priority])
        XCTAssertEqual(merged.priority, .high)
        XCTAssertEqual(merged.completionHistory, fresh.completionHistory)
        XCTAssertEqual(merged.lastDone, fresh.lastDone)
        XCTAssertEqual(merged.nextDue, fresh.nextDue)
    }

    func testChangingFrequencyRecalculatesNextDueFromLastDone() {
        let baseline = task()
        var edited = baseline
        edited.frequency = .yearly

        let plan = TaskSavePlan(baseline: baseline, edited: edited)
        let merged = plan.applyFullSaveFields(from: edited, onto: baseline)

        XCTAssertEqual(merged.nextDue, TaskFrequency.yearly.nextDue(after: baseline.lastDone!))
    }

    func testExplicitNextDueIsNotOverwrittenByRecalculation() {
        let baseline = task()
        var edited = baseline
        edited.frequency = .yearly
        edited.nextDue = Date(timeIntervalSince1970: 1_800_000_000)

        let merged = TaskSavePlan(baseline: baseline, edited: edited)
            .applyFullSaveFields(from: edited, onto: baseline)

        XCTAssertEqual(merged.nextDue, Date(timeIntervalSince1970: 1_800_000_000))
    }
}
