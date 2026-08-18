import Foundation
import PDFKit
import AppKit
import CryptoKit

// MARK: - Provenance / verification (URL + persisted tasks)

enum ManualVerificationStatus: String, Codable, CaseIterable, Identifiable {
    case unverified
    case userAccepted = "user_accepted"
    case rejected

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unverified: return "Unverified"
        case .userAccepted: return "User accepted"
        case .rejected: return "Rejected"
        }
    }
}

/// Corpus-level + manual identity facts from fetched pages (never invent).
struct ManualSourceProvenance: Codable, Equatable {
    var originalURL: String
    var retrievedAtISO: String
    var manualTitle: String
    var publicationNumber: String
    var model: String
    var serialNumberApplicability: String
    var contentChecksumSHA256: String
    var fetchedPageURLs: [String]

    init(
        originalURL: String = "",
        retrievedAtISO: String = "",
        manualTitle: String = "",
        publicationNumber: String = "",
        model: String = "",
        serialNumberApplicability: String = "",
        contentChecksumSHA256: String = "",
        fetchedPageURLs: [String] = []
    ) {
        self.originalURL = originalURL
        self.retrievedAtISO = retrievedAtISO
        self.manualTitle = manualTitle
        self.publicationNumber = publicationNumber
        self.model = model
        self.serialNumberApplicability = serialNumberApplicability
        self.contentChecksumSHA256 = contentChecksumSHA256
        self.fetchedPageURLs = fetchedPageURLs
    }

    enum CodingKeys: String, CodingKey {
        case originalURL, retrievedAtISO, manualTitle, publicationNumber
        case model, serialNumberApplicability, contentChecksumSHA256, fetchedPageURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalURL = try c.decodeIfPresent(String.self, forKey: .originalURL) ?? ""
        retrievedAtISO = try c.decodeIfPresent(String.self, forKey: .retrievedAtISO) ?? ""
        manualTitle = try c.decodeIfPresent(String.self, forKey: .manualTitle) ?? ""
        publicationNumber = try c.decodeIfPresent(String.self, forKey: .publicationNumber) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        serialNumberApplicability = try c.decodeIfPresent(String.self, forKey: .serialNumberApplicability) ?? ""
        contentChecksumSHA256 = try c.decodeIfPresent(String.self, forKey: .contentChecksumSHA256) ?? ""
        fetchedPageURLs = try c.decodeIfPresent([String].self, forKey: .fetchedPageURLs) ?? []
    }
}

/// Source facts extracted from manual text (verbatim / labeled). Separate from AI inference.
struct ManualSourceFacts: Codable, Equatable {
    var maintenanceInterval: String
    var fluids: [String]
    var capacities: [String]
    var filters: [String]
    var parts: [String]
    var safetyWarnings: [String]
    var sourceExcerpt: String
    var sectionSourceURLs: [String]

    init(
        maintenanceInterval: String = "",
        fluids: [String] = [],
        capacities: [String] = [],
        filters: [String] = [],
        parts: [String] = [],
        safetyWarnings: [String] = [],
        sourceExcerpt: String = "",
        sectionSourceURLs: [String] = []
    ) {
        self.maintenanceInterval = maintenanceInterval
        self.fluids = fluids
        self.capacities = capacities
        self.filters = filters
        self.parts = parts
        self.safetyWarnings = safetyWarnings
        self.sourceExcerpt = sourceExcerpt
        self.sectionSourceURLs = sectionSourceURLs
    }

    enum CodingKeys: String, CodingKey {
        case maintenanceInterval, fluids, capacities, filters, parts
        case safetyWarnings, sourceExcerpt, sectionSourceURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maintenanceInterval = try c.decodeIfPresent(String.self, forKey: .maintenanceInterval) ?? ""
        fluids = try c.decodeIfPresent([String].self, forKey: .fluids) ?? []
        capacities = try c.decodeIfPresent([String].self, forKey: .capacities) ?? []
        filters = try c.decodeIfPresent([String].self, forKey: .filters) ?? []
        parts = try c.decodeIfPresent([String].self, forKey: .parts) ?? []
        safetyWarnings = try c.decodeIfPresent([String].self, forKey: .safetyWarnings) ?? []
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? ""
        sectionSourceURLs = try c.decodeIfPresent([String].self, forKey: .sectionSourceURLs) ?? []
    }
}

/// Persisted with each URL-imported (or provenance-bearing) maintenance task.
struct ManualURLImportRecord: Codable, Equatable {
    var provenance: ManualSourceProvenance
    var sourceFacts: ManualSourceFacts
    var inferredNotes: String
    var confidence: Double
    var verificationStatus: ManualVerificationStatus

    init(
        provenance: ManualSourceProvenance = ManualSourceProvenance(),
        sourceFacts: ManualSourceFacts = ManualSourceFacts(),
        inferredNotes: String = "",
        confidence: Double = 0,
        verificationStatus: ManualVerificationStatus = .unverified
    ) {
        self.provenance = provenance
        self.sourceFacts = sourceFacts
        self.inferredNotes = inferredNotes
        self.confidence = confidence
        self.verificationStatus = verificationStatus
    }

    enum CodingKeys: String, CodingKey {
        case provenance, sourceFacts, inferredNotes, confidence, verificationStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provenance = try c.decodeIfPresent(ManualSourceProvenance.self, forKey: .provenance) ?? ManualSourceProvenance()
        sourceFacts = try c.decodeIfPresent(ManualSourceFacts.self, forKey: .sourceFacts) ?? ManualSourceFacts()
        inferredNotes = try c.decodeIfPresent(String.self, forKey: .inferredNotes) ?? ""
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        verificationStatus = try c.decodeIfPresent(ManualVerificationStatus.self, forKey: .verificationStatus) ?? .unverified
    }

    var hasContent: Bool {
        !provenance.originalURL.isEmpty
            || !provenance.contentChecksumSHA256.isEmpty
            || !sourceFacts.sourceExcerpt.isEmpty
            || !inferredNotes.isEmpty
    }
}

enum ManualImportChecksum {
    static func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func clipExcerpt(_ text: String, max: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max))
    }
}

struct ToolRequirement: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var size: String
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        size: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, size, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

func parseMeterInterval(from raw: String) -> (Double?, String?) {
    let lower = raw.lowercased()
    let pattern = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|miles?|mi|cycles?)"#
    guard let match = lower.range(of: pattern, options: .regularExpression) else { return (nil, nil) }
    let snippet = String(lower[match])
    let parts = snippet.split(whereSeparator: { !$0.isNumber && $0 != "." }).joined(separator: " ").split(separator: " ")
    guard let first = parts.first, let value = Double(first) else { return (nil, nil) }
    if snippet.contains("mile") || snippet.contains(" mi") { return (value, "mi") }
    if snippet.contains("cycle") { return (value, "cycles") }
    return (value, "hrs")
}

struct ManualImportDraft: Identifiable, Equatable {
    let id = UUID()
    var selected: Bool = true
    var area: String
    var item: String
    var category: String
    var frequency: TaskFrequency
    var warningDays: Int
    var criticalDays: Int
    var estimatedMinutes: Int
    var taskDescription: String
    var responseInstructions: String
    var suppliesNeeded: String
    var notes: String
    var manufacturer: String
    var sourceManualName: String
    var partNumbers: [String]
    var referenceURLs: [String]
    var toolsRequired: [ToolRequirement]
    /// Corpus + manual identity provenance (URL imports).
    var provenance: ManualSourceProvenance = ManualSourceProvenance()
    /// Verbatim / labeled source facts (not AI inference).
    var sourceFacts: ManualSourceFacts = ManualSourceFacts()
    /// AI-only notes; never mix unlabeled with sourceExcerpt.
    var inferredNotes: String = ""
    var confidence: Double = 0
    var verificationStatus: ManualVerificationStatus = .unverified
    var meterIntervalValue: Double? = nil
    var meterIntervalUnit: String? = nil

    func asMaintenanceTask(
        lastDone: Date = Date(),
        verificationStatus: ManualVerificationStatus? = nil
    ) -> MaintenanceTask {
        let nextDue = Calendar.current.date(
            byAdding: .day,
            value: warningDays,
            to: lastDone
        ) ?? lastDone

        let mappedParts: [PartRequirement] = {
            if !partNumbers.isEmpty || !referenceURLs.isEmpty {
                return PartRequirement.migrated(fromPartNumbers: partNumbers, urls: referenceURLs)
            }
            return []
        }()

        let status = verificationStatus ?? self.verificationStatus
        let hasURLProvenance = !provenance.originalURL.isEmpty || !provenance.contentChecksumSHA256.isEmpty
        let record: ManualURLImportRecord? = hasURLProvenance
            ? ManualURLImportRecord(
                provenance: provenance,
                sourceFacts: sourceFacts,
                inferredNotes: inferredNotes,
                confidence: confidence,
                verificationStatus: status
            )
            : nil

        var combinedNotes = notes
        if !inferredNotes.isEmpty {
            let block = "AI inference:\n\(inferredNotes)"
            combinedNotes = combinedNotes.isEmpty ? block : combinedNotes + "\n\n" + block
        }

        var parsedValue = meterIntervalValue
        var parsedUnit = meterIntervalUnit
        if parsedValue == nil {
            let parsed = parseMeterInterval(from: sourceFacts.maintenanceInterval)
            parsedValue = parsed.0
            parsedUnit = parsed.1
        }
        let scheduleKind = parsedValue != nil ? "meter" : "calendar"
        return MaintenanceTask(
            area: area,
            item: item,
            category: category,
            priority: .medium,
            frequency: frequency,
            taskDescription: taskDescription,
            responseInstructions: responseInstructions,
            suppliesNeeded: suppliesNeeded,
            notes: combinedNotes,
            estimatedMinutes: estimatedMinutes,
            warningDays: warningDays,
            criticalDays: criticalDays,
            lastDone: lastDone,
            nextDue: nextDue,
            manufacturer: manufacturer,
            sourceManualName: sourceManualName,
            origin: .manufacturer,
            partNumbers: partNumbers,
            referenceURLs: referenceURLs,
            toolsRequired: toolsRequired,
            parts: mappedParts,
            manualImport: record,
            scheduleKind: scheduleKind,
            meterIntervalValue: parsedValue.map { Decimal($0) },
            meterIntervalUnit: parsedUnit
        )
    }
}

enum ManualImportError: LocalizedError {
    case noText
    case ollamaUnreachable(String)
    case badJSON(String)
    case emptyTasks
    case invalidURL(String)
    case fetchFailed(String)
    case notHTML(String)
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "Could not extract usable text from that source."
        case .ollamaUnreachable(let detail):
            return "Local Ollama is unreachable. \(detail)"
        case .badJSON(let detail):
            return "Model returned unusable JSON. \(detail)"
        case .emptyTasks:
            return "No maintenance tasks were found in the manual. For manufacturer TOC URLs, try a Maintenance Intervals / Engine Maintenance section page if this persists."
        case .invalidURL(let detail):
            return "Invalid manual URL. \(detail)"
        case .fetchFailed(let detail):
            return "Could not fetch that URL. \(detail)"
        case .notHTML(let detail):
            return "URL did not return HTML. \(detail)"
        case .responseTooLarge(let bytes):
            return "Page is too large to import (\(bytes) bytes)."
        }
    }
}

enum PDFManualTextExtractor {
    static func extractText(from url: URL, maxCharacters: Int = 90_000) -> String {
        guard let document = PDFDocument(url: url) else {
            return ""
        }

        var parts: [String] = []
        var total = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                continue
            }

            let pageText = page.string ?? ""
            if pageText.isEmpty {
                continue
            }

            parts.append("----- page \(index + 1) -----\n\(pageText)")
            total += pageText.count
            if total >= maxCharacters {
                break
            }
        }

        var text = parts.joined(separator: "\n\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - URL HTML fetch (bounded; no full-manual archive)

enum URLManualFetcher {
    static let maxResponseBytes = 1_500_000
    /// Enough room for interval charts + engine/lubrication pages without flooding safety TOC entries.
    static let maxSectionPages = 20
    static let maxTotalCharacters = 90_000
    static let requestTimeout: TimeInterval = 45

    struct FetchedPage {
        let url: URL
        let html: String
        let text: String
    }

    struct HarvestedLink: Hashable {
        let title: String
        let url: URL
        /// Nearest TOC section heading (e.g. "220 - Engine Maintenance"), when known.
        let sectionTitle: String

        init(title: String, url: URL, sectionTitle: String = "") {
            self.title = title
            self.url = url
            self.sectionTitle = sectionTitle
        }
    }

    static func fetchPage(from url: URL) async throws -> FetchedPage {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ManualImportError.invalidURL("Only http/https URLs are supported.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "PropertyManagerApp/1.0 (local manufacturer manual import)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ManualImportError.fetchFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ManualImportError.fetchFailed("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ManualImportError.fetchFailed("HTTP \(http.statusCode)")
        }
        if data.count > maxResponseBytes {
            throw ManualImportError.responseTooLarge(data.count)
        }

        let mime = (http.mimeType ?? "").lowercased()
        let finalURL = http.url ?? url
        let looksHTML = mime.contains("html")
            || mime.isEmpty
            || finalURL.path.lowercased().hasSuffix(".html")
            || finalURL.path.lowercased().hasSuffix(".htm")
        guard looksHTML else {
            throw ManualImportError.notHTML(mime.isEmpty ? "unknown type" : mime)
        }

        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw ManualImportError.fetchFailed("Could not decode page text.")
        }

        return FetchedPage(url: finalURL, html: html, text: htmlToText(html))
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        let patterns = [
            #"(?is)<script[^>]*>.*?</script>"#,
            #"(?is)<style[^>]*>.*?</style>"#,
            #"(?is)<noscript[^>]*>.*?</noscript>"#,
            #"(?is)<!--.*?-->"#
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Preserve service-interval table structure for LLM extraction.
        s = s.replacingOccurrences(of: #"(?is)</td>"#, with: " | ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</th>"#, with: " | ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</tr>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</p>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)</(div|li|h[1-6]|table|thead|tbody)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)

        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "-"), ("&ndash;", "-"), ("&bull;", "*"),
            ("&middot;", "*"), ("&hellip;", "..."), ("&times;", "x")
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Decode simple numeric entities (e.g. &#8212;) instead of blanking them.
        if let numRegex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let ns = s as NSString
            let matches = numRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            var mutable = s
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let full = Range(match.range, in: mutable),
                      let numRange = Range(match.range(at: 1), in: mutable),
                      let code = UInt32(mutable[numRange]),
                      let scalar = UnicodeScalar(code) else { continue }
                mutable.replaceSubrange(full, with: String(Character(scalar)))
            }
            s = mutable
        }
        s = s.replacingOccurrences(of: #"&[a-zA-Z]+;"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t\f\r]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^(?:\s*\|\s*)+$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveURL(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:") || lower.hasPrefix("#") {
            return nil
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    static func harvestTOCLinks(from html: String, baseURL: URL) -> [HarvestedLink] {
        // Walk TOC in document order so each link inherits the nearest <h3 class="section">.
        let sectionPattern = #"(?is)<h3\s+[^>]*class\s*=\s*["']section["'][^>]*>\s*([^<]+)"#
        let linkPattern = #"(?is)<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let sectionRegex = try? NSRegularExpression(pattern: sectionPattern),
              let linkRegex = try? NSRegularExpression(pattern: linkPattern) else {
            return []
        }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Marker {
            let location: Int
            let isSection: Bool
            let sectionTitle: String
            let href: String
            let rawTitle: String
        }

        var markers: [Marker] = []
        for match in sectionRegex.matches(in: html, range: full) {
            guard match.numberOfRanges >= 2,
                  let titleRange = Range(match.range(at: 1), in: html) else { continue }
            let title = htmlToText(String(html[titleRange]))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            markers.append(Marker(
                location: match.range.location,
                isSection: true,
                sectionTitle: title,
                href: "",
                rawTitle: ""
            ))
        }
        for match in linkRegex.matches(in: html, range: full) {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            markers.append(Marker(
                location: match.range.location,
                isSection: false,
                sectionTitle: "",
                href: String(html[hrefRange]),
                rawTitle: String(html[titleRange])
            ))
        }
        markers.sort { $0.location < $1.location }

        var seen = Set<String>()
        var links: [HarvestedLink] = []
        var currentSection = ""

        for marker in markers {
            if marker.isSection {
                currentSection = marker.sectionTitle
                continue
            }
            guard let absolute = resolveURL(marker.href, against: baseURL) else { continue }
            guard let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                continue
            }
            let pathLower = absolute.path.lowercased()
            if pathLower.hasSuffix(".css") || pathLower.hasSuffix(".js")
                || pathLower.hasSuffix(".gif") || pathLower.hasSuffix(".png")
                || pathLower.hasSuffix(".jpg") || pathLower.hasSuffix(".jpeg")
                || pathLower.hasSuffix(".svg") || pathLower.hasSuffix(".ico") {
                continue
            }
            let key = absolute.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)

            let rawTitle = htmlToText(marker.rawTitle)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty
                ? (absolute.lastPathComponent.isEmpty ? key : absolute.lastPathComponent)
                : rawTitle
            links.append(
                HarvestedLink(
                    title: String(title.prefix(160)),
                    url: absolute,
                    sectionTitle: String(currentSection.prefix(160))
                )
            )
        }
        return links
    }

    /// Rank TOC entries for maintenance extraction. High scores = interval charts,
    /// engine/lubrication/service pages. Safety/operation TOC noise scores near zero or negative.
    static func maintenanceRelevanceScore(for link: HarvestedLink) -> Int {
        let title = link.title.lowercased()
        let section = link.sectionTitle.lowercased()
        let hay = title + " " + section + " " + link.url.path.lowercased()

        // Pure safety / operation chapters crowd Deere TOCs and yield empty schedules.
        let safetySection = section.contains("safety") && !section.contains("maintenance")
        if safetySection || title.contains("safely") || title.hasPrefix("recognize safety")
            || title.hasPrefix("understand signal") || title.hasPrefix("follow safety") {
            return -100
        }
        if section.contains("operation") && !section.contains("maintenance")
            && !title.contains("maintenance") && !title.contains("service")
            && !title.contains("lubric") && !title.contains("oil") && !title.contains("filter") {
            return -40
        }
        if section.contains("troubleshooting") || section.contains("specification")
            || section.contains("identification") || section.contains("warranty")
            || section.contains("certification") {
            return -20
        }

        var score = 0

        if section.contains("maintenance interval") || section.contains("periodic maintenance") {
            score += 120
        } else if section.contains("engine maintenance") {
            score += 110
        } else if section.contains("lubricant") || section.contains("fuel, lubricants") {
            score += 95
        } else if section.contains("service record") {
            score += 90
        } else if section.contains("maintenance") {
            score += 70
        } else if section.contains("service") {
            score += 25
        }

        let titleBoosts: [(String, Int)] = [
            ("maintenance interval chart", 130),
            ("maintenance interval", 120),
            ("service your machine", 110),
            ("periodic maintenance", 100),
            ("change engine oil", 95),
            ("check engine oil", 85),
            ("engine oil", 75),
            ("engine maintenance", 90),
            ("lubricate", 70),
            ("lubricant", 65),
            ("replace fuel filter", 70),
            ("air filter", 65),
            ("fuel filter", 65),
            ("oil and filter", 80),
            ("transmission oil", 70),
            ("hydraulic oil", 65),
            ("service records", 70),
            ("hour service", 75),
            ("every ", 40),
            ("as required", 45),
            ("as needed", 40),
            ("grease", 50),
            ("coolant", 45),
            ("schedule", 55),
            ("interval", 50),
            ("maintenance", 45),
            ("service", 20),
            ("filter", 25),
            ("oil", 20),
            ("inspect", 15),
            ("torque", 15)
        ]
        for (needle, boost) in titleBoosts where title.contains(needle) {
            score += boost
        }

        if section.contains("service record") && (title.contains("hour") || title.contains("daily") || title.contains("needed")) {
            score += 40
        }

        if title == section || hay.contains("general information") {
            score -= 15
        }

        // Deere TOC includes bodywork/paint pages under Service that drown interval charts.
        if title.contains("plastic") || title.contains("painted") || title.contains("paint")
            || title.contains("metal surfaces") || title.contains("avoid damage to plastic") {
            score -= 80
        }

        return score
    }

    static func rankedMaintenanceLinks(
        from candidates: [HarvestedLink],
        limit: Int,
        minimumScore: Int = 40
    ) -> [HarvestedLink] {
        let scored = candidates
            .map { ($0, maintenanceRelevanceScore(for: $0)) }
            .filter { $0.1 >= minimumScore }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
        var seen = Set<String>()
        var out: [HarvestedLink] = []
        for (link, _) in scored {
            let key = link.url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(link)
            if out.count >= limit { break }
        }
        return out
    }

    static func sourceManualName(for url: URL, titleHint: String? = nil) -> String {
        let host = url.host ?? "manual"
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let shortPath: String = {
            if path.isEmpty { return "" }
            let parts = path.split(separator: "/").map(String.init)
            if parts.count <= 2 {
                return parts.joined(separator: "/")
            }
            return parts.suffix(2).joined(separator: "/")
        }()
        if let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            let shortTitle = String(hint.prefix(60))
            return shortPath.isEmpty ? "\(host) — \(shortTitle)" : "\(host)/\(shortPath) — \(shortTitle)"
        }
        return shortPath.isEmpty ? host : "\(host)/\(shortPath)"
    }
}

enum URLManualImporter {
    static let maxSectionPages = URLManualFetcher.maxSectionPages
    static let maxTotalCharacters = URLManualFetcher.maxTotalCharacters
    static let maxExcerptCharacters = 400

    struct TOCSection: Decodable {
        var title: String?
        var url: String?
    }

    struct TOCPayload: Decodable {
        var sections: [TOCSection]?
    }

    static func importDrafts(from urlString: String) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startURL = URL(string: trimmed), startURL.scheme != nil else {
            throw ManualImportError.invalidURL("Paste a full http(s) manufacturer manual page URL.")
        }
        return try await importDrafts(from: startURL)
    }

    static func importDrafts(from startURL: URL) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let retrievedAtISO = ManualImportChecksum.isoNow()
        let root = try await URLManualFetcher.fetchPage(from: startURL)
        let harvested = URLManualFetcher.harvestTOCLinks(from: root.html, baseURL: root.url)
        let looksLikeTOC = root.url.path.lowercased().contains("toc")
            || root.url.lastPathComponent.lowercased().contains("toc")
            || harvested.count >= 8

        var sectionURLs: [URL] = []
        if looksLikeTOC {
            sectionURLs = try await selectTOCSections(
                pageURL: root.url,
                pageText: root.text,
                candidates: harvested
            )
        }

        if sectionURLs.isEmpty {
            sectionURLs = [root.url]
        }

        var unique: [URL] = []
        var seen = Set<String>()
        for url in sectionURLs {
            let key = url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(url)
            if unique.count >= maxSectionPages { break }
        }

        var chunks: [String] = []
        var total = 0
        var fetchedURLs: [String] = []

        // TOC pages are mostly nav; keep a short excerpt for metadata only so
        // maintenance/engine content pages fill the corpus budget.
        if unique.count > 1, !root.text.isEmpty {
            let tocExcerpt = String(root.text.prefix(2_500))
            let labeled = "----- source: \(root.url.absoluteString) -----\n\(tocExcerpt)"
            chunks.append(labeled)
            total += labeled.count
            fetchedURLs.append(root.url.absoluteString)
        }

        for url in unique {
            if total >= maxTotalCharacters { break }
            let page: URLManualFetcher.FetchedPage
            if url.absoluteString == root.url.absoluteString {
                page = root
            } else {
                do {
                    page = try await URLManualFetcher.fetchPage(from: url)
                } catch {
                    continue
                }
            }
            guard !page.text.isEmpty else { continue }
            if unique.count == 1 || url.absoluteString != root.url.absoluteString {
                var labeled = "----- source: \(page.url.absoluteString) -----\n\(page.text)"
                let remaining = maxTotalCharacters - total
                if labeled.count > remaining {
                    labeled = String(labeled.prefix(remaining))
                }
                chunks.append(labeled)
                total += labeled.count
                fetchedURLs.append(page.url.absoluteString)
            }
        }

        let combined = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw ManualImportError.noText
        }

        // Hash fetched corpus BEFORE Ollama for later site-change detection.
        let checksum = ManualImportChecksum.sha256Hex(of: combined)
        let allowedURLs = Set(fetchedURLs + [root.url.absoluteString])

        var provenance = ManualSourceProvenance(
            originalURL: root.url.absoluteString,
            retrievedAtISO: retrievedAtISO,
            contentChecksumSHA256: checksum,
            fetchedPageURLs: fetchedURLs
        )

        let payload = try await askOllamaURLImport(
            corpusName: URLManualFetcher.sourceManualName(for: root.url),
            corpusText: combined,
            allowedURLs: Array(allowedURLs).sorted()
        )

        let manufacturer = (payload.manufacturer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let equipment = (payload.equipment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.manualTitle = (payload.manualTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.publicationNumber = (payload.publicationNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.model = (payload.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        provenance.serialNumberApplicability = (payload.serialNumberApplicability ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let titleHint = provenance.manualTitle.isEmpty ? provenance.publicationNumber : provenance.manualTitle
        let manualName = URLManualFetcher.sourceManualName(for: root.url, titleHint: titleHint)

        var drafts: [ManualImportDraft] = []
        for task in payload.tasks ?? [] {
            let equipmentName = nonEmpty(equipment) ?? "Equipment"
            let subsystem = nonEmpty(task.area)
            let area = equipmentName
            var item = nonEmpty(task.item) ?? "Maintenance item"
            if let subsystem, subsystem.caseInsensitiveCompare(equipmentName) != .orderedSame,
               !item.localizedCaseInsensitiveContains(subsystem) {
                item = "\(subsystem): \(item)"
            }
            item = TaskTitle.canonicalItem(assetName: area, title: item)
            let warning = max(task.warningDays ?? 30, 1)
            let critical = max(task.criticalDays ?? max(warning * 2, warning + 7), warning)

            let facts = task.sourceFacts
            let toolsFromFacts = (facts?.tools ?? []).map {
                ToolRequirement(name: $0.name ?? "Tool", size: $0.size ?? "", notes: $0.notes ?? "")
            }.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            let toolsFromTop = (task.toolsRequired ?? []).map {
                ToolRequirement(name: $0.name ?? "Tool", size: $0.size ?? "", notes: $0.notes ?? "")
            }.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            let tools = toolsFromFacts.isEmpty ? toolsFromTop : toolsFromFacts

            var sectionURLsForTask = (facts?.sectionSourceURLs ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if let single = nonEmpty(task.sectionSourceURL) ?? nonEmpty(facts?.sectionSourceURL) {
                if !sectionURLsForTask.contains(single) {
                    sectionURLsForTask.insert(single, at: 0)
                }
            }
            sectionURLsForTask = sectionURLsForTask.filter {
                allowedURLs.contains($0) || $0.lowercased().hasPrefix("http")
            }
            if sectionURLsForTask.isEmpty {
                sectionURLsForTask = [root.url.absoluteString]
            }

            var refs = (task.referenceURLs ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            for u in sectionURLsForTask where !refs.contains(u) {
                refs.append(u)
            }

            let partNumbers = uniqueStrings((facts?.parts ?? []) + (task.partNumbers ?? []))
            let excerpt = ManualImportChecksum.clipExcerpt(
                facts?.sourceExcerpt ?? task.sourceExcerpt ?? "",
                max: maxExcerptCharacters
            )

            let sourceFacts = ManualSourceFacts(
                maintenanceInterval: (facts?.maintenanceInterval ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                fluids: cleanList(facts?.fluids),
                capacities: cleanList(facts?.capacities),
                filters: cleanList(facts?.filters),
                parts: cleanList(facts?.parts ?? task.partNumbers),
                safetyWarnings: cleanList(facts?.safetyWarnings),
                sourceExcerpt: excerpt,
                sectionSourceURLs: sectionURLsForTask
            )

            let inferred = (task.inferredNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = min(max(task.confidence ?? 0.5, 0), 1)

            var noteBits: [String] = []
            if !sourceFacts.maintenanceInterval.isEmpty {
                noteBits.append("Interval (source): \(sourceFacts.maintenanceInterval)")
            }
            noteBits.append("Source: \(manualName)")
            if !provenance.retrievedAtISO.isEmpty {
                noteBits.append("Retrieved: \(provenance.retrievedAtISO)")
            }

            drafts.append(
                ManualImportDraft(
                    area: area,
                    item: item,
                    category: category(from: task.category, area: area),
                    frequency: frequency(from: task.frequency, warningDays: warning),
                    warningDays: warning,
                    criticalDays: critical,
                    estimatedMinutes: max(task.estimatedMinutes ?? 30, 5),
                    taskDescription: nonEmpty(task.taskDescription) ?? item,
                    responseInstructions: nonEmpty(task.responseInstructions)
                        ?? "Follow the manufacturer procedure at \(sectionURLsForTask.first ?? manualName).",
                    suppliesNeeded: labeledSupplies(facts: sourceFacts, fallback: task.suppliesNeeded ?? ""),
                    notes: noteBits.joined(separator: "\n"),
                    manufacturer: manufacturer,
                    sourceManualName: manualName,
                    partNumbers: partNumbers,
                    referenceURLs: refs,
                    toolsRequired: tools,
                    provenance: provenance,
                    sourceFacts: sourceFacts,
                    inferredNotes: inferred,
                    confidence: confidence,
                    verificationStatus: .unverified
                )
            )
        }

        guard !drafts.isEmpty else {
            throw ManualImportError.emptyTasks
        }

        return (manufacturer, drafts)
    }

    private static func cleanList(_ values: [String]?) -> [String] {
        (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }

    private static func labeledSupplies(facts: ManualSourceFacts, fallback: String) -> String {
        var lines: [String] = []
        if !facts.fluids.isEmpty { lines.append("Fluids: \(facts.fluids.joined(separator: "; "))") }
        if !facts.capacities.isEmpty { lines.append("Capacities: \(facts.capacities.joined(separator: "; "))") }
        if !facts.filters.isEmpty { lines.append("Filters: \(facts.filters.joined(separator: "; "))") }
        if !facts.parts.isEmpty { lines.append("Parts: \(facts.parts.joined(separator: "; "))") }
        if lines.isEmpty {
            return fallback
        }
        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(fallback)
        }
        return lines.joined(separator: "\n")
    }

    private static func askOllamaURLImport(
        corpusName: String,
        corpusText: String,
        allowedURLs: [String]
    ) async throws -> URLManualLLMPayload {
        let system = """
        You extract manufacturer-recommended maintenance schedules from bounded manual web pages.
        Return ONLY a JSON object with keys manufacturer, equipment, manualTitle, publicationNumber, model, serialNumberApplicability, and tasks (array).
        Each task must include: area, item, category, frequency, warningDays, criticalDays, estimatedMinutes, taskDescription, responseInstructions, suppliesNeeded, partNumbers, referenceURLs, sectionSourceURL, toolsRequired, sourceFacts, inferredNotes, confidence.
        sourceFacts must include: maintenanceInterval, fluids, capacities, filters, parts, tools, safetyWarnings, sourceExcerpt, sectionSourceURLs.
        Rules:
        - Separate source facts from AI inference. Never mix unlabeled.
        - sourceFacts.* and sourceExcerpt must be supported by the labeled corpus. Empty string/array if unknown.
        - Do NOT invent publication numbers, models, serial ranges, part numbers, or URLs.
        - referenceURLs / sectionSourceURL must be real URLs appearing after "----- source:" lines.
        - Allowed URLs: \(allowedURLs.joined(separator: ", "))
        - confidence is 0.0-1.0 reflecting how clearly the source supports the task.
        - Include only maintenance/inspection/service tasks the manufacturer recommends.
        - Prefer concrete intervals; approximate warningDays when converting hours/months (daily=1, weekly=7, 50 hours~7, 200 hours~30, 400 hours~60, 600 hours~90, yearly=365).
        - CRITICAL: Extract EVERY row from Maintenance Interval Chart / service interval tables as its own task. Pipe-separated table rows list Item then interval columns marked with *.
        - Prioritize pages whose URL/path or heading contains "Interval Chart", "Engine Oil", "Hour Service", or "Service Your Machine".
        - Prefer chart/service-record interval items over low-level procedure steps (do not turn "remove dipstick" or "clean plastic" into schedule tasks).
        - Never return instructions[], steps[], or any schema other than the tasks object above.
        - If interval charts are present, tasks MUST come primarily from those chart rows (Check engine oil level, Replace fuel filter, etc.), not bodywork/paint pages.
        """

        let user = """
        Corpus name: \(corpusName)

        Manual corpus (labeled sources):
        \(corpusText)
        """

        let content = try await ManufacturerManualImporter.chatJSON(
            system: system,
            user: user,
            jsonSchema: ManufacturerManualImporter.urlImportJSONSchema
        )
        guard let data = content.data(using: .utf8) else {
            throw ManualImportError.badJSON("empty content")
        }
        // Guard against models that emit valid JSON but wrong shape (e.g. {"instructions":[...]}).
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hasTasksKey = root.keys.contains("tasks")
            let taskCount = (root["tasks"] as? [Any])?.count ?? 0
            if !hasTasksKey || taskCount == 0 {
                throw ManualImportError.badJSON(
                    "Ollama returned JSON without tasks (keys: \(root.keys.sorted().joined(separator: ", "))). Preview: \(String(content.prefix(300)))"
                )
            }
        }
        do {
            return try JSONDecoder().decode(URLManualLLMPayload.self, from: data)
        } catch {
            throw ManualImportError.badJSON(error.localizedDescription + " / " + String(content.prefix(400)))
        }
    }

    private static func selectTOCSections(
        pageURL: URL,
        pageText: String,
        candidates: [URLManualFetcher.HarvestedLink]
    ) async throws -> [URL] {
        // Deterministic ranking first — Deere-style TOCs bury Engine Maintenance /
        // interval charts after dozens of Safety links; first-N / loose keyword
        // matching previously filled the page budget with safety pages and empty tasks.
        var ranked = URLManualFetcher.rankedMaintenanceLinks(
            from: candidates,
            limit: maxSectionPages,
            minimumScore: 40
        )
        // When interval-chart / engine-oil pages are present, drop weak filler
        // (paint, generic service) so Ollama cannot ignore the schedule tables.
        let strong = ranked.filter { URLManualFetcher.maintenanceRelevanceScore(for: $0) >= 180 }
        if strong.count >= 3 {
            ranked = Array(strong.prefix(maxSectionPages))
        }
        if ranked.count >= 4 {
            return ranked.map(\.url)
        }

        let candidatePool = ranked.isEmpty
            ? Array(candidates.prefix(100))
            : ranked + Array(candidates.prefix(40))
        var seenPool = Set<String>()
        let uniquePool = candidatePool.filter {
            let key = $0.url.absoluteString
            if seenPool.contains(key) { return false }
            seenPool.insert(key)
            return true
        }

        let candidateLines = uniquePool.prefix(100).map { link -> String in
            let section = link.sectionTitle.isEmpty ? "" : " [\(link.sectionTitle)]"
            return "- \(link.title)\(section) | \(link.url.absoluteString)"
        }.joined(separator: "\n")

        let system = """
        You select maintenance-relevant sections from a manufacturer manual table of contents page.
        Return ONLY valid JSON:
        {
          "sections": [
            { "title": "string", "url": "absolute http(s) URL" }
          ]
        }
        Rules:
        - Prefer Maintenance Intervals, Engine Maintenance, Lubrication/Fluids, Filters, Service Records, and Periodic/Hourly service pages.
        - Include concrete procedure pages (oil, filters, lubricate, interval charts) over Safety / Operation chapters.
        - Do NOT fill the list with "...Safely" safety pages unless no maintenance pages exist.
        - Prefer URLs from the candidate list. Do not invent URLs.
        - Return at most \(maxSectionPages) sections.
        - If nothing is maintenance-relevant, return {"sections": []}.
        """

        let user = """
        TOC page URL: \(pageURL.absoluteString)

        Candidate links (maintenance-ranked when available):
        \(candidateLines.isEmpty ? "(none harvested)" : candidateLines)

        TOC page text (excerpt):
        \(String(pageText.prefix(8_000)))
        """

        let content = try await ManufacturerManualImporter.chatJSON(system: system, user: user)
        guard let data = content.data(using: .utf8) else {
            return fallbackTOCURLs(from: candidates)
        }

        let payload: TOCPayload
        do {
            payload = try JSONDecoder().decode(TOCPayload.self, from: data)
        } catch {
            return fallbackTOCURLs(from: candidates)
        }

        var urls: [URL] = []
        var seenLocal = Set<String>()
        let candidateSet = Set(candidates.map { $0.url.absoluteString })

        // Seed with any strong ranked hits so Ollama cannot drop interval/engine pages.
        for link in ranked.prefix(8) {
            let abs = link.url.absoluteString
            if seenLocal.contains(abs) { continue }
            seenLocal.insert(abs)
            urls.append(link.url)
        }

        for section in payload.sections ?? [] {
            guard let raw = section.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let url = URL(string: raw) ?? URLManualFetcher.resolveURL(raw, against: pageURL) else {
                continue
            }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                continue
            }
            let abs = url.absoluteString
            let sameHost = url.host != nil && url.host == pageURL.host
            if !candidateSet.isEmpty && !candidateSet.contains(abs) && !sameHost {
                continue
            }
            if seenLocal.contains(abs) { continue }
            seenLocal.insert(abs)
            urls.append(url)
            if urls.count >= maxSectionPages { break }
        }

        if urls.isEmpty {
            return fallbackTOCURLs(from: candidates)
        }
        return Array(urls.prefix(maxSectionPages))
    }

    private static func fallbackTOCURLs(from candidates: [URLManualFetcher.HarvestedLink]) -> [URL] {
        let ranked = URLManualFetcher.rankedMaintenanceLinks(
            from: candidates,
            limit: maxSectionPages,
            minimumScore: 20
        )
        if !ranked.isEmpty {
            return ranked.map(\.url)
        }
        return Array(candidates.prefix(maxSectionPages)).map(\.url)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func category(from raw: String?, area: String) -> String {
        ManufacturerManualImporter.categoryPublic(from: raw, area: area)
    }

    private static func frequency(from raw: String?, warningDays: Int) -> TaskFrequency {
        ManufacturerManualImporter.frequencyPublic(from: raw, warningDays: warningDays)
    }
}

enum ManufacturerManualImporter {
    static var preferredModel: String {
        ProcessInfo.processInfo.environment["PROPERTYMANAGER_OLLAMA_MODEL"]
            ?? "gemma3:12b"
    }

    static var ollamaBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["PROPERTYMANAGER_OLLAMA_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:11434")!
    }

    static func importDrafts(from pdfURL: URL) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let text = PDFManualTextExtractor.extractText(from: pdfURL)
        guard !text.isEmpty else {
            throw ManualImportError.noText
        }

        return try await extractDrafts(
            manualName: pdfURL.lastPathComponent,
            manualText: text
        )
    }

    static func extractDrafts(
        manualName: String,
        manualText: String,
        extraSystemRules: String = "",
        defaultReferenceURLs: [String] = [],
        maxNotesExcerpt: Int? = nil
    ) async throws -> (manufacturer: String, drafts: [ManualImportDraft]) {
        let payload = try await askOllama(
            manualName: manualName,
            manualText: manualText,
            extraSystemRules: extraSystemRules
        )

        let manufacturer = payload.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let equipment = payload.equipment.trimmingCharacters(in: .whitespacesAndNewlines)

        var drafts: [ManualImportDraft] = []
        for task in payload.tasks {
            let equipmentName = nonEmpty(equipment) ?? "Equipment"
            let subsystem = nonEmpty(task.area)
            let area = equipmentName
            var item = nonEmpty(task.item) ?? "Maintenance item"
            if let subsystem, subsystem.caseInsensitiveCompare(equipmentName) != .orderedSame,
               !item.localizedCaseInsensitiveContains(subsystem) {
                item = "\(subsystem): \(item)"
            }
            item = TaskTitle.canonicalItem(assetName: area, title: item)
            guard let responseInstructions = nonEmpty(task.responseInstructions) else {
                // A manufacturer task must carry usable, source-backed procedure text.
                // Do not create a misleading generic "follow the manual" How-To.
                continue
            }
            let warning = max(task.warningDays ?? 30, 1)
            let critical = max(task.criticalDays ?? max(warning * 2, warning + 7), warning)
            let tools = (task.toolsRequired ?? []).map {
                ToolRequirement(
                    name: $0.name ?? "Tool",
                    size: $0.size ?? "",
                    notes: $0.notes ?? ""
                )
            }.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            var refs = (task.referenceURLs ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if refs.isEmpty {
                refs = defaultReferenceURLs
            }

            var notesBits: [String] = []
            if let notes = nonEmpty(task.notes) {
                if let maxNotesExcerpt, notes.count > maxNotesExcerpt {
                    notesBits.append(String(notes.prefix(maxNotesExcerpt)))
                } else {
                    notesBits.append(notes)
                }
            }
            notesBits.append("Source manual: \(manualName)")
            if !manufacturer.isEmpty {
                notesBits.append("Manufacturer: \(manufacturer)")
            }

            drafts.append(
                ManualImportDraft(
                    area: area,
                    item: item,
                    category: category(from: task.category, area: area),
                    frequency: frequency(from: task.frequency, warningDays: warning),
                    warningDays: warning,
                    criticalDays: critical,
                    estimatedMinutes: max(task.estimatedMinutes ?? 30, 5),
                    taskDescription: nonEmpty(task.taskDescription)
                        ?? item,
                    responseInstructions: responseInstructions,
                    suppliesNeeded: task.suppliesNeeded ?? "",
                    notes: notesBits.joined(separator: "\n"),
                    manufacturer: manufacturer,
                    sourceManualName: manualName,
                    partNumbers: (task.partNumbers ?? []).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty },
                    referenceURLs: refs,
                    toolsRequired: tools
                )
            )
        }

        guard !drafts.isEmpty else {
            throw ManualImportError.emptyTasks
        }

        return (manufacturer, drafts)
    }

    struct HowToFillResult {
        var found: Bool
        var responseInstructions: String
        var manufacturer: String
    }

    static func fillHowTo(
        forTaskArea area: String,
        item: String,
        taskDescription: String,
        from pdfURL: URL
    ) async throws -> HowToFillResult {
        let text = PDFManualTextExtractor.extractText(from: pdfURL)
        guard !text.isEmpty else {
            throw ManualImportError.noText
        }

        let system = """
        You extract the manufacturer maintenance procedure for ONE specific task from an equipment manual.
        Return ONLY valid JSON:
        {
          "found": true,
          "manufacturer": "string",
          "responseInstructions": "numbered how-to steps from the manual for this task only"
        }
        Rules:
        - Set found=true only if the manual clearly covers this maintenance item.
        - If the manual does not cover it, return {"found": false, "manufacturer": "", "responseInstructions": ""}.
        - Do not invent steps that are not supported by the manual.
        - Keep responseInstructions actionable and faithful to the manual.
        """

        let user = """
        Manual file name: \(pdfURL.lastPathComponent)

        Task area: \(area)
        Task item: \(item)
        Task description: \(taskDescription)

        Manual text:
        \(text)
        """

        let content = try await chatJSON(system: system, user: user)
        guard let contentData = content.data(using: .utf8) else {
            throw ManualImportError.badJSON("empty content")
        }
        struct FillPayload: Decodable {
            var found: Bool?
            var manufacturer: String?
            var responseInstructions: String?
        }
        let payload = try JSONDecoder().decode(FillPayload.self, from: contentData)
        let instructions = (payload.responseInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let found = (payload.found ?? false) && !instructions.isEmpty
        return HowToFillResult(
            found: found,
            responseInstructions: instructions,
            manufacturer: (payload.manufacturer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Lean JSON Schema for Ollama `format`. Nested sourceFacts stay prompt-driven
    /// (optional in decode); a heavy required schema made gemma3 truncate mid-JSON.
    static var urlImportJSONSchema: [String: Any] {
        let task: [String: Any] = [
            "type": "object",
            "properties": [
                "area": ["type": "string"],
                "item": ["type": "string"],
                "category": ["type": "string"],
                "frequency": ["type": "string"],
                "warningDays": ["type": "integer"],
                "meterIntervalValue": ["type": "number"],
                "meterIntervalUnit": ["type": "string"],
                "criticalDays": ["type": "integer"],
                "estimatedMinutes": ["type": "integer"],
                "taskDescription": ["type": "string"],
                "responseInstructions": ["type": "string"],
                "suppliesNeeded": ["type": "string"],
                "partNumbers": ["type": "array", "items": ["type": "string"]],
                "referenceURLs": ["type": "array", "items": ["type": "string"]],
                "sectionSourceURL": ["type": "string"],
                "inferredNotes": ["type": "string"],
                "confidence": ["type": "number"],
                "sourceFacts": [
                    "type": "object",
                    "properties": [
                        "maintenanceInterval": ["type": "string"],
                        "fluids": ["type": "array", "items": ["type": "string"]],
                        "capacities": ["type": "array", "items": ["type": "string"]],
                        "filters": ["type": "array", "items": ["type": "string"]],
                        "parts": ["type": "array", "items": ["type": "string"]],
                        "safetyWarnings": ["type": "array", "items": ["type": "string"]],
                        "sourceExcerpt": ["type": "string"],
                        "sectionSourceURLs": ["type": "array", "items": ["type": "string"]]
                    ]
                ]
            ],
            "required": [
                "area", "item", "category", "frequency",
                "warningDays", "criticalDays", "estimatedMinutes",
                "taskDescription", "confidence"
            ]
        ]
        return [
            "type": "object",
            "properties": [
                "manufacturer": ["type": "string"],
                "equipment": ["type": "string"],
                "manualTitle": ["type": "string"],
                "publicationNumber": ["type": "string"],
                "model": ["type": "string"],
                "serialNumberApplicability": ["type": "string"],
                "tasks": ["type": "array", "items": task]
            ],
            "required": ["manufacturer", "equipment", "tasks"]
        ]
    }

    static func chatJSON(system: String, user: String) async throws -> String {
        try await chatJSON(system: system, user: user, jsonSchema: nil)
    }

    static func chatJSON(
        system: String,
        user: String,
        jsonSchema: [String: Any]?
    ) async throws -> String {
        let url = ollamaBaseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": preferredModel,
            "stream": false,
            "format": jsonSchema ?? "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "options": [
                "temperature": 0.1
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ManualImportError.ollamaUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw ManualImportError.ollamaUnreachable(detail)
        }

        struct ChatEnvelope: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }

        let envelope: ChatEnvelope
        do {
            envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        } catch {
            throw ManualImportError.badJSON(error.localizedDescription)
        }

        return envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func categoryPublic(from raw: String?, area: String) -> String {
        category(from: raw, area: area)
    }

    static func frequencyPublic(from raw: String?, warningDays: Int) -> TaskFrequency {
        frequency(from: raw, warningDays: warningDays)
    }

    private static func askOllama(
        manualName: String,
        manualText: String,
        extraSystemRules: String = ""
    ) async throws -> ManualLLMPayload {
        var system = """
        You extract manufacturer-recommended maintenance schedules from equipment manuals.
        Return ONLY valid JSON matching this schema:
        {
          "manufacturer": "string",
          "equipment": "string",
          "tasks": [
            {
              "area": "string",
              "item": "string",
              "category": "Pool|Home|Grounds|Equipment|House|Safety|Property",
              "frequency": "Daily|Weekly|Every 2 Weeks|Monthly|Quarterly|Yearly",
              "warningDays": 30,
              "criticalDays": 45,
              "estimatedMinutes": 30,
              "taskDescription": "string",
              "responseInstructions": "numbered how-to steps from the manual",
              "suppliesNeeded": "string",
              "partNumbers": ["string"],
              "referenceURLs": ["string"],
              "toolsRequired": [{"name":"string","size":"string","notes":"string"}],
              "notes": "page or section references"
            }
          ]
        }
        Rules:
        - Include only maintenance/inspection/service tasks the manufacturer recommends.
        - Capture part numbers, URLs, tool names, and socket/wrench sizes when present.
        - If a size is given (mm, SAE, hex, torx), put it in toolsRequired.size.
        - Prefer concrete intervals. Convert hours/months to warningDays approximately (30 days ~= monthly).
        - Do not invent part numbers or URLs. Use empty arrays when unknown.
        - Keep responseInstructions actionable and faithful to the manual.
        """
        let extra = extraSystemRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            system += "\n" + extra
        }

        let user = """
        Manual file name: \(manualName)

        Manual text:
        \(manualText)
        """

        let content = try await chatJSON(system: system, user: user)
        guard let contentData = content.data(using: .utf8) else {
            throw ManualImportError.badJSON("empty content")
        }

        do {
            return try JSONDecoder().decode(ManualLLMPayload.self, from: contentData)
        } catch {
            throw ManualImportError.badJSON(error.localizedDescription + " / " + String(content.prefix(400)))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func category(from raw: String?, area: String) -> String {
        let text = (raw ?? area).lowercased()
        if text.contains("pool") { return "Pool" }
        if text.contains("hot") || text.contains("tub") || text.contains("spa") { return "Home" }
        if text.contains("fence") || text.contains("gate") || text.contains("property") { return "Property" }
        if text.contains("ground") || text.contains("yard") || text.contains("lawn") {
            return "Grounds"
        }
        if text.contains("safety") || text.contains("fire") { return "Safety" }
        if text.contains("house") || text.contains("home") || text.contains("softener") { return "House" }
        if text.contains("mower") || text.contains("tractor") || text.contains("engine") { return "Equipment" }
        return "Equipment"
    }

    private static func frequency(from raw: String?, warningDays: Int) -> TaskFrequency {
        let text = (raw ?? "").lowercased()
        if text.contains("daily") { return .daily }
        if text.contains("2 week") || text.contains("biweek") || text.contains("every 2") {
            return .biweekly
        }
        if text.contains("week") { return .weekly }
        if text.contains("quarter") { return .quarterly }
        if text.contains("year") || text.contains("annual") { return .yearly }
        if text.contains("month") { return .monthly }

        if warningDays <= 1 { return .daily }
        if warningDays <= 7 { return .weekly }
        if warningDays <= 14 { return .biweekly }
        if warningDays <= 45 { return .monthly }
        if warningDays <= 120 { return .quarterly }
        return .yearly
    }
}

private struct ManualLLMPayload: Decodable {
    struct Tool: Decodable {
        var name: String?
        var size: String?
        var notes: String?
    }

    struct Task: Decodable {
        var area: String?
        var item: String?
        var category: String?
        var frequency: String?
        var warningDays: Int?
        var criticalDays: Int?
        var estimatedMinutes: Int?
        var taskDescription: String?
        var responseInstructions: String?
        var suppliesNeeded: String?
        var partNumbers: [String]?
        var referenceURLs: [String]?
        var toolsRequired: [Tool]?
        var notes: String?
    }

    enum CodingKeys: String, CodingKey {
        case manufacturer, equipment, tasks
    }

    var manufacturer: String
    var equipment: String
    var tasks: [Task]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        equipment = try c.decodeIfPresent(String.self, forKey: .equipment) ?? ""
        tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
    }
}

private struct URLManualLLMPayload: Decodable {
    struct Tool: Decodable {
        var name: String?
        var size: String?
        var notes: String?
    }

    struct SourceFacts: Decodable {
        var maintenanceInterval: String?
        var fluids: [String]?
        var capacities: [String]?
        var filters: [String]?
        var parts: [String]?
        var tools: [Tool]?
        var safetyWarnings: [String]?
        var sourceExcerpt: String?
        var sectionSourceURL: String?
        var sectionSourceURLs: [String]?
    }

    struct Task: Decodable {
        var area: String?
        var item: String?
        var category: String?
        var frequency: String?
        var warningDays: Int?
        var criticalDays: Int?
        var estimatedMinutes: Int?
        var taskDescription: String?
        var responseInstructions: String?
        var suppliesNeeded: String?
        var partNumbers: [String]?
        var referenceURLs: [String]?
        var sectionSourceURL: String?
        var toolsRequired: [Tool]?
        var sourceFacts: SourceFacts?
        var sourceExcerpt: String?
        var inferredNotes: String?
        var confidence: Double?
    }

    var manufacturer: String?
    var equipment: String?
    var manualTitle: String?
    var publicationNumber: String?
    var model: String?
    var serialNumberApplicability: String?
    var tasks: [Task]?
}
