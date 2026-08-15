import SwiftUI

enum PropertyManagerBuildIdentity {
    static let environment = PropertyManagerBuildEnvironment.isDevelopment ? "DEV" : "PROD"

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    static var build: String? {
        let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return value?.isEmpty == false ? value : nil
    }

    static var label: String {
        let dataLabel = PropertyManagerBuildEnvironment.isDevelopment ? "DEV DATA" : "PROD DATA"
        let versionLabel = build.map { "v\(version) (\($0))" } ?? "v\(version)"
        return "PROPERTY MANAGER \(environment) · \(versionLabel) · \(dataLabel)"
    }
}
