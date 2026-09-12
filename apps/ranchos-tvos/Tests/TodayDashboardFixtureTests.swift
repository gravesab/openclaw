import Foundation
import XCTest

final class TodayDashboardFixtureTests: XCTestCase {
    func testDevelopmentFixtureUsesStaticLocalLabels() {
        let dashboard = TodayDashboard.developmentFixture

        XCTAssertEqual(dashboard.tenantDisplayName, "Ranch OS DEV")
        XCTAssertEqual(dashboard.dateLabel, "Today")
        XCTAssertEqual(TodayDashboard.developmentFixtureValue, "DEV fixture")
        XCTAssertEqual(
            TodayDashboard.developmentFixtureBanner,
            "DEV fixture · Live tenant data is not connected")
        XCTAssertEqual(
            dashboard.cards.map(\.value),
            Array(repeating: TodayDashboard.developmentFixtureValue, count: 3))
        XCTAssertEqual(
            dashboard.cards.map(\.detail),
            [
                "Awaiting the approved API boundary.",
                "No animal records are stored locally.",
                "No API key or task data is embedded.",
            ])
        XCTAssertTrue(shellSource("TodayView.swift").contains("developmentFixtureBanner"))
        XCTAssertTrue(shellSource("RanchOSTVApp.swift").contains(".developmentFixture"))
    }

    func testDevelopmentFixtureHasExactlyThreeClosedCardKinds() {
        let cards = TodayDashboard.developmentFixture.cards
        let kinds = cards.map(\.kind)

        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(TodayDashboard.Card.Kind.allCases.count, 3)
        XCTAssertEqual(kinds, [.weather, .livestock, .property])
        XCTAssertEqual(Set(kinds), Set(TodayDashboard.Card.Kind.allCases))
        XCTAssertEqual(cards.map(\.id), ["weather", "livestock", "property"])
        XCTAssertEqual(cards.map(\.title), ["Weather", "Livestock", "Property"])
    }

    func testShellHasNoRecordNavigationOrWriteBehavior() {
        let dashboard = TodayDashboard.developmentFixture

        XCTAssertNil(UUID(uuidString: dashboard.tenantDisplayName))
        for card in dashboard.cards {
            XCTAssertNil(UUID(uuidString: card.id))
            XCTAssertFalse(cardHasActionableRecordAffordance(card))
        }

        let forbidden = [
            "NavigationLink",
            "NavigationStack",
            "NavigationPath",
            "Button(",
            "TextField",
            "SecureField",
            "onTapGesture",
            "onLongPressGesture",
            "sheet(",
            "fullScreenCover",
            "confirmationDialog",
            "URLSession",
            "URLRequest",
            "UserDefaults",
            "@AppStorage",
            "FileManager",
            "TenantContext",
            "VerifiedPrincipal",
            "/v1/tv/today",
        ]
        for name in ["TodayDashboard.swift", "TodayView.swift", "RanchOSTVApp.swift"] {
            let source = shellSource(name)
            XCTAssertFalse(source.isEmpty, "Missing shell source \(name)")
            for token in forbidden {
                XCTAssertFalse(
                    source.contains(token),
                    "\(name) must not contain \(token)")
            }
        }
    }
}

private func cardHasActionableRecordAffordance(_ card: TodayDashboard.Card) -> Bool {
    let fields = [card.id, card.title, card.value, card.detail, card.symbolName]
    return fields.contains { field in
        field.contains("://")
            || field.contains("/v1/")
            || field.lowercased().contains("http")
            || UUID(uuidString: field) != nil
    }
}

private func shellSource(_ fileName: String) -> String {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = testsDir.deletingLastPathComponent().appendingPathComponent("Sources").appendingPathComponent(fileName)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
