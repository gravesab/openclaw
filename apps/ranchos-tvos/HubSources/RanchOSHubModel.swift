import Foundation

enum RanchOSBuildInfo {
    static var productName: String { RanchOSRuntimeEnvironment.development.productName }
    static var environmentName: String { RanchOSRuntimeEnvironment.development.shortName }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    static var versionAndBuild: String {
        "Version \(version) · Build \(build)"
    }

    static var display: String { display(for: .development) }

    static var accessibilityLabel: String { accessibilityLabel(for: .development) }

    static func display(for environment: RanchOSRuntimeEnvironment) -> String {
        "\(environment.productName) · \(versionAndBuild)"
    }

    static func accessibilityLabel(for environment: RanchOSRuntimeEnvironment) -> String {
        switch environment {
        case .development:
            "RanchOS development Version \(version) Build \(build)"
        case .production:
            "RanchOS production Version \(version) Build \(build)"
        }
    }
}

enum RanchOSModule: String, CaseIterable, Identifiable, Sendable {
    case property
    case livestock
    case finance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .property: "Property Manager"
        case .livestock: "Livestock"
        case .finance: "Finance"
        }
    }

    var symbolName: String {
        switch self {
        case .property: "building.2"
        case .livestock: "pawprint"
        case .finance: "chart.bar.doc.horizontal"
        }
    }

    var detail: String {
        switch self {
        case .property: "Assets, maintenance, and work requests"
        case .livestock: "Animals, care, and operational inputs"
        case .finance: "Report summary from the Finance application"
        }
    }
}

struct RanchOSHubDashboard: Sendable {
    let title: String
    let tenantDisplayName: String
    let modules: [RanchOSModule]

    static var developmentFixtureBanner: String { RanchOSRuntimeEnvironment.development.hubBanner }
    static let developmentFixture = RanchOSHubDashboard(
        title: "RanchOS",
        tenantDisplayName: "Ranch OS DEV",
        modules: RanchOSModule.allCases)
}

enum RanchOSPropertyAsset: String, CaseIterable, Identifiable, Sendable {
    case northPastureFence = "north-fence"
    case equipmentBarn = "equipment-barn"
    case waterSystem = "water-system"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .northPastureFence: "North pasture fence"
        case .equipmentBarn: "Equipment barn"
        case .waterSystem: "Water system"
        }
    }
}

struct RanchOSPropertySummary: Identifiable, Sendable {
    enum Status: String, Sendable {
        case needsAttention = "Needs attention"
        case upcoming = "Upcoming"
        case current = "Current"
    }

    let asset: RanchOSPropertyAsset
    let summary: String
    let status: Status

    var id: String { asset.id }
    var title: String { asset.title }
    var detail: String { summary }
}

struct RanchOSPropertyAssetSnapshot: Sendable {
    let asset: RanchOSPropertyAsset
    let lastChecked: String
    let nextAction: String
    let note: String

    var title: String { asset.title }
}

struct RanchOSPropertyDashboard: Sendable {
    let ranchName: String
    let summaries: [RanchOSPropertySummary]
    let snapshots: [RanchOSPropertyAssetSnapshot]

    func snapshot(for asset: RanchOSPropertyAsset) -> RanchOSPropertyAssetSnapshot {
        if let snapshot = snapshots.first(where: { $0.asset == asset }) {
            return snapshot
        }
        preconditionFailure("The development fixture is missing snapshot data for \(asset.rawValue).")
    }

    static let developmentFixture = RanchOSPropertyDashboard(
        ranchName: "Ranch OS DEV",
        summaries: [
            RanchOSPropertySummary(
                asset: .northPastureFence,
                summary: "Inspection due this week",
                status: .needsAttention),
            RanchOSPropertySummary(
                asset: .equipmentBarn,
                summary: "Seasonal maintenance review",
                status: .upcoming),
            RanchOSPropertySummary(
                asset: .waterSystem,
                summary: "Last inspection: current",
                status: .current),
        ],
        snapshots: [
            RanchOSPropertyAssetSnapshot(
                asset: .northPastureFence,
                lastChecked: "September 14 · perimeter walk",
                nextAction: "Inspect the north gate and two marked posts this week.",
                note: "Fixture only. No work request can be created from RanchOS."),
            RanchOSPropertyAssetSnapshot(
                asset: .equipmentBarn,
                lastChecked: "September 3 · seasonal review",
                nextAction: "Review roof, lighting, and equipment storage before the fall schedule.",
                note: "Fixture only. Maintenance history is not connected."),
            RanchOSPropertyAssetSnapshot(
                asset: .waterSystem,
                lastChecked: "September 16 · system check",
                nextAction: "Continue routine observation; no action is currently due.",
                note: "Fixture only. Meter entries and inspections cannot be changed.")
        ])
}

struct RanchOSLivestockSummary: Identifiable, Sendable, Equatable {
    enum Status: String, Sendable {
        case careDue = "Care due"
        case current = "Current"
        case review = "Review"
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
}

struct RanchOSLivestockDashboard: Sendable, Equatable {
    let ranchName: String
    let herdCount: Int
    let summaries: [RanchOSLivestockSummary]

    static let developmentFixture = RanchOSLivestockDashboard(
        ranchName: "Ranch OS DEV",
        herdCount: 12,
        summaries: [
            RanchOSLivestockSummary(
                id: "care-reminders",
                title: "Care reminders",
                detail: "2 animals need attention this week",
                status: .careDue),
            RanchOSLivestockSummary(
                id: "pasture-check",
                title: "Pasture check",
                detail: "Daily observation is current",
                status: .current),
            RanchOSLivestockSummary(
                id: "records-review",
                title: "Records review",
                detail: "Herd details ready for review",
                status: .review),
        ])
}

struct RanchOSFinanceSummary: Identifiable, Sendable {
    enum Status: String, Sendable {
        case ready = "Ready"
        case review = "Review"
        case upcoming = "Upcoming"
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
}

struct RanchOSFinanceDashboard: Sendable {
    let ranchName: String
    let summaries: [RanchOSFinanceSummary]

    static let disconnectedCardLabel = "Report summary · not connected"
    static let disconnectedBanner =
        "Report summary · not connected. RanchOS will summarize reports from the Finance application when that DEV app is ready. No finance data is loaded here."

    /// Placeholder host payload. Summaries stay empty until the Finance app is connected.
    static let developmentFixture = RanchOSFinanceDashboard(
        ranchName: "Ranch OS DEV",
        summaries: [])
}

enum RanchOSHostedModule: Sendable {
    case property(RanchOSPropertyDashboard)
    case livestock(RanchOSLivestockDashboard)
    case finance(RanchOSFinanceDashboard)

    var module: RanchOSModule {
        switch self {
        case .property: .property
        case .livestock: .livestock
        case .finance: .finance
        }
    }
}

struct RanchOSModuleHost: Sendable {
    static let developmentFixture = RanchOSModuleHost()

    func hostedModule(for module: RanchOSModule) -> RanchOSHostedModule {
        switch module {
        case .property: .property(.developmentFixture)
        case .livestock: .livestock(.developmentFixture)
        case .finance: .finance(.developmentFixture)
        }
    }
}
