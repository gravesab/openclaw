import SwiftUI

enum OpenClawMacBuildIdentity {
    private static let productionBundleIdentifier = "ai.openclaw.mac"

    static var isProduction: Bool {
        Bundle.main.bundleIdentifier == self.productionBundleIdentifier
    }

    static var environment: String {
        self.isProduction ? "PROD" : "DEV"
    }

    static var color: Color {
        self.isProduction ? .green : .orange
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    static var build: String? {
        let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return value?.isEmpty == false ? value : nil
    }

    static var label: String {
        if let build {
            return "\(self.environment) · v\(self.version) (\(build))"
        }
        return "\(self.environment) · v\(self.version)"
    }
}
