import Foundation
import Observation
import SwiftUI

enum RanchOSRuntimeEnvironment: String, CaseIterable, Identifiable, Sendable {
    case development
    case production

    var id: String { rawValue }

    var title: String {
        switch self {
        case .development: "DEV"
        case .production: "Production"
        }
    }

    var shortName: String {
        switch self {
        case .development: "DEV"
        case .production: "PROD"
        }
    }

    var productName: String {
        switch self {
        case .development: "RanchOS DEV"
        case .production: "RanchOS Production"
        }
    }

    var tenantDisplayName: String {
        switch self {
        case .development: "Ranch OS DEV"
        case .production: "Ranch OS Production"
        }
    }

    var propertyBaseURL: URL {
        switch self {
        case .development:
            #if os(tvOS)
            URL(string: "http://andrew-m4-pro.local:15063")!
            #else
            URL(string: "http://100.85.188.74:5062")!
            #endif
        case .production:
            #if os(tvOS)
            URL(string: "http://intelmini.local:5062")!
            #else
            URL(string: "http://100.85.36.72:5062")!
            #endif
        }
    }

    var propertyKeychainService: String {
        switch self {
        case .development: "ai.openclaw.ranchos.dev.property"
        case .production: "ai.openclaw.ranchos.prod.property"
        }
    }

    var propertyKeychainAccount: String {
        switch self {
        case .development: "propertymanager-dev-api-key"
        case .production: "propertymanager-prod-api-key"
        }
    }

    var propertyLaunchKeyEnvironment: String {
        switch self {
        case .development: "RANCHOS_PROPERTYMANAGER_DEV_API_KEY"
        case .production: "RANCHOS_PROPERTYMANAGER_PROD_API_KEY"
        }
    }

    var hubBanner: String {
        switch self {
        case .development:
            "DEV · PropertyManager live; Livestock pending; Finance not connected"
        case .production:
            "Production · PropertyManager live; Livestock pending; Finance not connected"
        }
    }

    var propertyLiveCardLabel: String {
        switch self {
        case .development: "Live DEV data · read only"
        case .production: "Live Production data · read only"
        }
    }

    var propertyLiveFooter: String {
        switch self {
        case .development:
            "Live DEV data · read only. RanchOS cannot create, complete, edit, or delete PropertyManager records."
        case .production:
            "Live Production data · read only. RanchOS cannot create, complete, edit, or delete PropertyManager records."
        }
    }

    var livestockPendingLabel: String {
        switch self {
        case .development:
            "DEV fixture — live Livestock connection pending."
        case .production:
            "Production · live Livestock is not available yet."
        }
    }
}

private struct RanchOSRuntimeEnvironmentKey: EnvironmentKey {
    static let defaultValue = RanchOSRuntimeEnvironment.development
}

extension EnvironmentValues {
    var ranchOSRuntimeEnvironment: RanchOSRuntimeEnvironment {
        get { self[RanchOSRuntimeEnvironmentKey.self] }
        set { self[RanchOSRuntimeEnvironmentKey.self] = newValue }
    }
}

/// Persisted live-data choice. DEV and Production never share PropertyManager keys.
@MainActor
@Observable
final class RanchOSLiveSession {
    static let storageKey = "ai.openclaw.ranchos.runtime-environment"

    var environment: RanchOSRuntimeEnvironment {
        didSet {
            UserDefaults.standard.set(environment.rawValue, forKey: Self.storageKey)
        }
    }

    init(environment: RanchOSRuntimeEnvironment? = nil) {
        if let environment {
            self.environment = environment
        } else {
            self.environment = Self.persistedEnvironment()
        }
    }

    static func persistedEnvironment() -> RanchOSRuntimeEnvironment {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let value = RanchOSRuntimeEnvironment(rawValue: raw) {
            return value
        }
        return .development
    }
}

struct RanchOSLiveDataSourcePicker: View {
    @Bindable var session: RanchOSLiveSession

    var body: some View {
        Picker("Live data", selection: $session.environment) {
            ForEach(RanchOSRuntimeEnvironment.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .accessibilityLabel("Choose DEV or Production live data")
        .accessibilityHint("PropertyManager reads follow this choice. Livestock and Finance stay disconnected until those APIs exist.")
    }
}
