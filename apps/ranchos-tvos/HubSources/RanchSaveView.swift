import SwiftUI

/// Save-check card: "<Ranch> · Saved" plus one isolation row per domain.
/// Each passing row pops a green check aligned to the trailing edge,
/// staggered 200ms apart right after save. Pure view over
/// `DataIsolationVerifier` output; nothing here touches the network.
struct RanchSaveView: View {
    let ranchName: String
    let checks: [IsolationCheck]

    @State private var revealedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(ranchName) · Saved")
                .font(.headline)
                .padding(.bottom, 8)
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                HStack {
                    Text(check.label)
                        .font(.system(size: 13))
                    Spacer()
                    if check.passed && index < revealedCount {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 16))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 28)
                Divider().opacity(0.15)
            }
        }
        .frame(width: 340)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
        .cornerRadius(12)
        .shadow(radius: 4)
        .animation(.spring(response: 0.3), value: revealedCount)
        .onAppear { replay() }
        .onChange(of: checks) { _, _ in replay() }
    }

    // One branch compiles per platform. tvOS has no secondary system
    // background color; a material card is the native look there.
    private var cardBackground: some ShapeStyle {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #elseif os(tvOS)
        .regularMaterial
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private func replay() {
        revealedCount = 0
        for index in checks.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.2) {
                if index < checks.count {
                    revealedCount = max(revealedCount, index + 1)
                }
            }
        }
    }
}
