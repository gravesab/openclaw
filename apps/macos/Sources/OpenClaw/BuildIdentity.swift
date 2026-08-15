import SwiftUI

enum OpenClawMacBuildIdentity {
    #if DEBUG
    static let environment = "DEV"
    static let color = Color.orange
    #else
    static let environment = "PROD"
    static let color = Color.green
    #endif

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    static var build: String? {
        let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return value?.isEmpty == false ? value : nil
    }

    static var label: String {
        if let build {
            return "\(environment) · v\(version) (\(build))"
        }
        return "\(environment) · v\(version)"
    }
}
