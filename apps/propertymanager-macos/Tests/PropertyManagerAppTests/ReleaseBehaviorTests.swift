import XCTest
@testable import PropertyManagerApp

final class TaskListFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func task(dueInDays days: Int, warningDays: Int = 30, criticalDays: Int = 45) -> MaintenanceTask {
        MaintenanceTask(
            area: "House",
            item: "Replace HVAC filter",
            category: "House",
            priority: .medium,
            frequency: .monthly,
            taskDescription: "",
            responseInstructions: "",
            warningDays: warningDays,
            criticalDays: criticalDays,
            lastDone: nil,
            nextDue: Calendar.current.date(byAdding: .day, value: days, to: now)!
        )
    }

    func testToDoShowsDueTodayAndPastDueOnly() {
        XCTAssertTrue(task(dueInDays: 0).matches(.toDo, now: now))
        XCTAssertTrue(task(dueInDays: -3).matches(.toDo, now: now))
        XCTAssertFalse(task(dueInDays: 2).matches(.toDo, now: now))
    }

    func testMeterDueTaskIsToDoRegardlessOfDate() {
        var meterDue = task(dueInDays: 60)
        meterDue.dueMeter = true
        XCTAssertTrue(meterDue.matches(.toDo, now: now))
    }

    func testDueUsesWarningWindowAndOverdueNeedsPastDue() {
        XCTAssertTrue(task(dueInDays: 10, warningDays: 14).matches(.due, now: now))
        XCTAssertFalse(task(dueInDays: 10, warningDays: 14).matches(.overdue, now: now))
        XCTAssertFalse(task(dueInDays: 40, warningDays: 14).matches(.due, now: now))
        XCTAssertTrue(task(dueInDays: -2).matches(.overdue, now: now))
        XCTAssertTrue(task(dueInDays: 400).matches(.all, now: now))
    }

    func testSearchCoversPartsVendorsAndNotes() {
        var withPart = task(dueInDays: 0)
        withPart.parts = [PartRequirement(name: "Filter", partNumber: "FPR-10", vendor: "Filtrete")]
        withPart.notes = "Upstairs return"
        let fields = TaskSearch.taskFields(for: withPart, assets: [])
        XCTAssertTrue(TaskSearch.matches(fields: fields, words: ["filtrete", "fpr-10", "upstairs"]))
    }
}

final class AssetAndLibraryTests: XCTestCase {
    func testPlacedInServiceDateDecodesAsCivilDate() throws {
        let json = """
        {"id":"6d504692-7be4-4891-b5c5-0ffd2ecd8c42","name":"Mower","placed_in_service_date":"2024-04-15"}
        """
        let asset = try JSONDecoder().decode(MacRanchAsset.self, from: Data(json.utf8))
        XCTAssertEqual(asset.placedInServiceDate, "2024-04-15")
        let date = try XCTUnwrap(MacCivilDate.date(from: "2024-04-15"))
        XCTAssertEqual(MacCivilDate.string(from: date), "2024-04-15")
    }

    func testMissingOrInvalidPlacedInServiceDateIsNil() throws {
        let missing = try JSONDecoder().decode(
            MacRanchAsset.self,
            from: Data(#"{"id":"6d504692-7be4-4891-b5c5-0ffd2ecd8c43","name":"Gate"}"#.utf8)
        )
        XCTAssertNil(missing.placedInServiceDate)
        XCTAssertNil(MacCivilDate.normalized("not a date"))
        XCTAssertEqual(MacCivilDate.normalized("2024-04-15T00:00:00Z"), "2024-04-15")
    }

    func testAssetSearchFindsAssetThroughItsTask() throws {
        let chipper = try JSONDecoder().decode(
            MacRanchAsset.self,
            from: Data(#"{"id":"6d504692-7be4-4891-b5c5-0ffd2ecd8c44","name":"DR Chipper"}"#.utf8)
        )
        var knife = MaintenanceTask(
            area: "DR Chipper",
            item: "Check knife to wear plate gap",
            category: "Equipment",
            priority: .medium,
            frequency: .monthly,
            taskDescription: "",
            responseInstructions: "",
            warningDays: 30,
            criticalDays: 45,
            lastDone: nil,
            nextDue: Date()
        )
        knife.assetId = chipper.id

        let matches = TaskSearch.assetMatches(assets: [chipper], tasks: [knife], words: ["chipper", "knife"])
        XCTAssertEqual(matches.map(\.asset.id), [chipper.id])
        XCTAssertEqual(matches.first?.matchingTaskTitles.count, 1)
        XCTAssertTrue(TaskSearch.assetMatches(assets: [chipper], tasks: [knife], words: ["pool"]).isEmpty)
    }

    func testLibraryPDFSuggestionsComeFirst() {
        let pdfs = [
            DashboardLibraryPDF(relativePath: "Assets/Pool/Pump_Manual.pdf", title: "Pump"),
            DashboardLibraryPDF(relativePath: "Assets/DR_Chipper_Manual.pdf", title: "Chipper"),
        ]
        XCTAssertTrue(pdfs[1].isSuggested(forAssetName: "DR Chipper"))
        XCTAssertFalse(pdfs[0].isSuggested(forAssetName: "DR Chipper"))
        XCTAssertEqual(pdfs[0].folder, "Pool")
        XCTAssertEqual(
            DashboardLibraryPDF.ordered(pdfs, forAssetName: "DR Chipper").map(\.relativePath).first,
            "Assets/DR_Chipper_Manual.pdf"
        )
    }

    func testHTTPStatusMapsToNotFoundAndUnauthorized() throws {
        let client = PropertyAPIClient(baseURLString: "http://127.0.0.1:5062")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:5062/tasks/x"))
        func response(_ code: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        let body = Data(#"{"error":"Task not found"}"#.utf8)
        XCTAssertThrowsError(try client.validate(response(404), data: body)) { error in
            guard case PropertyAPIError.notFound(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "Task not found")
        }
        XCTAssertThrowsError(try client.validate(response(401), data: nil)) { error in
            guard case PropertyAPIError.unauthorized = error else { return XCTFail("\(error)") }
        }
    }
}

final class AppleManualExtractionTests: XCTestCase {
    private func extracted(item: String, frequency: String, steps: String = "1. Do it.") -> ExtractedManualTask {
        ExtractedManualTask(
            area: "Engine",
            item: item,
            category: "Equipment",
            frequency: frequency,
            estimatedMinutes: 2,
            taskDescription: "",
            responseInstructions: steps,
            suppliesNeeded: "",
            partNumbers: [" ", "AM125424"],
            tools: [.init(name: "Wrench", size: "10 mm")],
            notes: ""
        )
    }

    func testDraftsDropTasksWithoutIntervalOrSteps() {
        let drafts = AppleManualExtractor.drafts(
            from: [
                extracted(item: "Change engine oil", frequency: "Every 50 operating hours"),
                extracted(item: "Shut off the engine", frequency: ""),
                extracted(item: "Check tire pressure", frequency: "Weekly", steps: " "),
            ],
            manufacturer: "Deere",
            equipment: "1025R",
            manualName: "1025R.pdf"
        )
        XCTAssertEqual(drafts.map(\.item), ["Change engine oil"])
        let draft = drafts[0]
        XCTAssertEqual(draft.frequency, .monthly)
        XCTAssertEqual(draft.estimatedMinutes, 5)
        XCTAssertEqual(draft.partNumbers, ["AM125424"])
        XCTAssertEqual(draft.toolsRequired.first?.size, "10 mm")
        XCTAssertTrue(draft.notes.contains("Manufacturer interval: Every 50 operating hours."))
    }

    func testIntervalWordingMapsToCalendarSchedule() {
        XCTAssertEqual(ManualInterval.from("Before each use")?.frequency, .daily)
        XCTAssertEqual(ManualInterval.from("Every 3 months")?.frequency, .quarterly)
        XCTAssertEqual(ManualInterval.from("End of season")?.frequency, .yearly)
        XCTAssertNil(ManualInterval.from("  "))
    }

    func testFuzzyIdentityMatchesWordingVariantsButNotDifferentActions() {
        let inspect = ManualMaintenanceIdentity.make(area: "Chipper", item: "Inspect the knife for nicks and wear")
        let check = ManualMaintenanceIdentity.make(area: "Chipper", item: "Check knife for nicks, wear")
        let replace = ManualMaintenanceIdentity.make(area: "Chipper", item: "Replace knife")
        XCTAssertTrue(ManualMaintenanceIdentity.isSameAction(inspect, check))
        XCTAssertFalse(ManualMaintenanceIdentity.isSameAction(check, replace))
    }

    func testReviewMarksFuzzyDuplicateOfStoredTask() {
        let assetID = UUID()
        var stored = MaintenanceTask(
            area: "Chipper",
            item: "Check knife for nicks, wear",
            category: "Equipment",
            priority: .medium,
            frequency: .monthly,
            taskDescription: "",
            responseInstructions: "",
            warningDays: 30,
            criticalDays: 45,
            lastDone: nil,
            nextDue: Date()
        )
        stored.assetId = assetID
        let draft = AppleManualExtractor.drafts(
            from: [extracted(item: "Inspect the knife for nicks and wear", frequency: "Every 8 hours")],
            manufacturer: "",
            equipment: "Chipper",
            manualName: "chipper.pdf"
        )
        let selection = ManualImportReviewSelection.applyingDefaultSelection(
            drafts: draft,
            existingTasks: [stored],
            assetID: assetID
        )
        XCTAssertEqual(selection.map(\.selected), [false])
    }
}
