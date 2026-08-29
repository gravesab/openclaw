import XCTest
@testable import PropertyManager

final class TaskCompletionPolicyTests: XCTestCase {
    func testZeroIsAValidExplicitMeterReading() {
        XCTAssertEqual(TaskCompletionPolicy.meterValue("0"), 0)
        XCTAssertEqual(TaskCompletionPolicy.meterValue(" 0.0 "), 0)
        XCTAssertNil(TaskCompletionPolicy.meterValue(""))
        XCTAssertNil(TaskCompletionPolicy.meterValue("-1"))
        XCTAssertNil(TaskCompletionPolicy.meterValue("not a reading"))
    }

    func testActiveRuntimeMeterRequiresConfirmationForCalendarTask() throws {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "calendar",
            hasLinkedAsset: true,
            asset: try asset(
                meterType: "runtime_hours",
                activatedAt: "2026-08-29T12:00:00Z"
            )
        )

        XCTAssertEqual(
            requirement,
            .confirmationRequired(currentValue: 0, unit: "hrs")
        )
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: false,
            enteredValue: ""
        ))
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: false,
            enteredValue: "0"
        ))
        XCTAssertTrue(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: true,
            enteredValue: ""
        ))
    }

    func testProposedRuntimeMeterRequiresExplicitActivation() throws {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "calendar",
            hasLinkedAsset: true,
            asset: try asset(meterType: "none", proposedType: "runtime_hours")
        )

        XCTAssertEqual(
            requirement,
            .activationRequired(meterType: "runtime_hours", unit: "hrs")
        )
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: true,
            enteredValue: "0"
        ))
    }

    func testMeterScheduledTaskWithoutAssetFailsClosed() {
        let requirement = TaskCompletionPolicy.requirement(
            scheduleKind: "meter",
            hasLinkedAsset: false,
            asset: nil
        )

        guard case .unavailable = requirement else {
            return XCTFail("Meter-scheduled task must fail closed without an asset")
        }
        XCTAssertFalse(TaskCompletionPolicy.canSubmit(
            requirement: requirement,
            confirmedCurrent: true,
            enteredValue: "0"
        ))
    }

    private func asset(
        meterType: String,
        activatedAt: String? = nil,
        proposedType: String? = nil
    ) throws -> RanchAsset {
        var json: [String: Any] = [
            "id": UUID().uuidString,
            "external_id": "TEST-ASSET",
            "name": "Test asset",
            "meter": [
                "meter_type": meterType,
                "current_value": 0,
                "unit": meterType == "runtime_hours" ? "hrs" : "",
                "activated": meterType != "none",
            ],
        ]
        if let activatedAt {
            json["meter_activated_at"] = activatedAt
        }
        if let proposedType {
            json["proposed_meter"] = [
                "meter_type": proposedType,
                "unit": proposedType == "runtime_hours" ? "hrs" : "",
            ]
        }
        return try JSONDecoder.propertyManager.decode(
            RanchAsset.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }
}

private extension JSONDecoder {
    static var propertyManager: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
