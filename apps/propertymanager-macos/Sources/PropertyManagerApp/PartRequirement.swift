import Foundation

struct PartRequirement: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var oemPartNumber: String
    var partNumber: String
    var buyURL: String
    var cost: Double

    init(
        id: UUID = UUID(),
        name: String = "",
        oemPartNumber: String = "",
        partNumber: String = "",
        buyURL: String = "",
        cost: Double = 0
    ) {
        self.id = id
        self.name = name
        self.oemPartNumber = oemPartNumber
        self.partNumber = partNumber
        self.buyURL = buyURL
        self.cost = cost
    }

    enum CodingKeys: String, CodingKey {
        case id, name, oemPartNumber, partNumber, buyURL, cost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        oemPartNumber = try c.decodeIfPresent(String.self, forKey: .oemPartNumber) ?? ""
        partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber) ?? ""
        buyURL = try c.decodeIfPresent(String.self, forKey: .buyURL) ?? ""
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
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
