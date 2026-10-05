import Foundation

enum ManualSourceLink {
    static func url(provenanceURL: String?, displayName: String, instructions: String = "") -> URL? {
        // Imported display labels may omit both the scheme and path components.
        // Prefer the recorded source; never reconstruct a URL from those labels.
        for raw in [provenanceURL ?? "", displayName] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.contains(where: { $0.isWhitespace }),
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { continue }
            return url
        }
        // Some saved tasks retain the full procedure URL only in their how-to text.
        // Use that recorded URL only when it matches the source label's hostname.
        let labelHost = displayName.split(separator: "/").first.map(String.init)?.lowercased()
        guard let labelHost, labelHost.contains("."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: instructions, range: NSRange(instructions.startIndex..., in: instructions))
        for match in matches {
            guard let candidate = match.url,
                  candidate.host?.lowercased() == labelHost,
                  let validated = url(provenanceURL: nil, displayName: candidate.absoluteString) else { continue }
            return validated
        }
        return nil
    }
}
