import Foundation
import Observation

enum MaterialPreparation: Equatable {
    case ready(WorkRequestMaterial)
    case rejected(String)
}

@MainActor
@Observable
final class WorkRequestDraftAssistant {
    private(set) var status = "Organize draft uses the on-device model. Nothing is submitted until you tap Submit."
    private(set) var review: WorkRequestDraftReview?
    private(set) var isOrganizing = false
    private var generation: Task<Void, Never>?
    private var ticket: UUID?
    private var requestedReport: String?

    func organize(report: String, using generator: any WorkRequestDraftGenerating) {
        generation?.cancel()
        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        review = nil
        requestedReport = trimmed
        let current = UUID()
        ticket = current
        guard !trimmed.isEmpty else {
            isOrganizing = false
            status = WorkRequestDraftRejection.emptyReport.message
            return
        }
        guard trimmed.count <= WorkRequestDraftLimits.maximumCharacters else {
            isOrganizing = false
            status = WorkRequestDraftRejection.reportTooLong.message
            return
        }
        isOrganizing = true
        status = "Organizing a draft on this device…"
        generation = Task {
            let result = await generator.generate(from: trimmed)
            guard !Task.isCancelled, ticket == current, requestedReport == trimmed else { return }
            isOrganizing = false
            generation = nil
            switch result {
            case .success(let candidate):
                switch WorkRequestDraftValidator.validate(candidate, source: trimmed) {
                case .success(let review):
                    self.review = review
                    status = "Review each suggestion. The description stays as written until you edit it."
                case .failure(let rejection):
                    status = rejection.message
                }
            case .failure(let failure):
                status = failure.message
            }
        }
    }

    func cancel() {
        generation?.cancel()
        generation = nil
        ticket = nil
        requestedReport = nil
        isOrganizing = false
        review = nil
        status = "Organization canceled. The form is unchanged."
    }

    func invalidateIfReportChanged(_ report: String) {
        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = review?.sourceReport ?? requestedReport
        guard let source, trimmed != source else { return }
        generation?.cancel()
        generation = nil
        ticket = nil
        requestedReport = nil
        isOrganizing = false
        review = nil
        status = "The report changed, so the suggestions were cleared."
    }

    func applyArea(report: String, to draft: inout WorkRequestIntakeDraft) -> String? {
        guard let review, current(report, matches: review) else {
            return "Suggestion is out of date. Organize the current report again."
        }
        guard let area = review.areaText else { return "No area was suggested." }
        draft.area = area
        return nil
    }

    func preparedMaterial(
        report: String,
        index: Int,
        quantityOverride: String?
    ) -> MaterialPreparation {
        guard let review, current(report, matches: review) else {
            return .rejected("Suggestion is out of date. Organize the current report again.")
        }
        guard review.materials.indices.contains(index) else {
            return .rejected("That material suggestion is no longer available.")
        }
        let suggestion = review.materials[index]
        let quantity = suggestion.quantityText ?? quantityOverride ?? ""
        guard let accepted = WorkRequestQuantities.accepted(quantity) else {
            return .rejected("Enter a positive quantity for \(suggestion.name), or skip that material.")
        }
        var material = WorkRequestMaterial()
        material.name = suggestion.name
        material.quantity = accepted
        material.unit = suggestion.unit
        material.note = suggestion.note
        return .ready(material)
    }

    private func current(_ report: String, matches review: WorkRequestDraftReview) -> Bool {
        report.trimmingCharacters(in: .whitespacesAndNewlines) == review.sourceReport
    }
}
