import XCTest
@testable import PropertyManager

final class PartRequestContractTests: XCTestCase {
    func testReplacementUsesCanonicalPutArrayContract() throws {
        let client = PropertyAPIClient(
            baseURLString: "https://propertymanager.invalid",
            apiKey: "test-key"
        )
        let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let parts: [[String: Any]] = [[
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "Oil filter",
            "quantity": 1,
        ]]

        let request = try client.replacePartsRequest(taskID: taskID, parts: parts)

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["name"] as? String, "Oil filter")
        XCTAssertNil((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["parts"])
    }
}
