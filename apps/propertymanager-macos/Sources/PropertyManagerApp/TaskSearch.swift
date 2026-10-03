import Foundation

/// Task list search: every typed word must appear somewhere in the task, in any field and any order.
enum TaskSearch {
    static func words(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func matches(fields: [String], words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = fields.joined(separator: " ")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}
