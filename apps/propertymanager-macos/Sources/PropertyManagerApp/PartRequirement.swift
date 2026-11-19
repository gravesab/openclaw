import Foundation

struct PartRequirement: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var oemPartNumber: String
    var partNumber: String
    var buyURL: String
    var cost: Double
    /// Round-tripped from the server so a Mac edit never resets quantity,
    /// vendor, or notes entered on another client.
    var quantity: Double
    var vendor: String
    var notes: String

    init(
        id: UUID = UUID(),
        name: String = "",
        oemPartNumber: String = "",
        partNumber: String = "",
        buyURL: String = "",
        cost: Double = 0,
        quantity: Double = 1,
        vendor: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.oemPartNumber = oemPartNumber
        self.partNumber = partNumber
        self.buyURL = buyURL
        self.cost = cost
        self.quantity = quantity
        self.vendor = vendor
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, oemPartNumber, partNumber, buyURL, cost, quantity, vendor, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        oemPartNumber = try c.decodeIfPresent(String.self, forKey: .oemPartNumber) ?? ""
        partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber) ?? ""
        buyURL = try c.decodeIfPresent(String.self, forKey: .buyURL) ?? ""
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity) ?? 1
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    static func migrated(fromPartNumbers numbers: [String], urls: [String]) -> [PartRequirement] {
        let count = max(numbers.count, urls.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            PartRequirement(
                name: "Part \(index + 1)",
                oemPartNumber: "",
                partNumber: index < numbers.count ? numbers[index] : "",
                buyURL: index < urls.count ? urls[index] : "",
                cost: 0
            )
        }
    }
}

extension PartRequirement {
    static func apiPayload(_ parts: [PartRequirement]) -> [[String: Any]] {
        parts.enumerated().map { index, part -> [String: Any] in
            [
                "id": part.id.uuidString,
                "name": part.name,
                "oem_part_number": part.oemPartNumber,
                "part_number": part.partNumber,
                "buy_url": part.buyURL,
                "cost": part.cost,
                "quantity": part.quantity,
                "vendor": part.vendor,
                "notes": part.notes,
                "sort_order": index,
            ]
        }
    }
}
