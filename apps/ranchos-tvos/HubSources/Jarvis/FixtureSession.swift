#if !os(tvOS)
import Foundation
import Observation

public enum FixtureRecord: String, CaseIterable, Identifiable, Sendable {
    case mower, repair, fuel, parts, service, attachment, manual, dealer
    public var id: Self { self }
    public var title: String {
        switch self {
        case .mower: "John Deere X300"
        case .repair: "Spindle repair"
        case .fuel: "Fuel"
        case .parts: "Replacement belt"
        case .service: "Maintenance"
        case .attachment: "Attachment"
        case .manual: "Owner manual"
        case .dealer: "Sample dealer"
        }
    }
}
public struct FixtureExpense: Identifiable, Sendable {
    public let id: String
    public let record: FixtureRecord
    public let date: String
    public let cents: Int
    public var amount: String { Self.format(cents) }
    public static func format(_ cents: Int) -> String {
        "$\(cents / 100).\(String(format: "%02d", cents % 100))"
    }
    public static let samples = [
        Self(id: "F-101", record: .fuel, date: "2026-03-04", cents: 8400),
        Self(id: "F-102", record: .repair, date: "2026-04-18", cents: 28600),
        Self(id: "F-103", record: .service, date: "2026-05-06", cents: 12000),
        Self(id: "F-104", record: .parts, date: "2026-06-12", cents: 9200),
        Self(id: "F-105", record: .attachment, date: "2026-08-20", cents: 16000),
    ]
    public static var total: String { format(samples.reduce(0) { $0 + $1.cents }) }
}
@MainActor @Observable
public final class FixtureSession {
    public private(set) var selection: FixtureRecord = .mower
    public private(set) var answer = "Select a record or ask a sample question. All information is synthetic."
    public private(set) var showsExpenses = false
    public private(set) var showsCallDraft = false
    public init() {}
    public func select(_ record: FixtureRecord) {
        selection = record
        showsExpenses = false
        showsCallDraft = false
        answer = "Selected \(record.title). Sample record only."
    }
    public func ask(_ input: String) {
        showsExpenses = false
        showsCallDraft = false
        guard input.count <= 500 else { answer = "Use a question of 500 characters or fewer."; return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        switch question {
        case "show me the x300": select(.mower)
        case "what have we spent on lawn mowing":
            answer = "Do you mean contractors, equipment, or both? Only X300 equipment samples are available."
        case "what have we spent on it", "prepare a dealer call":
            guard selection == .mower || selection == .repair else {
                answer = "Select the X300 or its repair first. I will not assume which asset you mean."
                return
            }
            if question == "prepare a dealer call" {
                showsCallDraft = true
                answer = "Draft only. The recipient is unverified; calling is disconnected. No repair or payment authority."
            } else { showExpenses() }
        case "what have we spent on the x300":
            selection = .mower
            showExpenses()
        default: answer = "That request is not connected in this fixture. Try a sample question; no live query was run."
        }
    }
    private func showExpenses() {
        showsExpenses = true
        answer = "The X300 sample ledger totals \(FixtureExpense.total), across five transactions for January–September 2026."
    }
}

#endif
