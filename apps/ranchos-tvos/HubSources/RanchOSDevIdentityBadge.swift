import SwiftUI

enum RanchOSDevIdentityBadgeStyle {
    case canvas
    case sidebar
    case toolbar
    case television
}

/// Persistent identity for upper chrome. Names DEV or Production plus version and build.
struct RanchOSDevIdentityBadge: View {
    var style: RanchOSDevIdentityBadgeStyle = .canvas
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    #if !os(tvOS)
    static var toolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }
    #endif

    var body: some View {
        HStack(spacing: 10) {
            Text(environment.productName)
                .font(devFont)
                .tracking(0.4)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(devFill, in: Capsule())

            Text(RanchOSBuildInfo.versionAndBuild)
                .font(versionFont)
                .monospacedDigit()
                .foregroundStyle(versionColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(style == .toolbar ? 0 : 10)
        .frame(maxWidth: style == .toolbar ? nil : .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RanchOSBuildInfo.accessibilityLabel(for: environment))
    }

    private var devFont: Font {
        switch style {
        case .television: .headline.weight(.heavy)
        case .toolbar: .caption2.weight(.heavy)
        case .canvas, .sidebar: .caption.weight(.heavy)
        }
    }

    private var versionFont: Font {
        switch style {
        case .television: .title3.weight(.semibold)
        case .toolbar: .caption.weight(.semibold)
        case .canvas, .sidebar: .subheadline.weight(.semibold)
        }
    }

    private var versionColor: Color {
        switch style {
        case .sidebar, .television: Color(red: 0.96, green: 0.94, blue: 0.86)
        case .canvas, .toolbar: Color(red: 0.09, green: 0.13, blue: 0.10)
        }
    }

    private var devFill: Color {
        switch environment {
        case .development:
            Color(red: 0.69, green: 0.51, blue: 0.12)
        case .production:
            Color(red: 0.62, green: 0.18, blue: 0.16)
        }
    }

    private var background: Color {
        switch style {
        case .canvas:
            Color.white.opacity(0.72)
        case .sidebar:
            Color.white.opacity(0.12)
        case .toolbar:
            Color.clear
        case .television:
            Color.white.opacity(0.16)
        }
    }
}
