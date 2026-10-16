import Foundation

/// Keep each model request small while retaining the source label on every part.
struct ManualURLBatch {
    let header: String
    let text: String

    var corpus: String { header + "\n" + text }

    func split(limit: Int) -> [ManualURLBatch] {
        var rest = text[...]
        var parts: [ManualURLBatch] = []
        let capacity = max(1, limit - header.count - 1)
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: min(capacity, rest.count))
            if end != rest.endIndex {
                let prefix = rest[..<end]
                if let newline = prefix.lastIndex(of: "\n"), newline != rest.startIndex {
                    end = rest.index(after: newline)
                }
            }
            parts.append(ManualURLBatch(header: header, text: String(rest[..<end])))
            rest = rest[end...]
        }
        return parts
    }

    static func batches(from chunks: [String], limit: Int = 6_000) -> [ManualURLBatch] {
        chunks.flatMap { chunk -> [ManualURLBatch] in
            guard let newline = chunk.firstIndex(of: "\n") else { return [] }
            return ManualURLBatch(header: String(chunk[..<newline]), text: String(chunk[chunk.index(after: newline)...]))
                .split(limit: limit)
        }
    }
}

/// Never treat a token-limited or unfinished envelope as a complete JSON result.
enum ManualOllamaResponse {
    static func content(from data: Data) throws -> String {
        struct Envelope: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
            let done: Bool
            let done_reason: String?
        }
        let result: Envelope
        do { result = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ManualImportError.badJSON("The local model response envelope was invalid.") }
        if !result.done && result.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ManualImportError.modelRuntimeFailure
        }
        guard result.done, result.done_reason == "stop" else {
            throw ManualImportError.incompleteModelResponse
        }
        return result.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Retry only rejected model payloads, never publish partial results or run unboundedly.
enum ManualURLBatchProcessor {
    static func extract<T>(
        _ batch: ManualURLBatch, remainingRequests: inout Int, depth: Int = 0,
        request: (ManualURLBatch) async throws -> T
    ) async throws -> [T] {
        guard remainingRequests > 0 else {
            throw ManualImportError.badJSON("Manual processing reached its bounded request limit. No partial results were imported. Try a specific service section.")
        }
        remainingRequests -= 1
        do { return [try await request(batch)] }
        catch let error as ManualImportError {
            switch error {
            case .badJSON, .incompleteModelResponse:
                // Short procedure pages can fail transiently; retry once without
                // inventing a split or accepting an incomplete response.
                if batch.text.count <= 800 {
                    guard depth == 0 else { throw error }
                    return try await extract(batch, remainingRequests: &remainingRequests,
                        depth: depth + 1, request: request)
                }
                guard depth < 3 else { throw error }
                let parts = batch.split(limit: batch.header.count + 1 + max(1, batch.text.count / 2))
                var results: [T] = []
                for part in parts {
                    results += try await extract(part, remainingRequests: &remainingRequests,
                        depth: depth + 1, request: request)
                }
                return results
            default: throw error
            }
        }
    }
}
