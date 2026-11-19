import XCTest
@testable import PropertyManagerApp

final class ManualURLResponseTests: XCTestCase {
    func testCompleteEnvelopeAcceptsJSONButLengthOrUnfinishedDoesNot() throws {
        func envelope(done: Bool, reason: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["done": done, "done_reason": reason,
                "message": ["content": "{\"tasks\":[]}"]])
        }
        XCTAssertEqual(try ManualOllamaResponse.content(from: envelope(done: true, reason: "stop")), "{\"tasks\":[]}")
        XCTAssertThrowsError(try ManualOllamaResponse.content(from: envelope(done: true, reason: "length")))
        XCTAssertThrowsError(try ManualOllamaResponse.content(from: envelope(done: false, reason: "stop")))
        XCTAssertThrowsError(try ManualOllamaResponse.content(from: envelope(done: true, reason: "load")))
    }

    func testEmptyUnfinishedRuntimeResponseIsNotRetriedAsJSON() async throws {
        let data = Data(#"{"model":"","message":{"content":""},"done":false}"#.utf8)
        var budget = 40
        var calls = 0
        do {
            _ = try await ManualURLBatchProcessor.extract(ManualURLBatch(header: "source", text: "Inspect hose"), remainingRequests: &budget) { _ in
                calls += 1
                return try ManualOllamaResponse.content(from: data)
            }
            XCTFail("Runtime failure must not produce drafts")
        } catch ManualImportError.modelRuntimeFailure {
            XCTAssertEqual(calls, 1)
        }
    }

    func testEverySourceCharacterSurvivesBoundedLabeledSplit() {
        let header = "----- source: http://manuals.deere.com/example/section.html -----"
        let body = String(repeating: "Check filter | every 50 hours\n", count: 650)
        let batches = ManualURLBatch.batches(from: [header + "\n" + body])
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.corpus.count <= 6000 && $0.header == header })
        XCTAssertEqual(batches.map(\.text).joined(), body)
        let subdivided = batches[0].split(limit: 1400)
        XCTAssertEqual(subdivided.map(\.text).joined(), batches[0].text)
        XCTAssertTrue(subdivided.allSatisfy { $0.header == header && $0.corpus.count <= 1400 })
    }

    func testLongUnbrokenTextIsNotDroppedOrLooped() {
        let body = String(repeating: "🛠", count: 16000)
        let batch = ManualURLBatch(header: "source", text: body)
        let parts = batch.split(limit: 6000)
        XCTAssertEqual(parts.map(\.text).joined(), body)
        XCTAssertTrue(parts.allSatisfy { $0.corpus.count <= 6000 })
    }

    func testStrictTaskPayloadRejectsTruncationAndWrongTypes() throws {
        try URLManualImporter.validateURLPayload("{\"manufacturer\":\"John Deere\",\"tasks\":[]}")
        try URLManualImporter.validateURLPayload("```json\n{\"tasks\":[]}\n```")
        XCTAssertThrowsError(try URLManualImporter.validateURLPayload("{\"tasks\":[{\"item\":\"oil\"}"))
        XCTAssertThrowsError(try URLManualImporter.validateURLPayload("{\"tasks\":[{\"toolsRequired\":[\"wrench\"]}]}"))
        XCTAssertThrowsError(try URLManualImporter.validateURLPayload("{\"steps\":[]}"))
    }

    func testRejectedPayloadRetriesDisjointPartsWithoutLosingText() async throws {
        let body = String(repeating: "a", count: 2400)
        var budget = 10
        var attempts = 0
        let parts = try await ManualURLBatchProcessor.extract(
            ManualURLBatch(header: "source", text: body), remainingRequests: &budget
        ) { batch in
            attempts += 1
            if batch.text.count > 1200 { throw ManualImportError.incompleteModelResponse }
            return batch.text
        }
        XCTAssertEqual(parts.joined(), body)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(budget, 7)
    }

    func testFailedSubBatchDoesNotReturnPreviouslyCompletedParts() async {
        var budget = 3
        var attempts = 0
        do {
            _ = try await ManualURLBatchProcessor.extract(
                ManualURLBatch(header: "source", text: String(repeating: "x", count: 2400)), remainingRequests: &budget
            ) { batch -> String in
                attempts += 1
                if attempts != 2 { throw ManualImportError.badJSON("synthetic invalid response") }
                return batch.text
            }
            XCTFail("Must not return a successful first part when the other part failed")
        } catch { XCTAssertEqual(budget, 0) }
        XCTAssertEqual(attempts, 3)
    }

    func testShortProcedureRetriesOnceThenStops() async throws {
        let batch = ManualURLBatch(header: "source", text: "Inspect hose and tighten clamps.")
        var budget = 40
        var attempts = 0
        let result = try await ManualURLBatchProcessor.extract(batch, remainingRequests: &budget) { part in
            attempts += 1
            if attempts == 1 { throw ManualImportError.incompleteModelResponse }
            return part.text
        }
        XCTAssertEqual(result, [batch.text])
        XCTAssertEqual(attempts, 2)
        attempts = 0
        do {
            _ = try await ManualURLBatchProcessor.extract(batch, remainingRequests: &budget) { _ -> String in
                attempts += 1
                throw ManualImportError.incompleteModelResponse
            }
            XCTFail("Repeated incomplete output must stop")
        } catch { XCTAssertEqual(attempts, 2) }
    }

    func testTOCMetadataCannotIntroduceTasks() throws {
        try URLManualImporter.validateURLPayload("{\"manufacturer\":\"John Deere\",\"model\":\"1025R\"}", metadataOnly: true)
        XCTAssertThrowsError(try URLManualImporter.validateURLPayload("{\"tasks\":[{\"item\":\"Navigation heading\"}]}", metadataOnly: true))
        let properties = try XCTUnwrap(ManufacturerManualImporter.urlMetadataJSONSchema["properties"] as? [String: Any])
        XCTAssertNil(properties["tasks"])
    }

    func testBoundedPredictFitsInsideContextWindow() {
        XCTAssertEqual(ManufacturerManualImporter.boundedContextTokens, 8192)
        XCTAssertEqual(ManufacturerManualImporter.boundedPredictTokens, 4096)
        XCTAssertLessThan(
            ManufacturerManualImporter.boundedPredictTokens,
            ManufacturerManualImporter.boundedContextTokens
        )
        let options = ManufacturerManualImporter.boundedChatOptions()
        XCTAssertEqual(options["num_ctx"] as? Int, ManufacturerManualImporter.boundedContextTokens)
        XCTAssertEqual(options["num_predict"] as? Int, ManufacturerManualImporter.boundedPredictTokens)
    }

    func testCompleteTaskJSONIsAcceptedAndTruncationIsNot() throws {
        let complete = """
        {"manufacturer":"John Deere","tasks":[{"estimatedMinutes":10,"frequency":"Every 10 Hours or Daily","category":"Lubrication","taskDescription":"Lubricate machine grease fittings (A) every 10 hours of operation or on a daily basis in extremely wet and muddy conditions.","confidence":0.95,"area":"Machine Grease Fittings","item":"Grease Fittings","criticalDays":0,"warningDays":1,"sourceFacts":{"maintenanceInterval":"Every 10 hours","sourceExcerpt":"Lubricate fittings.","sectionSourceURLs":["http://manuals.deere.com/omview/OMLVU28480_19/toc.html"]}}]}
        """
        XCTAssertEqual(try URLManualImporter.importableTaskCount(in: complete), 1)
        XCTAssertThrowsError(try URLManualImporter.importableTaskCount(
            in: "{\"manufacturer\":\"John Deere\",\"tasks\":[{\"item\":\"Grease Fittings\",\"taskDescription\":\"Lubricate\",\"warningDays\""
        ))
        XCTAssertThrowsError(try URLManualImporter.importableTaskCount(in: complete + "{\"tasks\":[{\"item\":\"Oil\""))
        XCTAssertEqual(try URLManualImporter.importableTaskCount(in: "{\"tasks\":[{\"confidence\":0.95}]}"), 0)
    }

    func testLengthEnvelopeDoesNotReturnTruncatedJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "done": true,
            "done_reason": "length",
            "message": ["content": "{\"manufacturer\":\"John Deere\",\"tasks\":[{\"warningDays\""]
        ])
        XCTAssertThrowsError(try ManualOllamaResponse.content(from: data)) { error in
            guard case ManualImportError.incompleteModelResponse = error else {
                return XCTFail("length envelope must not become a draft, got \(error)")
            }
        }
    }

    func testNestedToolFieldsHaveSchemaMatchingDecoder() throws {
        let root = ManufacturerManualImporter.urlImportJSONSchema
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let tasks = try XCTUnwrap(properties["tasks"] as? [String: Any])
        let item = try XCTUnwrap(tasks["items"] as? [String: Any])
        let fields = try XCTUnwrap(item["properties"] as? [String: Any])
        let tools = try XCTUnwrap(fields["toolsRequired"] as? [String: Any])
        let tool = try XCTUnwrap(tools["items"] as? [String: Any])
        XCTAssertEqual(tool["type"] as? String, "object")
        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        let facts = try XCTUnwrap(fields["sourceFacts"] as? [String: Any])
        let factFields = try XCTUnwrap(facts["properties"] as? [String: Any])
        XCTAssertNotNil(factFields["tools"])
        XCTAssertNotNil(factFields["sectionSourceURL"])
    }
}
