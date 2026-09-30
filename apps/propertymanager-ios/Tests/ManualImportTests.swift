import XCTest
@testable import PropertyManager

final class TaskSearchTests: XCTestCase {
    func testEveryWordMustMatchAnywhereInAnyOrder() {
        let fields = ["DR Chipper", "Sharpen chipper knife", "Equipment"]

        XCTAssertTrue(TaskSearch.matches(fields: fields, words: TaskSearch.words(in: "knife")))
        XCTAssertTrue(TaskSearch.matches(fields: fields, words: TaskSearch.words(in: "  KNIFE  sharpen ")))
        XCTAssertFalse(TaskSearch.matches(fields: fields, words: TaskSearch.words(in: "knife oil")))
        XCTAssertTrue(TaskSearch.matches(fields: fields, words: TaskSearch.words(in: "   ")))
    }

    func testAssetFilterMatchesAssetOrItsTasks() throws {
        let chipper = try asset(name: "DR Chipper")
        let mower = try asset(name: "Zero Turn Mower")
        let tasks = [
            try task(item: "Check knife to wear plate gap", assetID: chipper.id),
            try task(item: "Change engine oil", assetID: chipper.id),
            try task(item: "Sharpen mower blades", assetID: mower.id),
        ]
        func search(_ query: String) -> [AssetSearchMatch] {
            TaskSearch.assetMatches(
                assets: [mower, chipper], tasks: tasks, words: TaskSearch.words(in: query),
                taskFields: { [$0.item] }, taskTitle: { $0.item }
            )
        }

        XCTAssertEqual(search("").map(\.asset.name), ["DR Chipper", "Zero Turn Mower"])
        let knife = search("knife")
        XCTAssertEqual(knife.map(\.asset.name), ["DR Chipper"])
        XCTAssertEqual(knife.first?.matchingTaskTitles, ["Check knife to wear plate gap"])
        XCTAssertEqual(search("chipper knife").first?.matchingTaskTitles, ["Check knife to wear plate gap"])
        XCTAssertEqual(search("mower").map(\.asset.name), ["Zero Turn Mower"])
        XCTAssertTrue(search("knife blades").isEmpty)
    }

    private func asset(name: String) throws -> RanchAsset {
        let json: [String: Any] = ["id": UUID().uuidString, "external_id": name.lowercased(), "name": name]
        return try JSONDecoder().decode(RanchAsset.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func task(item: String, assetID: UUID) throws -> MaintenanceTask {
        let json: [String: Any] = [
            "id": UUID().uuidString, "area": "Equipment", "item": item, "category_name": "Equipment",
            "priority": "Medium", "frequency": "Yearly", "next_due": "2026-10-01T00:00:00Z",
            "asset_id": assetID.uuidString, "is_active": true,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MaintenanceTask.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

final class ManualImportReviewSelectionTests: XCTestCase {
    private let assetID = UUID()

    func testStoredAndRepeatedActionsAreMarkedDuplicateAndUnchecked() throws {
        let tasks = try [
            storedTask(item: "Change engine oil", assetID: assetID),
            storedTask(item: "Inspect belts", assetID: UUID()),
            storedTask(item: "Clean or replace air filter", assetID: assetID, isActive: false),
        ]
        let drafts = [
            draft("DR Chipper: Change the engine oil"),
            draft("Inspect belts for wear"),
            draft("Check belts for wear and tension"),
            draft("Clean or replace air filter"),
        ]

        let notes = ManualImportReviewSelection.notes(drafts: drafts, existingTasks: tasks, assetID: assetID)
        XCTAssertEqual(notes[drafts[0].id], "Duplicate of stored task: Change engine oil")
        XCTAssertNil(notes[drafts[1].id])
        XCTAssertEqual(notes[drafts[2].id], "Duplicate of another proposal: Inspect belts for wear")
        XCTAssertNil(notes[drafts[3].id])

        let selected = ManualImportReviewSelection.applyingDefaultSelection(
            drafts: drafts,
            existingTasks: tasks,
            assetID: assetID
        ).map(\.selected)
        XCTAssertEqual(selected, [false, true, false, true])
    }

    private func draft(_ item: String) -> ManualImportDraft {
        ManualImportDraft(
            area: "DR Chipper", item: item, category: "Equipment", frequency: .yearly,
            warningDays: 365, criticalDays: 730, estimatedMinutes: 20, taskDescription: item,
            responseInstructions: "1. Do it.", suppliesNeeded: "", notes: "", manufacturer: "DR",
            sourceManualName: "DR_Chipper_Manual.pdf", partNumbers: [], referenceURLs: [], toolsRequired: []
        )
    }

    private func storedTask(item: String, assetID: UUID, isActive: Bool = true) throws -> MaintenanceTask {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "area": "DR Chipper",
            "item": item,
            "category_name": "Equipment",
            "priority": "Medium",
            "frequency": "Yearly",
            "next_due": "2026-10-01T00:00:00Z",
            "asset_id": assetID.uuidString,
            "is_active": isActive,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MaintenanceTask.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

final class AppleManualDraftMappingTests: XCTestCase {
    func testDropsTasksWithoutStepsAndCleansRepeatedHeadings() {
        let tasks = [
            extracted(area: "Engine", item: "DR Chipper: Engine: Change oil", steps: "1. Drain oil.\n2. Refill."),
            extracted(area: "", item: "Grease the bearings", steps: "   "),
        ]

        let drafts = AppleManualExtractor.drafts(
            from: tasks, manufacturer: "DR Power", equipment: "DR Chipper", manualName: "DR_Chipper_Manual.pdf"
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].item, "Change oil")
        XCTAssertEqual(drafts[0].area, "DR Chipper")
        XCTAssertEqual(drafts[0].frequency, .yearly)
        XCTAssertEqual(drafts[0].criticalDays, 730)
        XCTAssertTrue(drafts[0].notes.contains("Source manual: DR_Chipper_Manual.pdf"))
        XCTAssertEqual(drafts[0].toolsRequired, [ManualToolRequirement(name: "Wrench", size: "10 mm", notes: "")])
    }

    func testSourceBackedChecksDoNotRepeatModelProposals() {
        let model = AppleManualExtractor.drafts(
            from: [extracted(area: "Engine", item: "Change engine oil", steps: "1. Drain.")],
            manufacturer: "DR Power", equipment: "DR Chipper", manualName: "DR_Chipper_Manual.pdf"
        )

        let merged = AppleManualExtractor.merged(
            modelDrafts: model,
            manualName: "DR_Chipper_Manual.pdf",
            manualText: "Before storage, change the oil. Battery care: charge monthly.",
            manufacturer: "DR Power"
        )

        XCTAssertEqual(merged.map(\.item), ["Change engine oil", "Charge stored battery"])
    }

    func testTaskPayloadMatchesMacImportShape() throws {
        let assetID = UUID()
        let lastDone = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = AppleManualExtractor.drafts(
            from: [extracted(area: "Engine", item: "Change engine oil", steps: "1. Drain.")],
            manufacturer: "DR Power", equipment: "DR Chipper", manualName: "DR_Chipper_Manual.pdf"
        )[0]

        let payload = draft.taskPayload(assetID: assetID, lastDone: lastDone)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertEqual(payload["kind"] as? String, "Scheduled")
        XCTAssertEqual(payload["origin"] as? String, "manufacturer")
        XCTAssertEqual(payload["frequency"] as? String, "Yearly")
        XCTAssertEqual(payload["asset_id"] as? String, assetID.uuidString)
        XCTAssertEqual(payload["schedule_kind"] as? String, "calendar")
        XCTAssertEqual((payload["parts"] as? [[String: Any]])?.first?["part_number"] as? String, "OIL-1")
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(payload["next_due"] as? String, iso.string(from: lastDone.addingTimeInterval(365 * 86_400)))
    }

    func testTasksWithoutManualIntervalAreDropped() {
        let drafts = AppleManualExtractor.drafts(
            from: [
                extracted(area: "", item: "Shut down the engine", steps: "1. Turn the key off.", frequency: " "),
                extracted(area: "", item: "Lubricate flywheel bearings", steps: "1. Grease.", frequency: "Every 25 hours"),
            ],
            manufacturer: "DR Power", equipment: "DR Chipper", manualName: "DR_Chipper_Manual.pdf"
        )

        XCTAssertEqual(drafts.map(\.item), ["Lubricate flywheel bearings"])
        XCTAssertEqual(drafts[0].frequency, .monthly)
        XCTAssertTrue(drafts[0].notes.hasPrefix("Manufacturer interval: Every 25 hours."))
    }

    private func extracted(
        area: String, item: String, steps: String, frequency: String = "Yearly"
    ) -> ExtractedManualTask {
        ExtractedManualTask(
            area: area, item: item, category: "Equipment", frequency: frequency,
            estimatedMinutes: 30, taskDescription: "", responseInstructions: steps, suppliesNeeded: "",
            partNumbers: ["OIL-1", " "], tools: [.init(name: "Wrench", size: "10 mm"), .init(name: " ", size: "")],
            notes: ""
        )
    }
}

final class ManualIntervalTests: XCTestCase {
    func testMapsManualWordingToCalendarSchedule() {
        XCTAssertNil(ManualInterval.from("  "))
        XCTAssertEqual(ManualInterval.from("Before each use")?.frequency, .daily)
        XCTAssertEqual(ManualInterval.from("Every 2 weeks")?.frequency, .biweekly)
        XCTAssertEqual(ManualInterval.from("Weekly")?.frequency, .weekly)
        XCTAssertEqual(ManualInterval.from("Every 3 months")?.frequency, .quarterly)
        XCTAssertEqual(ManualInterval.from("Monthly")?.frequency, .monthly)
        XCTAssertEqual(ManualInterval.from("Before storage")?.frequency, .yearly)
        XCTAssertEqual(ManualInterval.from("Annually")?.warningDays, 365)
        XCTAssertNil(ManualInterval.from("Yearly")?.note)
    }

    func testApproximatedIntervalsKeepManufacturerWording() throws {
        let hours = try XCTUnwrap(ManualInterval.from("Every 8-10 operating hours"))
        XCTAssertEqual(hours.frequency, .monthly)
        XCTAssertEqual(hours.criticalDays, 60)
        XCTAssertTrue(hours.note?.contains("hour trigger") == true)

        let sixMonths = try XCTUnwrap(ManualInterval.from("Every 6 months"))
        XCTAssertEqual(sixMonths.frequency, .yearly)
        XCTAssertEqual(sixMonths.warningDays, 180)
        XCTAssertEqual(ManualInterval.from("As needed")?.note, "Manufacturer interval: As needed.")
    }
}

final class ManualMaintenanceIdentityTests: XCTestCase {
    private func key(_ item: String) -> String {
        ManualMaintenanceIdentity.make(area: "DR Chipper", item: item)
    }

    func testSameActionAllowsQualifiersAndSynonyms() {
        XCTAssertTrue(ManualMaintenanceIdentity.isSameAction(
            key("Inspect knife for nicks and wear"), key("Check the knife for nicks, wear, and tightness")
        ))
        XCTAssertTrue(ManualMaintenanceIdentity.isSameAction(key("Check belt tension"), key("Inspect belt tension")))
    }

    func testDifferentActionsOrPartsDoNotMatch() {
        XCTAssertFalse(ManualMaintenanceIdentity.isSameAction(key("Check knife"), key("Replace knife")))
        XCTAssertFalse(ManualMaintenanceIdentity.isSameAction(key("Check belt tension"), key("Check tire pressure")))
    }
}

final class DashboardLibraryPDFTests: XCTestCase {
    private func pdf(_ path: String) throws -> DashboardLibraryPDF {
        let json = ["relative_path": path, "title": ""]
        return try JSONDecoder().decode(DashboardLibraryPDF.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSuggestsPDFsNamedForTheAsset() throws {
        XCTAssertTrue(try pdf("Assets/DR_Chipper_Manual.pdf").isSuggested(forAssetName: "DR Chipper"))
        XCTAssertTrue(try pdf("Assets/John-Deere/1E and 1R Series.pdf").isSuggested(forAssetName: "John Deere 1025R"))
        XCTAssertFalse(try pdf("Assets/Home/EcoWater Owners Manual.pdf").isSuggested(forAssetName: "DR Chipper"))
    }

    func testFolderAndFilename() throws {
        let nested = try pdf("Assets/Landscape/Chainsaws/Husqvarna 450.pdf")
        XCTAssertEqual(nested.folder, "Landscape/Chainsaws")
        XCTAssertEqual(nested.filename, "Husqvarna 450.pdf")
        XCTAssertEqual(try pdf("Assets/DR_Chipper_Manual.pdf").folder, "")
    }
}

final class ManualPDFTextTests: XCTestCase {
    func testStartsAtPeriodicMaintenanceAndStopsAtSpecifications() {
        let pages = [
            "----- page 1 -----\nSafety warnings",
            "----- page 2 -----\nPeriodic maintenance chart",
            "----- page 3 -----\nChange the oil every 50 hours",
            "----- page 4 -----\nSpecifications",
        ]

        let chunks = ManualPDFText.maintenanceChunks(fromPageTexts: pages, maxCharactersPerChunk: 4_000)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("page 2"))
        XCTAssertTrue(chunks[0].contains("page 3"))
        XCTAssertFalse(chunks[0].contains("Safety warnings"))
        XCTAssertFalse(chunks[0].contains("Specifications"))
        XCTAssertEqual(ManualPDFText.firstPageNumber(in: chunks[0]), 2)
    }

    func testLongPagesAreSplitWithoutDroppingText() {
        let lines = (1...400).map { "Maintenance line \($0): check the belt tension." }
        let page = "----- page 7 -----\n" + lines.joined(separator: "\n")

        let chunks = ManualPDFText.maintenanceChunks(fromPageTexts: [page], maxCharactersPerChunk: 2_000)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2_000 })
        let rejoined = chunks.joined(separator: "\n")
        XCTAssertTrue(lines.allSatisfy { rejoined.contains($0) })
    }
}
