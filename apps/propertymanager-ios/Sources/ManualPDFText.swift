import Foundation
import PDFKit

enum ManualPDFText {
    /// Apple's on-device model shares a ~4K-token window between the prompt,
    /// the schema, and the answer, so sections are much smaller than the Mac's 14K.
    static let onDeviceCharactersPerChunk = 4_000

    static func pageTexts(from pdf: Data) -> [String] {
        guard let document = PDFDocument(data: pdf) else { return [] }
        return (0..<document.pageCount).compactMap { index -> String? in
            guard let page = document.page(at: index), let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "----- page \(index + 1) -----\n\(text)"
        }
    }

    static func extractionChunks(from chunks: [String]) -> [AssetManualExtractionChunk] {
        chunks.map { content in
            AssetManualExtractionChunk(pageNumber: firstPageNumber(in: content), sectionHeading: "Maintenance", content: content)
        }
    }

    static func firstPageNumber(in content: String) -> Int? {
        guard let range = content.range(of: #"----- page ([0-9]+) -----"#, options: .regularExpression) else { return nil }
        return Int(content[range].filter(\.isNumber))
    }

    /// Start at the manufacturer's periodic-maintenance chart when there is one;
    /// otherwise keep pages that read like service procedures. Same selection as the Mac app.
    static func maintenanceChunks(fromPageTexts pages: [String], maxCharactersPerChunk: Int) -> [String] {
        guard maxCharactersPerChunk > 0 else { return [] }
        let normalized = pages.map { $0.lowercased() }
        var selected: [String] = []

        if let start = normalized.firstIndex(where: { $0.contains("periodic maintenance") }) {
            for index in start..<pages.count {
                let leading = normalized[index].trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
                if index > start,
                   leading.contains("specifications") || leading.contains("warranty") || leading.contains("index") {
                    break
                }
                selected.append(pages[index])
            }
        } else {
            // Never fall back to the first pages: they are commonly safety/front matter and omit service.
            selected = zip(pages, normalized).compactMap { page, text in
                maintenancePageScore(text) > 0 ? page : nil
            }
            if selected.isEmpty {
                let fallback = pages.joined(separator: "\n\n")
                selected = fallback.isEmpty ? [] : [String(fallback.prefix(maxCharactersPerChunk))]
            }
        }

        var chunks: [String] = []
        var current = ""
        for page in selected {
            for piece in split(page, maxCharacters: maxCharactersPerChunk) {
                let candidate = current.isEmpty ? piece : current + "\n\n" + piece
                if !current.isEmpty && candidate.count > maxCharactersPerChunk {
                    chunks.append(current)
                    current = piece
                } else {
                    current = candidate
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Long pages are split rather than truncated so no service text is dropped.
    private static func split(_ page: String, maxCharacters: Int) -> [String] {
        guard page.count > maxCharacters else { return [page] }
        var pieces: [String] = []
        var remaining = Substring(page)
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: maxCharacters, limitedBy: remaining.endIndex)
                ?? remaining.endIndex
            if end < remaining.endIndex, let newline = remaining[..<end].lastIndex(of: "\n"),
               remaining.distance(from: remaining.startIndex, to: newline) > maxCharacters / 2 {
                end = newline
            }
            pieces.append(String(remaining[..<end]))
            remaining = remaining[end...].drop(while: { $0 == "\n" })
        }
        return pieces
    }

    private static func maintenancePageScore(_ text: String) -> Int {
        let excludedHeadings = ["specifications", "warranty", "parts list", "schematic diagram"]
        let leading = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220)
        guard !excludedHeadings.contains(where: { leading.contains($0) }) else { return 0 }

        let strongTerms = [
            "change the oil", "oil filter", "engine oil", "belt", "brake", "lubricat",
            "adjusting", "replacing", "replace the", "maintenance", "end of season",
            "storage", "daily checklist", "battery care", "air filter",
        ]
        return strongTerms.reduce(into: 0) { score, term in
            if text.contains(term) { score += 1 }
        }
    }
}
