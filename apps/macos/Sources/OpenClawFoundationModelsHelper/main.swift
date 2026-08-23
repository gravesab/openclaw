import Foundation
import FoundationModels

private struct Request: Decodable {
    let operation: String
    let prompt: String?
    let systemPrompt: String?
}

private struct Response: Encodable {
    let apiAvailable: Bool?
    let availabilityReason: String?
    let generationReady: Bool?
    let content: String?
    let error: String?
}

@main
struct OpenClawFoundationModelsHelper {
    static func main() async {
        let response: Response

        do {
            let request = try JSONDecoder().decode(
                Request.self,
                from: FileHandle.standardInput.readDataToEndOfFile())
            response = try await handle(request)
        } catch {
            response = Response(
                apiAvailable: nil,
                availabilityReason: nil,
                generationReady: false,
                content: nil,
                error: "Foundation Models helper request failed: \(error.localizedDescription)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(response) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func handle(_ request: Request) async throws -> Response {
        guard #available(macOS 26.0, *) else {
            return Response(
                apiAvailable: false,
                availabilityReason: "macOS 26 or later is required",
                generationReady: false,
                content: nil,
                error: nil)
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            return Response(
                apiAvailable: false,
                availabilityReason: String(describing: reason),
                generationReady: false,
                content: nil,
                error: nil)
        }

        if request.operation == "availability" {
            return Response(
                apiAvailable: true,
                availabilityReason: "available; generation readiness not probed",
                generationReady: nil,
                content: nil,
                error: nil)
        }

        guard request.operation == "execute",
              let prompt = request.prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw HelperError.invalidRequest
        }

        let session = LanguageModelSession(
            instructions: request.systemPrompt ?? "Respond concisely and accurately.")
        do {
            let answer = try await session.respond(to: prompt)
            return Response(
                apiAvailable: true,
                availabilityReason: "generation succeeded",
                generationReady: true,
                content: answer.content,
                error: nil)
        } catch {
            return Response(
                apiAvailable: true,
                availabilityReason: "generation request failed",
                generationReady: false,
                content: nil,
                error: "Foundation Models generation failed: \(error.localizedDescription)")
        }
    }
}

private enum HelperError: Error {
    case invalidRequest
}
