import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleWorkRequestDraftGenerator: WorkRequestDraftGenerating {
    func generate(from report: String) async -> Result<WorkRequestDraftCandidate, WorkRequestDraftGenerationFailure> {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return .failure(.unavailable("On-device organization requires iOS 26 or later."))
        }
        return await AppleWorkRequestGeneration.generate(from: report)
        #else
        return .failure(.unavailable("On-device organization is not included in this build."))
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleWorkRequestGeneration {
    static func generate(from report: String) async -> Result<WorkRequestDraftCandidate, WorkRequestDraftGenerationFailure> {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            return .failure(.unavailable("This device cannot run the on-device language model."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .failure(.unavailable("Apple Intelligence is turned off."))
        case .unavailable(.modelNotReady):
            return .failure(.unavailable("The on-device language model is not ready."))
        @unknown default:
            return .failure(.unavailable("The on-device language model is unavailable."))
        }
        guard model.supportsLocale(Locale(identifier: "en-US")) || model.supportsLocale() else {
            return .failure(.unavailable("On-device organization does not support this device language yet."))
        }

        let session = LanguageModelSession(instructions: """
            You extract editable work-request fields from one maintenance report.
            Use only the report text. Do not call tools or infer a repair.
            """)
        do {
            let response = try await session.respond(
                to: WorkRequestDraftPrompt.text(for: report),
                generating: AppleWorkRequestExtraction.self
            )
            return .success(response.content.candidate)
        } catch {
            return .failure(.failed)
        }
    }
}

@available(iOS 26.0, *)
@Generable(description: "Facts copied from one maintenance report. Null means the report did not state that fact.")
private struct AppleWorkRequestExtraction {
    @Guide(description: "Location words from the report, or null when no location is stated.")
    var areaText: String?

    @Guide(description: "Verbatim report excerpt that supports areaText. Empty when areaText is null.")
    var areaExcerpt: String

    @Guide(description: "Equipment or place name as written in the report, or null.")
    var assetMention: String?

    @Guide(description: "Verbatim report excerpt that supports assetMention. Empty when assetMention is null.")
    var assetExcerpt: String

    @Guide(description: "Materials the report actually names.", .maximumCount(5))
    var materials: [AppleMaterialExtraction]

    @Guide(description: "Uncertainty, negation, or missing facts for a person to review.", .maximumCount(8))
    var reviewNotes: [String]

    var candidate: WorkRequestDraftCandidate {
        WorkRequestDraftCandidate(
            areaText: areaText,
            areaExcerpt: areaExcerpt,
            assetMention: assetMention,
            assetExcerpt: assetExcerpt,
            materials: materials.map(\.candidate),
            reviewNotes: reviewNotes
        )
    }
}

@available(iOS 26.0, *)
@Generable(description: "One material named by the report.")
private struct AppleMaterialExtraction {
    @Guide(description: "Material name as written.")
    var name: String

    @Guide(description: "One finite positive quantity written in the report, or null. Never guess.")
    var quantityText: String?

    @Guide(description: "Unit written in the report, or null.")
    var unit: String?

    @Guide(description: "Short note copied from the report, or null.")
    var note: String?

    @Guide(description: "Verbatim report excerpt that names this material.")
    var sourceExcerpt: String

    var candidate: WorkRequestMaterialCandidate {
        WorkRequestMaterialCandidate(
            name: name,
            quantityText: quantityText,
            unit: unit,
            note: note,
            sourceExcerpt: sourceExcerpt
        )
    }
}
#endif
