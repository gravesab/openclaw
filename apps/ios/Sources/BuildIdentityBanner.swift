import SwiftUI

enum OpenClawBuildIdentity {
    static var isProduction: Bool {
        PushBuildConfig.current.mode == .appStore
    }

    static var environment: String {
        self.isProduction ? "PROD" : "DEV"
    }

    static var color: Color {
        self.isProduction ? .green : .orange
    }

    static var version: String {
        (Bundle.main.infoDictionary?["OpenClawCanonicalVersion"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "unknown"
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

struct BuildIdentityBanner: View {
    var body: some View {
        Text(OpenClawBuildIdentity.label)
            .font(.caption2.bold().monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(.black)
            .background(OpenClawBuildIdentity.color)
            .accessibilityLabel(
                "OpenClaw \(OpenClawBuildIdentity.environment) version \(OpenClawBuildIdentity.version)")
    }
}
