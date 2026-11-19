import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ManualExtractionResult {
    let manufacturer: String
    let drafts: [ManualImportDraft]
    let chunks: [PropertyAPIClient.AssetManualExtractionChunk]
    let unreadSections: Int
    let evaluation: ManufacturerManualImporter.CoverageEvaluation
}

enum ManualExtractionError: LocalizedError {
    case unavailable(String)
    case noText
    case noTasks
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .noText:
            return "This PDF has no readable text. Scanned manuals need text recognition before Extract can read them."
        case .noTasks:
            return "No maintenance tasks were found in this manual."
        case .modelFailed(let detail):
            return "The on-device model could not read this manual. \(detail)"
        }
    }
}

/// Reads a manual with Apple's on-device model only, the same extractor the
/// iPhone and iPad use. There is no cloud or Private Cloud Compute fallback.
enum AppleManualExtractor {
    static let extractorName = "PropertyManager Mac Apple on-device"
    static let extractorVersion = "SystemLanguageModel.default"
    /// The on-device model shares a ~4K-token window between the prompt, the
    /// schema, and the answer.
    static let charactersPerChunk = 4_000

    static func extract(
        pdfURL: URL,
        onProgress: @escaping @MainActor (ManufacturerManualImporter.Progress) -> Void
    ) async throws -> ManualExtractionResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw ManualExtractionError.unavailable("Extract requires macOS 26 or later with Apple Intelligence.")
        }
        return try await AppleManualGeneration.extract(pdfURL: pdfURL, onProgress: onProgress)
        #else
        throw ManualExtractionError.unavailable("On-device Extract is not included in this build.")
        #endif
    }

    static func sections(from pdfURL: URL) -> [String] {
        PDFManualTextExtractor.maintenanceChunks(from: pdfURL, maxCharactersPerChunk: charactersPerChunk)
    }

    static func extractionChunks(from sections: [String]) -> [PropertyAPIClient.AssetManualExtractionChunk] {
        sections.map { content in
            PropertyAPIClient.AssetManualExtractionChunk(
                pageNumber: firstPageNumber(in: content),
                sectionHeading: "Maintenance",
                content: content
            )
        }
    }

    static func firstPageNumber(in content: String) -> Int? {
        guard let range = content.range(of: #"----- page ([0-9]+) -----"#, options: .regularExpression) else {
            return nil
        }
        return Int(content[range].filter(\.isNumber))
    }

    /// Titles are cleaned and tasks without source-backed how-to steps are
    /// dropped. Tasks without a manufacturer interval are dropped too; on this
    /// model they are almost always single steps of a procedure.
    static func drafts(
        from tasks: [ExtractedManualTask],
        manufacturer: String,
        equipment: String,
        manualName: String
    ) -> [ManualImportDraft] {
        let equipmentName = nonEmpty(equipment) ?? "Equipment"
        return tasks.compactMap { task in
            guard let responseInstructions = nonEmpty(task.responseInstructions),
                  let interval = ManualInterval.from(task.frequency) else { return nil }
            let item = ManualTaskTitle.clean(
                nonEmpty(task.item) ?? "Maintenance item",
                equipmentName: equipmentName,
                subsystem: nonEmpty(task.area),
                supportingText: nonEmpty(task.taskDescription) ?? responseInstructions
            )
            var notesBits: [String] = []
            if let note = interval.note { notesBits.append(note) }
            if let notes = nonEmpty(task.notes) { notesBits.append(notes) }
            notesBits.append("Source manual: \(manualName)")
            if !manufacturer.isEmpty { notesBits.append("Manufacturer: \(manufacturer)") }
            return ManualImportDraft(
                area: equipmentName,
                item: item,
                category: ManualTaskCategory.from(task.category, area: equipmentName),
                frequency: interval.frequency,
                warningDays: interval.warningDays,
                criticalDays: interval.criticalDays,
                estimatedMinutes: max(task.estimatedMinutes, 5),
                taskDescription: nonEmpty(task.taskDescription) ?? item,
                responseInstructions: responseInstructions,
                suppliesNeeded: task.suppliesNeeded.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notesBits.joined(separator: "\n"),
                manufacturer: manufacturer,
                sourceManualName: manualName,
                partNumbers: task.partNumbers.compactMap(nonEmpty),
                referenceURLs: [],
                toolsRequired: task.tools.compactMap { tool in
                    nonEmpty(tool.name).map { ToolRequirement(name: $0, size: tool.size) }
                }
            )
        }
    }

    /// Adds the literal manufacturer recommendations the source verifier finds
    /// in the PDF text when the model missed them.
    static func merged(
        modelDrafts: [ManualImportDraft],
        manualName: String,
        manualText: String,
        manufacturer: String
    ) -> (drafts: [ManualImportDraft], evaluation: ManufacturerManualImporter.CoverageEvaluation) {
        let sourceBacked = ManufacturerManualImporter.sourceBackedMaintenanceDrafts(
            manualName: manualName,
            manualText: manualText,
            manufacturer: manufacturer
        )
        let evaluation = ManufacturerManualImporter.coverageEvaluation(
            localAIDrafts: modelDrafts,
            sourceBackedDrafts: sourceBacked
        )
        return (appendingNewActions(sourceBacked, to: modelDrafts), evaluation)
    }

    /// Keeps the first proposal for each maintenance action across sections.
    static func appendingNewActions(_ candidates: [ManualImportDraft], to drafts: [ManualImportDraft]) -> [ManualImportDraft] {
        var result = drafts
        for candidate in candidates {
            let key = candidate.maintenanceIdentity
            if !result.contains(where: { ManualMaintenanceIdentity.isSameAction(key, $0.maintenanceIdentity) }) {
                result.append(candidate)
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Platform-neutral copy of one model answer so draft mapping stays testable
/// without the model.
struct ExtractedManualTask: Equatable {
    struct Tool: Equatable {
        var name: String
        var size: String
    }

    var area: String
    var item: String
    var category: String
    var frequency: String
    var estimatedMinutes: Int
    var taskDescription: String
    var responseInstructions: String
    var suppliesNeeded: String
    var partNumbers: [String]
    var tools: [Tool]
    var notes: String
}

/// Turns the interval the manual prints into a calendar schedule. The model
/// is only asked to copy that wording; its own day estimates defaulted to daily.
struct ManualInterval: Equatable {
    let frequency: TaskFrequency
    let warningDays: Int
    /// Manufacturer wording kept in the task notes when the calendar schedule
    /// is an approximation.
    let note: String?

    var criticalDays: Int { max(warningDays * 2, warningDays + 7) }

    static func from(_ raw: String) -> ManualInterval? {
        let stated = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stated.isEmpty else { return nil }
        let text = stated.lowercased()
        let approximate = "Manufacturer interval: \(stated)."
        let contains: (String) -> Bool = { text.contains($0) }

        if text.range(of: #"\d+\s*(operating\s+)?(hours?|hrs?)\b"#, options: .regularExpression) != nil {
            return ManualInterval(
                frequency: .monthly,
                warningDays: 30,
                note: approximate + " Set an hour trigger on the task if the asset has an hour meter."
            )
        }
        if ["each use", "every use", "before use", "after use", "daily", "every day", "each day"].contains(where: contains) {
            return ManualInterval(frequency: .daily, warningDays: 1, note: nil)
        }
        if ["2 week", "two week", "biweek", "every other week"].contains(where: contains) {
            return ManualInterval(frequency: .biweekly, warningDays: 14, note: nil)
        }
        if contains("week") {
            return ManualInterval(frequency: .weekly, warningDays: 7, note: nil)
        }
        if ["quarter", "3 month", "three month"].contains(where: contains) {
            return ManualInterval(frequency: .quarterly, warningDays: 90, note: nil)
        }
        if ["6 month", "six month", "twice a year", "semi-annual"].contains(where: contains) {
            return ManualInterval(frequency: .yearly, warningDays: 180, note: approximate)
        }
        if contains("month") {
            return ManualInterval(frequency: .monthly, warningDays: 30, note: nil)
        }
        if ["year", "annual", "season", "storage", "winter"].contains(where: contains) {
            return ManualInterval(frequency: .yearly, warningDays: 365, note: nil)
        }
        return ManualInterval(frequency: .monthly, warningDays: 30, note: approximate)
    }
}

enum ManualTaskCategory {
    static func from(_ raw: String?, area: String) -> String {
        let text = (raw ?? area).lowercased()
        if text.contains("pool") { return "Pool" }
        if text.contains("hot") || text.contains("tub") || text.contains("spa") { return "Home" }
        if text.contains("fence") || text.contains("gate") || text.contains("property") { return "Property" }
        if text.contains("ground") || text.contains("yard") || text.contains("lawn") { return "Grounds" }
        if text.contains("safety") || text.contains("fire") { return "Safety" }
        if text.contains("house") || text.contains("home") || text.contains("softener") { return "House" }
        return "Equipment"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum AppleManualGeneration {
    static let instructions = """
    You extract the owner's recurring maintenance jobs from one section of an equipment manual.
    A task is one job the owner schedules, such as "Lubricate flywheel bearings" or "Check knife to wear plate gap".
    The steps of a procedure are never separate tasks: put them, numbered, in that task's responseInstructions.
    Safety or preparation steps such as shutting down the engine, disengaging the blade, or waiting for parts
    to stop are never tasks.
    Copy the interval exactly as the manual prints it for that job, for example "Before each use",
    "Every 8-10 operating hours", "Yearly", or "As needed". Leave it empty when the section states no interval.
    Use only the section text. Do not invent part numbers, sizes, or intervals.
    Return no tasks when the section has no recurring maintenance jobs.
    """

    static func extract(
        pdfURL: URL,
        onProgress: @escaping @MainActor (ManufacturerManualImporter.Progress) -> Void
    ) async throws -> ManualExtractionResult {
        try checkAvailability()
        let manualName = pdfURL.lastPathComponent
        let sections = AppleManualExtractor.sections(from: pdfURL)
        guard !sections.isEmpty else { throw ManualExtractionError.noText }

        var manufacturer = ""
        var equipment = ""
        var modelDrafts: [ManualImportDraft] = []
        var unread = 0
        var firstError: Error?

        for (index, section) in sections.enumerated() {
            await onProgress(ManufacturerManualImporter.Progress(
                completedSections: index,
                totalSections: sections.count,
                discoveredDrafts: modelDrafts.count
            ))
            try Task.checkCancellation()
            let answers: [AppleManualSchedule]
            do {
                answers = try await read(section: section, manualName: manualName)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                unread += 1
                continue
            }
            for answer in answers {
                if manufacturer.isEmpty { manufacturer = answer.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines) }
                if equipment.isEmpty { equipment = answer.equipment.trimmingCharacters(in: .whitespacesAndNewlines) }
                let drafts = AppleManualExtractor.drafts(
                    from: answer.tasks.map(\.extracted),
                    manufacturer: manufacturer,
                    equipment: equipment,
                    manualName: manualName
                )
                modelDrafts = AppleManualExtractor.appendingNewActions(drafts, to: modelDrafts)
            }
        }
        await onProgress(ManufacturerManualImporter.Progress(
            completedSections: sections.count,
            totalSections: sections.count,
            discoveredDrafts: modelDrafts.count
        ))

        if unread == sections.count, let firstError {
            throw ManualExtractionError.modelFailed(firstError.localizedDescription)
        }
        let merged = AppleManualExtractor.merged(
            modelDrafts: modelDrafts,
            manualName: manualName,
            manualText: sections.joined(separator: "\n\n"),
            manufacturer: manufacturer
        )
        guard !merged.drafts.isEmpty else { throw ManualExtractionError.noTasks }
        return ManualExtractionResult(
            manufacturer: manufacturer,
            drafts: merged.drafts,
            chunks: AppleManualExtractor.extractionChunks(from: sections),
            unreadSections: unread,
            evaluation: merged.evaluation
        )
    }

    private static func checkAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw ManualExtractionError.unavailable("This Mac cannot run Apple's on-device model.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ManualExtractionError.unavailable("Turn on Apple Intelligence in System Settings to use Extract.")
        case .unavailable(.modelNotReady):
            throw ManualExtractionError.unavailable("Apple's on-device model is still downloading. Try Extract again later.")
        @unknown default:
            throw ManualExtractionError.unavailable("Apple's on-device model is unavailable.")
        }
    }

    /// A section that overflows the context window is retried once as two halves.
    private static func read(section: String, manualName: String) async throws -> [AppleManualSchedule] {
        do {
            return [try await respond(to: section, manualName: manualName)]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard section.count > 1_000 else { throw error }
            let middle = section.index(section.startIndex, offsetBy: section.count / 2)
            let splitAt = section[..<middle].lastIndex(of: "\n") ?? middle
            var answers: [AppleManualSchedule] = []
            for half in [String(section[..<splitAt]), String(section[splitAt...])] {
                answers.append(try await respond(to: half, manualName: manualName))
            }
            return answers
        }
    }

    private static func respond(to section: String, manualName: String) async throws -> AppleManualSchedule {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let response = try await session.respond(
            to: "Manual file name: \(manualName)\n\nManual section:\n\(section)",
            generating: AppleManualSchedule.self,
            options: GenerationOptions(temperature: 0.1)
        )
        return response.content
    }
}

@available(macOS 26.0, *)
@Generable(description: "Maintenance tasks the manufacturer recommends in one manual section.")
private struct AppleManualSchedule {
    @Guide(description: "Manufacturer name printed in the manual, or empty.")
    var manufacturer: String

    @Guide(description: "Equipment model or name the manual covers, or empty.")
    var equipment: String

    @Guide(description: "Recurring maintenance jobs in this section, one per job. Empty when there are none.", .maximumCount(5))
    var tasks: [AppleManualTask]
}

@available(macOS 26.0, *)
@Generable(description: "One manufacturer-recommended maintenance task.")
private struct AppleManualTask {
    @Guide(description: "Subsystem heading such as Engine or Deck, or empty.")
    var area: String

    @Guide(description: "Short title for the whole job, for example Lubricate flywheel bearings. Never a single step.")
    var item: String

    @Guide(description: "One of Pool, Home, Grounds, Equipment, House, Safety, Property.")
    var category: String

    @Guide(description: "Interval exactly as the manual prints it for this job, or empty when none is stated.")
    var frequency: String

    @Guide(description: "Estimated minutes to do the whole job.")
    var estimatedMinutes: Int

    @Guide(description: "One sentence describing the job.")
    var taskDescription: String

    @Guide(description: "All steps of the job, numbered, copied faithfully from the manual.")
    var responseInstructions: String

    @Guide(description: "Supplies the manual names, or empty.")
    var suppliesNeeded: String

    @Guide(description: "Part numbers printed in the manual. Never guess.", .maximumCount(4))
    var partNumbers: [String]

    @Guide(description: "Tools the manual names, with sizes when given.", .maximumCount(4))
    var tools: [AppleManualTool]

    @Guide(description: "Page or section reference, or empty.")
    var notes: String

    var extracted: ExtractedManualTask {
        ExtractedManualTask(
            area: area,
            item: item,
            category: category,
            frequency: frequency,
            estimatedMinutes: estimatedMinutes,
            taskDescription: taskDescription,
            responseInstructions: responseInstructions,
            suppliesNeeded: suppliesNeeded,
            partNumbers: partNumbers,
            tools: tools.map { ExtractedManualTask.Tool(name: $0.name, size: $0.size) },
            notes: notes
        )
    }
}

@available(macOS 26.0, *)
@Generable(description: "A tool named by the manual.")
private struct AppleManualTool {
    @Guide(description: "Tool name.")
    var name: String

    @Guide(description: "Size such as 10 mm or 3/8 in, or empty.")
    var size: String
}
#endif
