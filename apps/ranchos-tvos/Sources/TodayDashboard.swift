import Foundation

struct TodayDashboard: Sendable {
    struct Card: Identifiable, Sendable {
        let id: String
        let kind: Kind
        let title: String
        let value: String
        let detail: String
        let symbolName: String

        enum Kind: String, Sendable, CaseIterable {
            case weather
            case livestock
            case property
        }
    }

    let tenantDisplayName: String
    let dateLabel: String
    let cards: [Card]

    // Compile-time local chrome only. This is not the server Today endpoint
    // and is not an unauthenticated or tenant-scoped data source.
    static let developmentFixtureBanner = "DEV fixture · Live tenant data is not connected"
    static let developmentFixtureValue = "DEV fixture"
    static let developmentFixture = TodayDashboard(
        tenantDisplayName: "Ranch OS DEV",
        dateLabel: "Today",
        cards: [
            Card(
                id: "weather",
                kind: .weather,
                title: "Weather",
                value: developmentFixtureValue,
                detail: "Awaiting the approved API boundary.",
                symbolName: "cloud.sun.fill"),
            Card(
                id: "livestock",
                kind: .livestock,
                title: "Livestock",
                value: developmentFixtureValue,
                detail: "No animal records are stored locally.",
                symbolName: "pawprint.fill"),
            Card(
                id: "property",
                kind: .property,
                title: "Property",
                value: developmentFixtureValue,
                detail: "No API key or task data is embedded.",
                symbolName: "house.fill"),
        ])
}
