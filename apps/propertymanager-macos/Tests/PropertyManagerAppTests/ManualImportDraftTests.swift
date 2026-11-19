import XCTest
@testable import PropertyManagerApp

final class ManualImportDraftTests: XCTestCase {
    func testAcceptedDraftLinksTaskToSelectedAsset() {
        let assetID = UUID()
        let draft = ManualImportDraft(
            area: "Polaris Ranger",
            item: "Inspect drive belt",
            category: "Vehicle",
            frequency: .monthly,
            warningDays: 30,
            criticalDays: 45,
            estimatedMinutes: 20,
            taskDescription: "Inspect the drive belt.",
            responseInstructions: "Inspect before operation.",
            suppliesNeeded: "",
            notes: "",
            manufacturer: "Polaris",
            sourceManualName: "Polaris Ranger.pdf",
            partNumbers: [],
            referenceURLs: [],
            toolsRequired: []
        )

        XCTAssertEqual(
            draft.asMaintenanceTask(assetID: assetID, verificationStatus: .userAccepted).assetId,
            assetID
        )
    }

    func testRemovesOnlyLeadingBOMImmediatelyBeforePDFSignature() {
        let payload = Data([0xff, 0xfe]) + Data("%PDF-1.5".utf8)
        XCTAssertEqual(ManualPDFFile.canonicalData(from: payload), Data("%PDF-1.5".utf8))

        let notAPDF = Data([0xff, 0xfe]) + Data("not a PDF".utf8)
        XCTAssertEqual(ManualPDFFile.canonicalData(from: notAPDF), notAPDF)
    }

    func testAcceptsOneJSONObjectWrappedInMarkdownFence() throws {
        let content = """
        ```json
        {"manufacturer":"Polaris","equipment":"Ranger","tasks":[]}
        ```
        """

        let data = try ManualJSONPayload.objectData(from: content)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["manufacturer"] as? String, "Polaris")
    }

    func testRejectsMalformedEmbeddedJSON() {
        XCTAssertThrowsError(try ManualJSONPayload.objectData(from: "Here: {\"tasks\":[}"))
    }

    func testMaintenanceChunksKeepOilSectionAndExcludeSpecifications() {
        let chunks = PDFManualTextExtractor.maintenanceChunks(
            fromPageTexts: [
                "----- page 1 -----\nRANGER owner manual",
                "----- page 2 -----\nDaily pre-ride inspection",
                "----- page 67 -----\nMAINTENANCE\nPeriodic Maintenance Chart",
                "----- page 71 -----\nMAINTENANCE\nEngine Oil\nOil Check",
                "----- page 72 -----\nMAINTENANCE\nEngine Oil\nOil and Filter Change",
                "----- page 102 -----\nSPECIFICATIONS\nVehicle dimensions"
            ],
            maxCharactersPerChunk: 10_000
        )

        let content = chunks.joined(separator: "\n")
        XCTAssertTrue(content.contains("Oil and Filter Change"))
        XCTAssertFalse(content.contains("Vehicle dimensions"))
    }

    func testMaintenanceChunksFindDistributedServicePagesWithoutPeriodicHeading() {
        let chunks = PDFManualTextExtractor.maintenanceChunks(
            fromPageTexts: [
                "----- page 1 -----\nSafety overview and controls",
                "----- page 2 -----\nDaily Checklist\nCheck engine oil and belts for wear.",
                "----- page 12 -----\nRemoving and Replacing the Blade Belt\nWear gloves.",
                "----- page 13 -----\nAdjusting the Brake Cables\nUse a 5.5mm Allen wrench.",
                "----- page 14 -----\nEnd of Season Storage\nChange the oil and filter.",
                "----- page 15 -----\nSpecifications\nVehicle dimensions"
            ],
            maxCharactersPerChunk: 10_000
        )

        let content = chunks.joined(separator: "\n")
        XCTAssertTrue(content.contains("Daily Checklist"))
        XCTAssertTrue(content.contains("Blade Belt"))
        XCTAssertTrue(content.contains("Brake Cables"))
        XCTAssertTrue(content.contains("End of Season"))
        XCTAssertFalse(content.contains("Vehicle dimensions"))
    }

    func testManualTaskIdentityIgnoresAssetPrefixAndFormatting() {
        XCTAssertEqual(
            ManualMaintenanceIdentity.make(area: "DR Field Mower", item: "Change engine oil"),
            ManualMaintenanceIdentity.make(area: "DR Field Mower", item: "DR Field Mower: Change Engine Oil")
        )
    }

    func testManualTaskTitleRemovesEquipmentAndSubsystemPrefixes() {
        XCTAssertEqual(
            ManualTaskTitle.clean(
                "DR FIELD and BRUSH MOWER: Engine: Change engine oil",
                equipmentName: "DR FIELD and BRUSH MOWER",
                subsystem: "Engine"
            ),
            "Change engine oil"
        )
    }

    func testManualTaskTitleUsesSourceActionWhenModelReturnsAHeading() {
        XCTAssertEqual(
            ManualTaskTitle.clean(
                "DR FIELD and BRUSH MOWER: Engine: Fuel Lines and Grommets",
                equipmentName: "DR Field Mower",
                subsystem: "Engine",
                supportingText: "Replace rubber fuel lines and grommets when worn or damaged."
            ),
            "Replace rubber fuel lines and grommets when worn or damaged"
        )
    }

    func testSourceBackedDraftsPreserveCriticalDRMaintenanceRecommendations() {
        let drafts = ManufacturerManualImporter.sourceBackedMaintenanceDrafts(
            manualName: "DR Field Mower Manual.pdf",
            manualText: """
            Check the engine oil level every time before you use the machine.
            Check belts for wear, proper alignment and tension.
            Change the oil (and oil filter, if applicable).
            Clean/replace the Air Filters.
            If your Engine has a Fuel Filter, replace it.
            Replace rubber fuel lines and grommets when worn or damaged or after 5 years of use.
            Removing and Replacing the Blade Belt.
            Adjusting the Brake Cables.
            Battery Care: charge the Battery every 4 – 6 weeks.
            """,
            manufacturer: "DR Power"
        )

        XCTAssertEqual(
            Set(drafts.map(\.item)),
            [
                "Check engine oil level",
                "Inspect belts for wear, alignment, and tension",
                "Change engine oil",
                "Clean or replace air filter",
                "Replace fuel filter",
                "Replace rubber fuel lines and grommets",
                "Replace blade belt",
                "Adjust brake cables",
                "Charge stored battery"
            ]
        )
    }

    func testMaintenanceIdentityCollapsesEquivalentOilAndFilterWording() {
        XCTAssertEqual(
            ManualMaintenanceIdentity.make(area: "DR Field Mower", item: "Change engine oil"),
            ManualMaintenanceIdentity.make(area: "DR Field Mower", item: "Change the oil and oil filter (if applicable)")
        )
        XCTAssertEqual(
            ManualMaintenanceIdentity.make(area: "DR Field Mower", item: "Clean or replace air filter"),
            ManualMaintenanceIdentity.make(area: "DR Field Mower", item: "Replace the Air Filter and Precleaner")
        )
    }

    func testCoverageEvaluationReportsWhatLocalAIActuallyMissed() {
        let expected = [
            draft(item: "Check engine oil level"),
            draft(item: "Change engine oil"),
            draft(item: "Replace blade belt")
        ]
        let local = [
            draft(item: "Check the Engine Oil level every time before you use the machine"),
            draft(item: "Change Engine Oil and Filter")
        ]

        let evaluation = ManufacturerManualImporter.coverageEvaluation(
            localAIDrafts: local,
            sourceBackedDrafts: expected
        )

        XCTAssertEqual(evaluation.localAIConfirmedTitles, ["Change engine oil", "Check engine oil level"])
        XCTAssertEqual(evaluation.missingFromLocalAI, ["Replace blade belt"])
    }

    func testCrossManualWordingMatchesWithoutUsingAreaOrManualName() {
        XCTAssertEqual(
            ManualMaintenanceIdentity.make(area: "Compact Utility Tractors", item: "Check engine valve clearance"),
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "JD 1025R Tractor: Check engine valve clearance")
        )
        XCTAssertEqual(
            ManualMaintenanceIdentity.make(area: "Compact Utility Tractors", item: "Replace fuel filters"),
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "JD 1025R Tractor: Replace Inline Fuel Filter")
        )
        XCTAssertEqual(
            ManualMaintenanceIdentity.make(area: "Compact Utility Tractors", item: "Lubricate control valve and all grease points"),
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "JD 1025R Tractor: Lubricate machine grease fittings in extremely wet and muddy conditions")
        )
        XCTAssertNotEqual(
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "JD 1025R Tractor: Lubricate steering cylinder (Older models only)"),
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "JD 1025R Tractor: Lubricate machine")
        )
        XCTAssertNotEqual(
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "Check engine oil level"),
            ManualMaintenanceIdentity.make(area: "JD 1025R Tractor", item: "Change engine oil and filter")
        )
    }

    func testReviewMarksStoredDuplicatesAndLeavesThemUnselected() {
        let assetID = UUID()
        let stored = draft(
            area: "JD 1025R Tractor",
            item: "JD 1025R Tractor: Check engine valve clearance"
        ).asMaintenanceTask(assetID: assetID)
        let duplicate = draft(area: "Compact Utility Tractors", item: "Check engine valve clearance")
        let fresh = draft(area: "Compact Utility Tractors", item: "Check wheel bolt torque")
        let repeated = draft(area: "Compact Utility Tractors", item: "Check Wheel Bolt Torque")

        let notes = ManualImportReviewSelection.notes(
            drafts: [duplicate, fresh, repeated],
            existingTasks: [stored],
            assetID: assetID
        )
        XCTAssertEqual(notes[duplicate.id], "Duplicate of stored task: \(stored.item)")
        XCTAssertNil(notes[fresh.id])
        XCTAssertEqual(notes[repeated.id], "Duplicate of another proposal: \(fresh.item)")

        let reviewed = ManualImportReviewSelection.applyingDefaultSelection(
            drafts: [duplicate, fresh, repeated],
            existingTasks: [stored],
            assetID: assetID
        )
        XCTAssertFalse(reviewed[0].selected)
        XCTAssertTrue(reviewed[1].selected)
        XCTAssertFalse(reviewed[2].selected)
    }

    private func draft(area: String = "DR Field Mower", item: String) -> ManualImportDraft {
        ManualImportDraft(
            area: area,
            item: item,
            category: "Equipment",
            frequency: .yearly,
            warningDays: 365,
            criticalDays: 730,
            estimatedMinutes: 20,
            taskDescription: item,
            responseInstructions: "Source-backed instruction.",
            suppliesNeeded: "",
            notes: "",
            manufacturer: "DR Power",
            sourceManualName: "DR Field Mower Manual.pdf",
            partNumbers: [],
            referenceURLs: [],
            toolsRequired: []
        )
    }
}
