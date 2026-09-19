import SwiftUI

#if os(tvOS)
struct RanchOSTVHomeView: View {
    let dashboard: RanchOSHubDashboard
    @Binding var appearance: RanchOSAppearance

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.indigo.opacity(0.8), .green.opacity(0.55), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 42) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dashboard.title)
                            .font(.largeTitle.bold())
                        Text(dashboard.tenantDisplayName)
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.78))
                    }

                    HStack(spacing: 28) {
                        ForEach(dashboard.modules) { module in
                            NavigationLink {
                                RanchOSTVModuleDetailView(module: module)
                            } label: {
                                RanchOSTVModuleCard(module: module)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Picker("Appearance", selection: $appearance) {
                        ForEach(RanchOSAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)

                    Label(RanchOSHubDashboard.developmentFixtureBanner, systemImage: "lock.shield")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .padding(.horizontal, 92)
                .padding(.vertical, 66)
            }
        }
    }
}

private struct RanchOSTVModuleCard: View {
    let module: RanchOSModule
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: module.symbolName)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.mint)
            Text(module.title)
                .font(.title3.weight(.semibold))
            Text(module.detail)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(30)
        .frame(width: 350, height: 290, alignment: .topLeading)
        .background(.white.opacity(isFocused ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(isFocused ? 0.9 : 0.16), lineWidth: isFocused ? 4 : 1)
        }
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct RanchOSTVModuleDetailView: View {
    let module: RanchOSModule

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.8), .green.opacity(0.55), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                Label("\(module.title.uppercased()) · READ ONLY", systemImage: "lock.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.mint)

                Text(headline)
                    .font(.system(size: 54, weight: .bold, design: .serif))
                    .foregroundStyle(.white)

                Text("Ranch OS DEV")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.74))

                VStack(spacing: 16) {
                    ForEach(items) { item in
                        if let snapshot = item.propertySnapshot {
                            NavigationLink {
                                RanchOSTVPropertySnapshotView(snapshot: snapshot)
                            } label: {
                                RanchOSTVDetailCard(item: item)
                            }
                            .buttonStyle(.plain)
                        } else {
                            RanchOSTVDetailCard(item: item)
                        }
                    }
                }
                .frame(maxWidth: 900)

                Spacer()

                Label("Read-only development fixture · No records can be changed here.", systemImage: "lock.shield")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
            .padding(.horizontal, 92)
            .padding(.vertical, 66)
        }
    }

    private var headline: String {
        switch module {
        case .property: "Property overview"
        case .livestock: "Herd overview"
        case .finance: "Financial overview"
        }
    }

    private var items: [RanchOSTVDetailItem] {
        switch module {
        case .property:
            RanchOSPropertyDashboard.developmentFixture.summaries.map { summary in
                RanchOSTVDetailItem(
                    title: summary.title,
                    detail: summary.detail,
                    symbolName: propertySymbol(for: summary.status),
                    propertySnapshot: RanchOSPropertyDashboard.developmentFixture.snapshot(for: summary.asset))
            }
        case .livestock:
            [
                RanchOSTVDetailItem(title: "Care reminders", detail: "2 animals need attention this week", symbolName: "bell.fill"),
                RanchOSTVDetailItem(title: "Pasture check", detail: "Daily observation is current", symbolName: "checkmark.circle.fill"),
                RanchOSTVDetailItem(title: "Records review", detail: "Herd details ready for review", symbolName: "doc.text.magnifyingglass"),
            ]
        case .finance:
            [
                RanchOSTVDetailItem(title: "Monthly view", detail: "September summary is ready", symbolName: "checkmark.circle.fill"),
                RanchOSTVDetailItem(title: "Household and ranch", detail: "Categories are ready for review", symbolName: "doc.text.magnifyingglass"),
                RanchOSTVDetailItem(title: "Upcoming bills", detail: "3 planned items this month", symbolName: "calendar"),
            ]
        }
    }

    private func propertySymbol(for status: RanchOSPropertySummary.Status) -> String {
        switch status {
        case .needsAttention: "exclamationmark.triangle.fill"
        case .upcoming: "calendar"
        case .current: "checkmark.circle.fill"
        }
    }
}

private struct RanchOSTVDetailCard: View {
    let item: RanchOSTVDetailItem

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: item.symbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.mint)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                Text(item.detail)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
            if item.propertySnapshot != nil {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(20)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct RanchOSTVPropertySnapshotView: View {
    let snapshot: RanchOSPropertyAssetSnapshot

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.8), .green.opacity(0.55), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 30) {
                Label("PROPERTY SNAPSHOT · READ ONLY", systemImage: "lock.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.mint)
                Text(snapshot.title)
                    .font(.system(size: 54, weight: .bold, design: .serif))
                RanchOSTVSnapshotRow(title: "Last checked", detail: snapshot.lastChecked, symbolName: "checkmark.circle")
                RanchOSTVSnapshotRow(title: "Next action", detail: snapshot.nextAction, symbolName: "calendar")
                RanchOSTVSnapshotRow(title: "Fixture boundary", detail: snapshot.note, symbolName: "lock.shield")
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 92)
            .padding(.vertical, 66)
        }
    }
}

private struct RanchOSTVSnapshotRow: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.body).foregroundStyle(.white.opacity(0.72))
            }
        } icon: {
            Image(systemName: symbolName).foregroundStyle(.mint)
        }
        .padding(20)
        .frame(maxWidth: 900, alignment: .leading)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct RanchOSTVDetailItem: Identifiable {
    let title: String
    let detail: String
    let symbolName: String
    let propertySnapshot: RanchOSPropertyAssetSnapshot?

    init(title: String, detail: String, symbolName: String, propertySnapshot: RanchOSPropertyAssetSnapshot? = nil) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.propertySnapshot = propertySnapshot
    }

    var id: String { title }
}
#endif
