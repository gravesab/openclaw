import Foundation

struct TaskPartDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var oemPartNumber: String
    var partNumber: String
    var buyURL: String
    var costText: String
    var quantityText: String
    var vendor: String
    var notes: String
    var isExisting: Bool

    init(from part: TaskPart) {
        id = part.id ?? UUID()
        name = part.name ?? ""
        oemPartNumber = part.oemPartNumber ?? ""
        partNumber = part.partNumber ?? ""
        buyURL = part.buyURL ?? ""
        costText = TaskPartDraft.numberText(part.cost)
        quantityText = TaskPartDraft.numberText(part.quantity ?? 1)
        vendor = part.vendor ?? ""
        notes = part.notes ?? ""
        isExisting = part.id != nil
    }

    init() {
        id = UUID()
        name = ""
        oemPartNumber = ""
        partNumber = ""
        buyURL = ""
        costText = ""
        quantityText = "1"
        vendor = ""
        notes = ""
        isExisting = false
    }

    func asAPIDictionary() throws -> [String: Any] {
        let cost = try Self.parseOptionalNumber(costText, field: "Cost") ?? 0
        let quantity = try Self.parseOptionalNumber(quantityText, field: "Quantity") ?? 1
        guard quantity > 0 else {
            throw PartDraftError.invalidQuantity
        }
        return [
            "id": id.uuidString,
            "name": name,
            "oem_part_number": oemPartNumber,
            "part_number": partNumber,
            "buy_url": buyURL,
            "cost": cost,
            "quantity": quantity,
            "vendor": vendor,
            "notes": notes,
        ]
    }

    private static func numberText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func parseOptionalNumber(_ text: String, field: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        guard let value = Double(trimmed) else {
            throw PartDraftError.invalidNumber(field)
        }
        return value
    }
}

enum PartDraftError: LocalizedError {
    case invalidNumber(String)
    case invalidQuantity

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let field):
            return "\(field) must be a number."
        case .invalidQuantity:
            return "Quantity must be greater than zero."
        }
    }
}
