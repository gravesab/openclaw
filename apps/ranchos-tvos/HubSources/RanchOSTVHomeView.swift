import SwiftUI

#if os(tvOS)
struct RanchOSTVHomeView: View {
    let dashboard: RanchOSHubDashboard
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore
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
                                RanchOSTVModuleDetailView(
                                    module: module,
                                    propertyStore: propertyStore,
                                    livestockStore: livestockStore)
                            } label: {
                                RanchOSTVModuleCard(module: module)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    RanchOSForecastBriefCard()

                    RanchOSJarvisCard()

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

    private var moduleConnectionLabel: String {
        switch module {
        case .property: "Live DEV data · read only"
        case .livestock: RanchOSLivestockConnection.pendingLabel
        case .finance: "Development fixture"
        }
    }

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
            Text(moduleConnectionLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.mint.opacity(0.9))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(30)
        .frame(width: 350, height: 320, alignment: .topLeading)
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
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore

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

                detailContent
                .frame(maxWidth: 900)

                Spacer()

                if !footerText.isEmpty {
                    Label(footerText, systemImage: "lock.shield")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
            .padding(.horizontal, 92)
            .padding(.vertical, 66)
        }
        .task {
            switch module {
            case .property:
                await propertyStore.refresh()
            case .livestock:
                await livestockStore.load()
            case .finance:
                break
            }
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
            RanchOSLivestockDashboard.developmentFixture.summaries.map { summary in
                RanchOSTVDetailItem(
                    title: summary.title,
                    detail: summary.detail,
                    symbolName: livestockSymbol(for: summary.status))
            }
        case .finance:
            [
                RanchOSTVDetailItem(title: "Monthly view", detail: "September summary is ready", symbolName: "checkmark.circle.fill"),
                RanchOSTVDetailItem(title: "Household and ranch", detail: "Categories are ready for review", symbolName: "doc.text.magnifyingglass"),
                RanchOSTVDetailItem(title: "Upcoming bills", detail: "3 planned items this month", symbolName: "calendar"),
            ]
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch module {
        case .property:
            switch propertyStore.state {
            case .loading:
                ProgressView("Loading PropertyManager DEV…")
            case .unavailable(let message):
                Text(message).foregroundStyle(.white.opacity(0.78))
            case .ready(let dashboard):
                VStack(spacing: 16) {
                    Text("\(dashboard.activeTaskCount) active tasks · \(dashboard.attentionCount) need attention")
                        .font(.title3.weight(.semibold))
                    ForEach(Array(dashboard.tasks.filter(\.isActive).prefix(5))) { task in
                        RanchOSTVDetailCard(item: RanchOSTVDetailItem(title: task.title, detail: task.detail, symbolName: task.status == .needsAttention ? "exclamationmark.triangle.fill" : "calendar"))
                    }
                }
            }
        case .livestock:
            livestockContent
        case .finance:
            VStack(spacing: 16) {
                ForEach(items) { item in RanchOSTVDetailCard(item: item) }
            }
        }
    }

    @ViewBuilder
    private var livestockContent: some View {
        switch livestockStore.presentation {
        case .fixture(let dashboard):
            livestockCards(dashboard)
        case .loading:
            ProgressView("Loading Livestock…")
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 18) {
                Text(message).foregroundStyle(.white.opacity(0.78))
                if livestockStore.canRetry {
                    Button("Retry") {
                        Task { await livestockStore.load() }
                    }
                }
            }
        case .retryable:
            Button("Retry") {
                Task { await livestockStore.load() }
            }
        case .available(let dashboard):
            livestockCards(dashboard)
        }
    }

    private func livestockCards(_ dashboard: RanchOSLivestockDashboard) -> some View {
        VStack(spacing: 16) {
            ForEach(dashboard.summaries) { summary in
                RanchOSTVDetailCard(
                    item: RanchOSTVDetailItem(
                        title: summary.title,
                        detail: summary.detail,
                        symbolName: livestockSymbol(for: summary.status)))
            }
        }
    }

    private var footerText: String {
        switch module {
        case .property:
            "Live DEV data · read only. RanchOS cannot change PropertyManager records."
        case .livestock:
            livestockStore.presentation.banner
        case .finance:
            "Read-only development fixture · No records can be changed here."
        }
    }

    private func livestockSymbol(for status: RanchOSLivestockSummary.Status) -> String {
        switch status {
        case .careDue: "bell.fill"
        case .current: "checkmark.circle.fill"
        case .review: "doc.text.magnifyingglass"
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
