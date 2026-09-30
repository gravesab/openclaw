import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ManualExtractionResult {
    let manufacturer: String
    let drafts: [ManualImportDraft]
    let chunks: [AssetManualExtractionChunk]
    let unreadSections: Int
}

struct ManualExtractionProgress: Equatable {
    let completedSections: Int
    let totalSections: Int
    let discoveredDrafts: Int
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

/// Reads a manual with Apple's on-device model only. There is no cloud fallback.
enum AppleManualExtractor {
    static let extractorName = "PropertyManager iOS Apple on-device"
    static let extractorVersion = "SystemLanguageModel.default"

    static func extract(
        pdf: Data,
        manualName: String,
        onProgress: @MainActor (ManualExtractionProgress) -> Void
    ) async throws -> ManualExtractionResult {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw ManualExtractionError.unavailable("Extract on iPhone and iPad requires iOS 26 or later with Apple Intelligence.")
        }
        return try await AppleManualGeneration.extract(pdf: pdf, manualName: manualName, onProgress: onProgress)
        #else
        throw ManualExtractionError.unavailable("On-device Extract is not included in this build.")
        #endif
    }

    /// Mirrors the Mac importer: titles are cleaned and tasks without source-backed
    /// how-to steps are dropped. Tasks without a manufacturer interval are dropped
    /// too; on this model they are almost always single steps of a procedure.
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
                    nonEmpty(tool.name).map { ManualToolRequirement(name: $0, size: tool.size, notes: "") }
                }
            )
        }
    }

    static func merged(
        modelDrafts: [ManualImportDraft],
        manualName: String,
        manualText: String,
        manufacturer: String
    ) -> [ManualImportDraft] {
        let sourceBacked = ManualSourceBackedDrafts.drafts(
            manualName: manualName,
            manualText: manualText,
            manufacturer: manufacturer
        )
        return appendingNewActions(sourceBacked, to: modelDrafts)
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

/// Platform-neutral copy of one model answer so draft mapping stays testable without the model.
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

#if canImport(FoundationModels)
@available(iOS 26.0, *)
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
        pdf: Data,
        manualName: String,
        onProgress: @MainActor (ManualExtractionProgress) -> Void
    ) async throws -> ManualExtractionResult {
        try checkAvailability()
        let pages = ManualPDFText.pageTexts(from: pdf)
        let chunks = ManualPDFText.maintenanceChunks(
            fromPageTexts: pages,
            maxCharactersPerChunk: ManualPDFText.onDeviceCharactersPerChunk
        )
        guard !chunks.isEmpty else { throw ManualExtractionError.noText }

        var manufacturer = ""
        var equipment = ""
        var modelDrafts: [ManualImportDraft] = []
        var unread = 0
        var firstError: Error?

        for (index, chunk) in chunks.enumerated() {
            await onProgress(ManualExtractionProgress(
                completedSections: index,
                totalSections: chunks.count,
                discoveredDrafts: modelDrafts.count
            ))
            try Task.checkCancellation()
            let answers: [AppleManualSchedule]
            do {
                answers = try await read(chunk: chunk, manualName: manualName)
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
        await onProgress(ManualExtractionProgress(
            completedSections: chunks.count,
            totalSections: chunks.count,
            discoveredDrafts: modelDrafts.count
        ))

        if unread == chunks.count, let firstError {
            throw ManualExtractionError.modelFailed(firstError.localizedDescription)
        }
        let drafts = AppleManualExtractor.merged(
            modelDrafts: modelDrafts,
            manualName: manualName,
            manualText: chunks.joined(separator: "\n\n"),
            manufacturer: manufacturer
        )
        guard !drafts.isEmpty else { throw ManualExtractionError.noTasks }
        return ManualExtractionResult(
            manufacturer: manufacturer,
            drafts: drafts,
            chunks: ManualPDFText.extractionChunks(from: chunks),
            unreadSections: unread
        )
    }

    private static func checkAvailability() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw ManualExtractionError.unavailable("This device cannot run Apple's on-device model, so Extract is Mac-only here.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ManualExtractionError.unavailable("Turn on Apple Intelligence in Settings to use Extract.")
        case .unavailable(.modelNotReady):
            throw ManualExtractionError.unavailable("Apple's on-device model is still downloading. Try Extract again later.")
        @unknown default:
            throw ManualExtractionError.unavailable("Apple's on-device model is unavailable.")
        }
    }

    /// A section that overflows the context window is retried once as two halves.
    private static func read(chunk: String, manualName: String) async throws -> [AppleManualSchedule] {
        do {
            return [try await respond(to: chunk, manualName: manualName)]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard chunk.count > 1_000 else { throw error }
            let middle = chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)
            let splitAt = chunk[..<middle].lastIndex(of: "\n") ?? middle
            var answers: [AppleManualSchedule] = []
            for half in [String(chunk[..<splitAt]), String(chunk[splitAt...])] {
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

@available(iOS 26.0, *)
@Generable(description: "Maintenance tasks the manufacturer recommends in one manual section.")
private struct AppleManualSchedule {
    @Guide(description: "Manufacturer name printed in the manual, or empty.")
    var manufacturer: String

    @Guide(description: "Equipment model or name the manual covers, or empty.")
    var equipment: String

    @Guide(description: "Recurring maintenance jobs in this section, one per job. Empty when there are none.", .maximumCount(5))
    var tasks: [AppleManualTask]
}

@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
@Generable(description: "A tool named by the manual.")
private struct AppleManualTool {
    @Guide(description: "Tool name.")
    var name: String

    @Guide(description: "Size such as 10 mm or 3/8 in, or empty.")
    var size: String
}
#endif
