import Foundation
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Suggests the first category for a new vendor. The model sees only the
/// vendor name and the existing category list. It never sees the raw file,
/// account numbers, statement text, or amounts. A suggestion is not an
/// accounting entry.
///
/// Andrew's rule, which overrides "best guess": the model may pick a
/// category only when the vendor name alone makes it obvious, such as Petco
/// to Pets. Otherwise the answer is Uncategorized and the charge stays
/// uncategorized. The API returns no probability for the category, so no
/// confidence score is invented or used anywhere: a model-written score
/// would be another guess.
protocol RanchOSFinanceCategorySuggesting: Sendable {
    /// Returns one category name, or nil when no suggestion is available.
    func suggestCategory(vendorName: String, categories: [String]) async -> String?
}

#if canImport(FoundationModels) && !os(tvOS)
/// Structured reply: exactly one category field. The valid values come from
/// the prompt's list (or Uncategorized); the store validates the answer
/// against that list and fails closed to Uncategorized.
@available(macOS 26, iOS 26, *)
@Generable
struct RanchOSFinanceCategoryChoice {
    @Guide(description: "Exactly one category name from the list, or Uncategorized")
    var category: String
}
#endif

/// Prompt text and strict output cleaning, shared by the live suggester and
/// tests. Cleaning keeps a suggestion to one short printable line.
enum RanchOSFinanceSuggester {
    static let instructions =
        "You assign one spending category to a vendor, but only when the vendor name alone "
        + "makes the category obvious, such as Petco to Pets. "
        + "Reply with exactly one category name from the list. "
        + "When it is not obvious from the name alone, reply exactly: Uncategorized. "
        + "Nothing else."

    static func prompt(vendorName: String, categories: [String]) -> String {
        let vendor = String(vendorName.prefix(80))
        let listed = categories.prefix(40).joined(separator: ", ")
        return "Vendor: \(vendor)\nCategories: \(listed)\nCategory:"
    }

    /// First line, trimmed, dequoted, printable, 1...64 characters.
    /// Anything else fails closed to nil.
    static func clean(_ raw: String) -> String? {
        var line = raw.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.count >= 2, line.hasPrefix("\""), line.hasSuffix("\"") {
            line = String(line.dropFirst().dropLast())
        }
        if line.count >= 2, line.hasPrefix("'"), line.hasSuffix("'") {
            line = String(line.dropFirst().dropLast())
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= 64,
            line.allSatisfy({ $0.isASCII && !$0.isNewline })
        else {
            return nil
        }
        return line
    }
}

/// Foundation Models on device only: greedy sampling, one structured reply.
/// No Private Cloud Compute, no local LLM, no other provider. Each call opens
/// its own session; any failure — model missing, ineligible, throw,
/// unparsable reply — returns nil and the vendor stays Uncategorized with
/// the honest label.
struct RanchOSFinanceLiveSuggester: RanchOSFinanceCategorySuggesting {
    func suggestCategory(vendorName: String, categories: [String]) async -> String? {
#if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            do {
                let session = LanguageModelSession(instructions: RanchOSFinanceSuggester.instructions)
                let prompt = RanchOSFinanceSuggester.prompt(vendorName: vendorName, categories: categories)
                let options = GenerationOptions(samplingMode: .greedy)
                let response = try await session.respond(
                    to: prompt, generating: RanchOSFinanceCategoryChoice.self, options: options)
                return RanchOSFinanceSuggester.clean(response.content.category)
            } catch {
                return nil
            }
        }
#endif
        return nil
    }
}
