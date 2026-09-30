import Foundation

enum WorkRequestDraftGenerationFailure: Equatable, Error {
    case unavailable(String)
    case failed

    var message: String {
        switch self {
        case .unavailable(let reason):
            return "\(reason) You can still edit and submit the form."
        case .failed:
            return "The on-device model could not organize this report. You can still edit and submit the form."
        }
    }
}

protocol WorkRequestDraftGenerating: Sendable {
    func generate(from report: String) async -> Result<WorkRequestDraftCandidate, WorkRequestDraftGenerationFailure>
}

struct UnavailableWorkRequestDraftGenerator: WorkRequestDraftGenerating {
    var reason = "On-device organization is unavailable."

    func generate(from report: String) async -> Result<WorkRequestDraftCandidate, WorkRequestDraftGenerationFailure> {
        .failure(.unavailable(reason))
    }
}
