import CryptoKit
import Foundation

/// CSV ingest for the Finance screen: Apple Card Wallet exports plus generic
/// bank/credit-card statements. Pure functions, no I/O, no network.
/// Display parsing follows the accepted finance-frontend spec:
/// apple-card-csv-v1 headers, five finance_csv_* codes, wrapped-line join,
/// Credit and Interest case-insensitively. Unknown types stay
/// finance_csv_invalid with a generic message — the rejected cell is never
/// printed, because a shifted row can put a merchant or an amount there.
enum RanchOSFinanceCSV {
    // MARK: - Codes (the five approved finance_csv_* codes)

    static let codeInvalid = "finance_csv_invalid"
    static let codeDuplicateRow = "finance_csv_duplicate_row"
    static let codeFutureDate = "finance_csv_future_date"
    static let codeAmountZero = "finance_csv_amount_zero"
    static let codeMissingColumn = "finance_csv_missing_column"

    // MARK: - Apple Card

    static let appleCardHeaders = [
        "Transaction Date", "Clearing Date", "Description", "Merchant",
        "Category", "Type", "Amount (USD)", "Purchased By",
    ]

    /// Matched case-insensitively after trimming.
    static let appleCardTypes = [
        "purchase", "payment", "refund", "adjustment", "fee", "credit", "interest",
    ]

    // MARK: - Generic bank/credit-card statements

    /// A header identifies the column when its trimmed lowercase form is in
    /// the matching set. Small on purpose: unknown layouts stay unrecognized
    /// rather than silently misread.
    static let genericDateHeaders = ["date", "transaction date", "posted date", "posting date", "trans date"]
    static let genericDescriptionHeaders = ["description", "merchant", "memo", "payee", "details", "narrative"]
    static let genericAmountHeaders = ["amount", "amount (usd)", "transaction amount", "value"]

    static let dateFormats = ["M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "MM/dd/yy", "yyyy-MM-dd"]

    enum Kind: String, Sendable {
        case appleCard
        case bank
        case unrecognized
    }

    struct Charge: Sendable {
        var dateText: String
        var merchantText: String
        var amountText: String
        var isDuplicate: Bool
        /// Apple's Category cell for this row. Empty for bank rows, which
        /// have no such column, and for blank cells.
        var categoryText: String = ""
    }

    struct ParseError: Sendable {
        /// 1-based logical data row. 0 means the file itself (headers/encoding).
        var row: Int
        var code: String
        var message: String
    }

    struct ParsedFile: Sendable {
        var kind: Kind
        var sha256Hex: String
        /// Logical data rows (a joined wrapped line counts once).
        var rowCount: Int
        var charges: [Charge]
        var errors: [ParseError]
    }

    // MARK: - Entry point

    static func parse(bytes: Data, now: Date = Date()) -> ParsedFile {
        let digest = SHA256.hash(data: bytes)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        guard var text = String(data: bytes, encoding: .utf8) else {
            return ParsedFile(
                kind: .unrecognized, sha256Hex: sha, rowCount: 0, charges: [],
                errors: [ParseError(row: 0, code: codeInvalid, message: "file is not readable text")])
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let physical = splitPhysicalRecords(text).filter { !$0.allSatisfy(\.isEmpty) }
        guard let headerFields = physical.first, !headerFields.isEmpty else {
            return ParsedFile(
                kind: .unrecognized, sha256Hex: sha, rowCount: 0, charges: [],
                errors: [ParseError(row: 0, code: codeInvalid, message: "file has no header row")])
        }
        let headers = headerFields.map { normalizeHeader($0) }
        let body = Array(physical.dropFirst())
        if isAppleCardAttempt(headers: headers) {
            let rows = joinContinuations(body)
            return parseAppleCard(headers: headers, rows: rows, sha: sha, now: now)
        }
        if let mapping = genericMapping(headers: headers) {
            let rows = joinContinuations(body)
            return parseGeneric(mapping: mapping, rows: rows, sha: sha)
        }
        return ParsedFile(
            kind: .unrecognized, sha256Hex: sha, rowCount: 0, charges: [],
            errors: [ParseError(row: 0, code: codeInvalid, message: "headers not recognized")])
    }

    // MARK: - Record splitting (quotes and commas)

    /// Splits text into physical-line records honoring double quotes
    /// (embedded commas, escaped ""). No joining here.
    static func splitPhysicalRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false

        func endField() {
            current.append(field)
            field = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inQuotes {
                if char == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                    index = text.index(after: index)
                    continue
                }
                field.append(char)
                index = text.index(after: index)
                continue
            }
            if char == "\"" && field.isEmpty {
                inQuotes = true
                index = text.index(after: index)
                continue
            }
            if char == "," {
                endField()
                index = text.index(after: index)
                continue
            }
            if char == "\r" || char == "\n" {
                endField()
                records.append(current)
                current = []
                var end = text.index(after: index)
                if char == "\r" && end < text.endIndex && text[end] == "\n" {
                    end = text.index(after: end)
                }
                index = end
                continue
            }
            field.append(char)
            index = text.index(after: index)
        }
        if !field.isEmpty || !current.isEmpty {
            endField()
            records.append(current)
        }
        return records
    }

    /// Joins wrapped continuation lines: a physical line that does not start
    /// with a transaction date continues the previous row. The continuation's
    /// first cell extends the previous row's last cell (the field the wrap
    /// broke, usually the description) with a space; any remaining cells fill
    /// the columns that follow on the continuation line. A joined line counts
    /// once as one logical row.
    static func joinContinuations(_ body: [[String]]) -> [[String]] {
        var joined: [[String]] = []
        for record in body {
            let firstCell = record.first ?? ""
            if startsWithDate(firstCell) || joined.isEmpty {
                joined.append(record)
                continue
            }
            var fragment = record
            let head = fragment.removeFirst().trimmingCharacters(in: .whitespaces)
            let last = joined.count - 1
            if joined[last].isEmpty {
                joined[last] = fragment
                if !head.isEmpty {
                    joined[last].insert(head, at: 0)
                }
                continue
            }
            if !head.isEmpty {
                let tail = joined[last].count - 1
                if joined[last][tail].isEmpty {
                    joined[last][tail] = head
                } else {
                    joined[last][tail] += " " + head
                }
            }
            joined[last].append(contentsOf: fragment)
        }
        return joined
    }

    static func startsWithDate(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let pattern = #"^\d{1,4}[/\-.]\d{1,2}([/\-.]\d{1,4})?"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Detection

    static func normalizeHeader(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// "Purchased By" is the Apple discriminator: only Wallet exports carry
    /// it. A file with it is an Apple Card attempt — missing siblings then
    /// report finance_csv_missing_column instead of silently reading as generic.
    static func isAppleCardAttempt(headers: [String]) -> Bool {
        headers.contains(normalizeHeader("Purchased By"))
    }

    struct GenericMapping: Sendable {
        var date: Int
        var description: Int
        var amount: Int
    }

    static func genericMapping(headers: [String]) -> GenericMapping? {
        func firstIndex(of candidates: [String]) -> Int? {
            headers.firstIndex(where: { candidates.contains($0) })
        }
        guard let date = firstIndex(of: genericDateHeaders),
            let description = firstIndex(of: genericDescriptionHeaders),
            let amount = firstIndex(of: genericAmountHeaders)
        else {
            return nil
        }
        return GenericMapping(date: date, description: description, amount: amount)
    }

    // MARK: - Apple Card rows

    static func parseAppleCard(headers: [String], rows: [[String]], sha: String, now: Date) -> ParsedFile {
        var errors: [ParseError] = []
        for header in appleCardHeaders {
            if !headers.contains(normalizeHeader(header)) {
                errors.append(ParseError(
                    row: 0, code: codeMissingColumn,
                    message: "required column is missing: \(header)"))
            }
        }
        if !errors.isEmpty {
            return ParsedFile(kind: .appleCard, sha256Hex: sha, rowCount: 0, charges: [], errors: errors)
        }
        func column(_ name: String) -> Int {
            headers.firstIndex(of: normalizeHeader(name)) ?? 0
        }
        let dateColumn = column("Transaction Date")
        let merchantColumn = column("Merchant")
        let descriptionColumn = column("Description")
        let typeColumn = column("Type")
        let amountColumn = column("Amount (USD)")
        let categoryColumn = column("Category")

        var charges: [Charge] = []
        var seenCanonical: Set<String> = []
        for (offset, record) in rows.enumerated() {
            let row = offset + 1
            func cell(_ column: Int) -> String {
                column < record.count ? record[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            let dateText = cell(dateColumn)
            let merchantText = cell(merchantColumn)
            let descriptionText = cell(descriptionColumn)
            let typeText = cell(typeColumn)
            let amountText = cell(amountColumn)
            let categoryText = cell(categoryColumn)
            guard !dateText.isEmpty, !amountText.isEmpty else {
                errors.append(ParseError(row: row, code: codeInvalid, message: "required column is empty"))
                continue
            }
            guard let date = parseDate(dateText) else {
                errors.append(ParseError(row: row, code: codeInvalid, message: "transaction date is invalid"))
                continue
            }
            let limit = Calendar.current.date(byAdding: .day, value: 2, to: startOfDay(now)) ?? now
            if date > limit {
                errors.append(ParseError(row: row, code: codeFutureDate, message: "transaction date is in the future"))
                continue
            }
            guard let amount = parseAmount(amountText) else {
                errors.append(ParseError(row: row, code: codeInvalid, message: "amount is invalid"))
                continue
            }
            if amount == 0 {
                errors.append(ParseError(row: row, code: codeAmountZero, message: "amount is zero"))
                continue
            }
            if !appleCardTypes.contains(typeText.lowercased()) {
                errors.append(ParseError(row: row, code: codeInvalid, message: "activity type is invalid"))
                continue
            }
            let merchant = merchantText.isEmpty ? descriptionText : merchantText
            let canonical = [dateText.lowercased(), merchant.lowercased(), descriptionText.lowercased(),
                             typeText.lowercased(), amountText.lowercased()].joined(separator: "\u{1F}")
            let isDuplicate = seenCanonical.contains(canonical)
            if isDuplicate {
                errors.append(ParseError(row: row, code: codeDuplicateRow, message: "duplicate of an earlier row"))
            } else {
                seenCanonical.insert(canonical)
            }
            charges.append(Charge(
                dateText: dateText, merchantText: merchant, amountText: amountText,
                isDuplicate: isDuplicate, categoryText: categoryText))
        }
        return ParsedFile(
            kind: .appleCard, sha256Hex: sha, rowCount: rows.count,
            charges: charges, errors: errors)
    }

    // MARK: - Generic rows

    static func parseGeneric(mapping: GenericMapping, rows: [[String]], sha: String) -> ParsedFile {
        var charges: [Charge] = []
        var errors: [ParseError] = []
        var seenCanonical: Set<String> = []
        for (offset, record) in rows.enumerated() {
            let row = offset + 1
            func cell(_ column: Int) -> String {
                column < record.count ? record[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            let dateText = cell(mapping.date)
            let merchantText = cell(mapping.description)
            let amountText = cell(mapping.amount)
            if dateText.isEmpty || merchantText.isEmpty || amountText.isEmpty {
                errors.append(ParseError(row: row, code: codeInvalid, message: "required column is empty"))
                continue
            }
            if parseDate(dateText) == nil {
                errors.append(ParseError(row: row, code: codeInvalid, message: "transaction date is invalid"))
                continue
            }
            guard let amount = parseAmount(amountText) else {
                errors.append(ParseError(row: row, code: codeInvalid, message: "amount is invalid"))
                continue
            }
            if amount == 0 {
                errors.append(ParseError(row: row, code: codeAmountZero, message: "amount is zero"))
                continue
            }
            let canonical = [dateText.lowercased(), merchantText.lowercased(), amountText.lowercased()]
                .joined(separator: "\u{1F}")
            let isDuplicate = seenCanonical.contains(canonical)
            if isDuplicate {
                errors.append(ParseError(row: row, code: codeDuplicateRow, message: "duplicate of an earlier row"))
            } else {
                seenCanonical.insert(canonical)
            }
            charges.append(Charge(
                dateText: dateText, merchantText: merchantText, amountText: amountText,
                isDuplicate: isDuplicate))
        }
        return ParsedFile(
            kind: .bank, sha256Hex: sha, rowCount: rows.count,
            charges: charges, errors: errors)
    }

    // MARK: - Scalars

    static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) {
                return date
            }
        }
        return nil
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Plain decimals with optional commas, currency marks, whitespace, and
    /// parentheses negatives. Anything else fails closed.
    static func parseAmount(_ raw: String) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        text = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "USD", with: "")
            .replacingOccurrences(of: "usd", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard var decimal = Decimal(string: text, locale: Locale(identifier: "en_US")) else { return nil }
        if negative { decimal.negate() }
        return decimal
    }
}
