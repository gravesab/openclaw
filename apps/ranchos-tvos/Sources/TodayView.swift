import SwiftUI

struct TodayView: View {
    let dashboard: TodayDashboard

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.10, blue: 0.13), Color(red: 0.10, green: 0.22, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 52) {
                header

                HStack(spacing: 28) {
                    ForEach(dashboard.cards) { card in
                        TodayCardView(card: card)
                    }
                }

                Spacer()

                Label(TodayDashboard.developmentFixtureBanner, systemImage: "lock.shield")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 92)
            .padding(.vertical, 66)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dashboard.tenantDisplayName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
            Text(dashboard.dateLabel)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

private struct TodayCardView: View {
    let card: TodayDashboard.Card
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: card.symbolName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(tint)
            Text(card.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(card.value)
                .font(.system(size: 44, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(card.detail)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(width: 360, height: 330, alignment: .topLeading)
        .background(.white.opacity(isFocused ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(isFocused ? 0.9 : 0.16), lineWidth: isFocused ? 4 : 1)
        }
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    private var tint: Color {
        switch card.kind {
        case .weather: .yellow
        case .livestock: .orange
        case .property: .mint
        }
    }
}
