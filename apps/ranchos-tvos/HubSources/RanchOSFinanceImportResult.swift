import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Exact strings for the Finance DEV import-result view.
enum FinanceImportResultStrings {
    static let banner = "DEV · Finance import result · read only"
    static let walletInstructions = "On iPhone: open Wallet, tap Apple Card, open Statements, export the monthly CSV."
    static let unreadable = "Could not read that file."
    static let notThisCSV = "That file is not an Apple Card CSV."
}

struct FinanceImportDisplay: Sendable, Equatable {
    struct RowError: Sendable, Equatable {
        let row: Int
        let code: String
        let message: String
    }

    let fileName: String
    let sha256: String
    let rowCount: Int
    let errors: [RowError]
}

enum FinanceImportParseError: Error, Equatable {
    case unreadable
    case notThisCSV
}

/// Display-only Apple Card CSV read. Mirrors apple-card-csv-v1 headers and error codes.
/// Amounts, merchants, categories, and row text are not returned.
enum FinanceImportResultLoader {
    static let readableTypes: [UTType] = {
        var types: [UTType] = [.commaSeparatedText, .plainText]
        if let csv = UTType(filenameExtension: "csv"), !types.contains(csv) {
            types.append(csv)
        }
        return types
    }()

    static func load(from url: URL) throws -> FinanceImportDisplay {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FinanceImportParseError.unreadable
        }
        return try parse(data, fileName: url.lastPathComponent)
    }

    static func parse(_ data: Data, fileName: String, now: Date = Date()) throws -> FinanceImportDisplay {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FinanceImportParseError.notThisCSV }
        guard var text = String(data: data, encoding: .utf8) else {
            throw FinanceImportParseError.notThisCSV
        }
        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }
        let table = CSVTable(text: text)
        guard let header = table.rows.first else { throw FinanceImportParseError.notThisCSV }
        let titles = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let missing = Self.headers.filter { !titles.contains($0) }
        guard missing.isEmpty else { throw FinanceImportParseError.notThisCSV }
        let index = Dictionary(uniqueKeysWithValues: Self.headers.map { ($0, titles.firstIndex(of: $0)!) })
        let latest = Self.addDays(2, to: Self.utcDay(now))
        var errors: [FinanceImportDisplay.RowError] = []
        var seen: Set<String> = []
        var rowCount = 0
        for (offset, raw) in Self.repairWrappedRows(Array(table.rows.dropFirst())).enumerated() {
            rowCount += 1
            let rowNumber = offset + 2
            switch Self.classify(raw, index: index, latest: latest, seen: &seen) {
            case .ok:
                break
            case .problem(let code, let message):
                errors.append(FinanceImportDisplay.RowError(row: rowNumber, code: code, message: "Row \(rowNumber): \(message)"))
            }
        }
        return FinanceImportDisplay(
            fileName: name,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            rowCount: rowCount,
            errors: errors)
    }

    private static let headers = [
        "Transaction Date",
        "Clearing Date",
        "Description",
        "Merchant",
        "Category",
        "Type",
        "Amount (USD)",
        "Purchased By",
    ]
    /// Wallet exports use more type words than the original five.
    /// Credit, interest, installment, and dispute are real Apple Card types.
    private static let activityTypes: Set<String> = [
        "purchase", "payment", "refund", "adjustment", "fee",
        "credit", "interest", "installment", "dispute",
    ]

    private enum RowClass {
        case ok
        case problem(String, String)
    }

    private static func classify(
        _ raw: [String],
        index: [String: Int],
        latest: YMD,
        seen: inout Set<String>
    ) -> RowClass {
        guard let transaction = dateField(cell(raw, index["Transaction Date"]!), name: "transaction date") else {
            return dateProblem(cell(raw, index["Transaction Date"]!), name: "transaction date")
        }
        if transaction > latest {
            return .problem("finance_csv_future_date", "transaction date is too far in the future")
        }
        let clearingText = cell(raw, index["Clearing Date"]!)
        var clearing: YMD?
        if !clearingText.isEmpty {
            guard let parsed = dateField(clearingText, name: "clearing date") else {
                return dateProblem(clearingText, name: "clearing date")
            }
            if parsed < transaction {
                return .problem("finance_csv_invalid", "clearing date precedes transaction date")
            }
            clearing = parsed
        }
        let description = cell(raw, index["Description"]!)
        if description.isEmpty {
            return .problem("finance_csv_invalid", "description is required")
        }
        let activityType = cell(raw, index["Type"]!)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !activityTypes.contains(activityType) {
            return .problem("finance_csv_invalid", "activity type is invalid")
        }
        switch amountField(cell(raw, index["Amount (USD)"]!)) {
        case .invalid:
            return .problem("finance_csv_invalid", "amount is invalid")
        case .zero:
            return .problem("finance_csv_amount_zero", "amount is zero")
        case .value(let amount):
            let identity = rowIdentity(
                transaction: transaction,
                clearing: clearing,
                description: description,
                merchant: cell(raw, index["Merchant"]!),
                category: cell(raw, index["Category"]!),
                type: activityType,
                amount: amount,
                purchasedBy: cell(raw, index["Purchased By"]!))
            if seen.contains(identity) {
                return .problem("finance_csv_duplicate_row", "duplicate csv row")
            }
            seen.insert(identity)
            return .ok
        }
    }

    private static func dateProblem(_ text: String, name: String) -> RowClass {
        if text.isEmpty {
            return .problem("finance_csv_invalid", "\(name) is required")
        }
        return .problem("finance_csv_invalid", "\(name) is invalid")
    }

    /// A Wallet description sometimes continues on the next line without quotes.
    /// That continuation does not start with a date. Join it back onto the row above
    /// so Type stays in the Type column.
    private static func repairWrappedRows(_ rows: [[String]]) -> [[String]] {
        var logical: [[String]] = []
        for raw in rows {
            if !raw.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            let first = cell(raw, 0)
            if logical.isEmpty || dateField(first, name: "transaction date") != nil {
                logical.append(raw)
                continue
            }
            guard var previous = logical.popLast(), !previous.isEmpty else {
                logical.append(raw)
                continue
            }
            let continued = previous.removeLast()
            let head = raw.first ?? ""
            let joined = [continued, head]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            previous.append(joined)
            previous.append(contentsOf: raw.dropFirst())
            logical.append(previous)
        }
        return logical
    }

    private static func cell(_ raw: [String], _ position: Int) -> String {
        guard position < raw.count else { return "" }
        return raw[position].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dateField(_ text: String, name _: String) -> YMD? {
        let parts = text.split(separator: text.contains("/") ? "/" : "-", omittingEmptySubsequences: false)
        guard parts.count == 3, !text.isEmpty else { return nil }
        if text.contains("/") {
            guard let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2]), parts[0].count <= 2, parts[1].count <= 2, parts[2].count == 4 else {
                return nil
            }
            return YMD.valid(year: year, month: month, day: day)
        }
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), parts[0].count == 4 else {
            return nil
        }
        return YMD.valid(year: year, month: month, day: day)
    }

    private enum AmountClass {
        case value(String)
        case zero
        case invalid
    }

    private static func amountField(_ text: String) -> AmountClass {
        if text.isEmpty || text.contains("$") || text.contains(",") || text.contains(" ") {
            return .invalid
        }
        guard let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return .invalid
        }
        var source = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        if rounded != amount { return .invalid }
        if rounded == 0 { return .zero }
        return .value(twoPlaces(rounded))
    }

    private static func twoPlaces(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? ""
    }

    private static func rowIdentity(
        transaction: YMD,
        clearing: YMD?,
        description: String,
        merchant: String,
        category: String,
        type: String,
        amount: String,
        purchasedBy: String
    ) -> String {
        let clearingText = clearing.map { $0.iso } ?? ""
        let payload = #"{"amount":\#(json(amount)),"category":\#(json(category)),"clearing_date":\#(json(clearingText)),"description":\#(json(description)),"merchant":\#(json(merchant)),"purchased_by":\#(json(purchasedBy)),"transaction_date":\#(json(transaction.iso)),"type":\#(json(type))}"#
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func json(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private struct YMD: Comparable {
        let year: Int
        let month: Int
        let day: Int

        var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

        static func < (lhs: YMD, rhs: YMD) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            if lhs.month != rhs.month { return lhs.month < rhs.month }
            return lhs.day < rhs.day
        }

        static func valid(year: Int, month: Int, day: Int) -> YMD? {
            var components = DateComponents()
            components.calendar = utcCalendar
            components.timeZone = TimeZone(secondsFromGMT: 0)
            components.year = year
            components.month = month
            components.day = day
            guard components.isValidDate, let date = components.date else { return nil }
            let back = utcCalendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == year, back.month == month, back.day == day else { return nil }
            return YMD(year: year, month: month, day: day)
        }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static func utcDay(_ date: Date) -> YMD {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return YMD(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    private static func addDays(_ days: Int, to day: YMD) -> YMD {
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = day.year
        components.month = day.month
        components.day = day.day
        let date = components.date ?? Date()
        let shifted = utcCalendar.date(byAdding: .day, value: days, to: date) ?? date
        return utcDay(shifted)
    }
}

private struct CSVTable {
    let rows: [[String]]

    init(text: String) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        self.rows = rows
    }
}
