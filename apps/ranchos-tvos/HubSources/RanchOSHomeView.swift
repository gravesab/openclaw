import SwiftUI

#if !os(tvOS)
private enum RanchOSDestination: Hashable {
    case home
    case module(RanchOSModule)
    case people
}

struct RanchOSHomeView: View {
    let dashboard: RanchOSHubDashboard
    let liveSession: RanchOSLiveSession
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore
    let peopleDirectory: RanchOSPeopleDirectory
    @Binding var appearance: RanchOSAppearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: RanchOSDestination = .home
    @State private var hasInitializedHome = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                RanchOSCompactHomeView(
                    dashboard: dashboard,
                    liveSession: liveSession,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    peopleDirectory: peopleDirectory,
                    appearance: $appearance)
            } else {
                NavigationSplitView {
                    RanchOSSidebar(
                        dashboard: dashboard,
                        liveSession: liveSession,
                        selection: $selection,
                        appearance: $appearance)
                } detail: {
                    NavigationStack {
                        switch selection {
                        case .home:
                            RanchOSDashboardView(dashboard: dashboard, selection: $selection)
                        case .module(let module):
                            RanchOSModuleHostView(
                                module: module,
                                propertyStore: propertyStore,
                                livestockStore: livestockStore)
                        case .people:
                            RanchOSPeopleView(directory: peopleDirectory)
                        }
                    }
                }
            }
        }
        .tint(RanchOSTheme.accent)
        .onAppear {
            guard !hasInitializedHome else { return }
            hasInitializedHome = true
            Task { @MainActor in
                selection = .home
            }
        }
    }
}

private struct RanchOSCompactHomeView: View {
    let dashboard: RanchOSHubDashboard
    let liveSession: RanchOSLiveSession
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore
    let peopleDirectory: RanchOSPeopleDirectory
    @Binding var appearance: RanchOSAppearance
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 18)]

    var body: some View {
        NavigationStack {
            ZStack {
                RanchOSTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            RanchOSDevIdentityBadge(style: .canvas)
                            Text("Welcome to RanchOS")
                                .font(.system(size: 36, weight: .bold, design: .serif))
                                .foregroundStyle(RanchOSTheme.ink)
                            Text(RanchOSBuildInfo.display(for: environment))
                                .font(.title3.weight(.medium))
                                .foregroundStyle(RanchOSTheme.olive)
                        }

                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(dashboard.modules) { module in
                                NavigationLink {
                                    RanchOSModuleHostView(
                                        module: module,
                                        propertyStore: propertyStore,
                                        livestockStore: livestockStore)
                                } label: {
                                    RanchOSModuleCard(module: module)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(module.title)")
                            }
                        }

                        NavigationLink {
                            RanchOSPeopleView(directory: peopleDirectory)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("People")
                                        .font(.headline)
                                        .foregroundStyle(RanchOSTheme.ink)
                                    Text("Who can open this ranch.")
                                        .font(.subheadline)
                                        .foregroundStyle(RanchOSTheme.mutedInk)
                                }
                            } icon: {
                                Image(systemName: "person.2")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(RanchOSTheme.olive, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open People")

                        RanchOSForecastBriefCard()

                        Label(environment.hubBanner, systemImage: "lock.shield")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }
                    .padding(24)
                }
            }
            .navigationTitle(environment.productName)
            .toolbar {
                ToolbarItem(placement: RanchOSDevIdentityBadge.toolbarPlacement) {
                    RanchOSDevIdentityBadge(style: .toolbar)
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        RanchOSLiveDataSourcePicker(session: liveSession)
                        Picker("Appearance", selection: $appearance) {
                            ForEach(RanchOSAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Live data and appearance", systemImage: "circle.lefthalf.filled")
                    }
                }
            }
        }
    }
}

private struct RanchOSSidebar: View {
    let dashboard: RanchOSHubDashboard
    let liveSession: RanchOSLiveSession
    @Binding var selection: RanchOSDestination
    @Binding var appearance: RanchOSAppearance
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    var body: some View {
        List(selection: sidebarSelection) {
            VStack(alignment: .leading, spacing: 20) {
                Label(dashboard.title, systemImage: "mountain.2")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundStyle(RanchOSTheme.cream)
                    .padding(.top, 20)

                RanchOSDevIdentityBadge(style: .sidebar)

                Label(RanchOSBuildInfo.display(for: environment), systemImage: "house")
                    .font(.headline)
                    .foregroundStyle(RanchOSTheme.cream)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 20, trailing: 16))

            Label("Home", systemImage: "house.fill")
                .foregroundStyle(RanchOSTheme.cream)
                .tag(RanchOSDestination.home)

            Section("Applications") {
                ForEach(dashboard.modules) { module in
                    Label(module.title, systemImage: module.symbolName)
                        .foregroundStyle(RanchOSTheme.cream)
                        .tag(RanchOSDestination.module(module))
                }
            }

            Section("Ranch") {
                Label("People", systemImage: "person.2")
                    .foregroundStyle(RanchOSTheme.cream)
                    .tag(RanchOSDestination.people)
            }

            Section("Live data") {
                RanchOSLiveDataSourcePicker(session: liveSession)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(RanchOSAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RanchOSTheme.sidebar.ignoresSafeArea())
        .navigationTitle("")
    }

    private var sidebarSelection: Binding<RanchOSDestination?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue {
                    selection = newValue
                }
            })
    }
}

private struct RanchOSDashboardView: View {
    let dashboard: RanchOSHubDashboard
    @Binding var selection: RanchOSDestination
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 18)]

    var body: some View {
        ZStack {
            RanchOSTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(dashboard.modules) { module in
                            Button {
                                selection = .module(module)
                            } label: {
                                RanchOSModuleCard(module: module)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(module.title)")
                        }
                    }

                    RanchOSForecastBriefCard()

                    Label(environment.hubBanner, systemImage: "lock.shield")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(RanchOSTheme.mutedInk)
                }
                .padding(32)
            }
        }
        .navigationTitle("Home")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            RanchOSDevIdentityBadge(style: .canvas)
            Text("Welcome to RanchOS")
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(RanchOSTheme.ink)
            Text(RanchOSBuildInfo.display(for: environment))
                .font(.title2.weight(.medium))
                .foregroundStyle(RanchOSTheme.olive)
        }
    }
}

private struct RanchOSModuleHostView: View {
    private let hostedModule: RanchOSHostedModule
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore

    init(module: RanchOSModule, propertyStore: RanchOSPropertyLiveStore, livestockStore: RanchOSLivestockStore) {
        hostedModule = RanchOSModuleHost.developmentFixture.hostedModule(for: module)
        self.propertyStore = propertyStore
        self.livestockStore = livestockStore
    }

    var body: some View {
        switch hostedModule {
        case .property:
            RanchOSPropertyModuleView(propertyStore: propertyStore)
        case .livestock:
            RanchOSLivestockModuleView(store: livestockStore)
        case .finance(let dashboard):
            RanchOSFinanceModuleView(dashboard: dashboard)
        }
    }
}

private struct RanchOSPropertyModuleView: View {
    let propertyStore: RanchOSPropertyLiveStore
    @State private var selectedCategory: RanchOSPropertyDueTaskCategoryFilter = .all
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    var body: some View {
        ZStack {
            RanchOSTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        RanchOSDevIdentityBadge(style: .canvas)
                        Label("PROPERTY MANAGER · READ ONLY", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(RanchOSTheme.olive)
                        Text("Property overview")
                            .font(.system(size: 40, weight: .bold, design: .serif))
                            .foregroundStyle(RanchOSTheme.ink)
                        Text("\(environment.tenantDisplayName) · Live PropertyManager")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }

                    propertyContent
                }
                .padding(32)
            }
        }
        .navigationTitle("Property Manager")
        .task { await propertyStore.refresh() }
        .onChange(of: propertyStore.state) { _, newState in
            if case .ready(let dashboard) = newState {
                selectedCategory = dashboard.resolvedFilter(selectedCategory)
            }
        }
    }

    @ViewBuilder
    private var propertyContent: some View {
        switch propertyStore.state {
        case .loading:
            ProgressView("Loading PropertyManager DEV…")
                .frame(maxWidth: .infinity, minHeight: 180)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(RanchOSTheme.mutedInk)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        case .ready(let dashboard):
            let filter = dashboard.resolvedFilter(selectedCategory)
            let dueTasks = dashboard.dueTasks(matching: filter)

            Label("\(dashboard.activeTaskCount) active tasks · \(dashboard.attentionCount) need attention", systemImage: "checkmark.icloud")
                .font(.headline)
                .foregroundStyle(RanchOSTheme.ink)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))

            RanchOSPropertyDueTaskCategoryPicker(
                filters: dashboard.dueTaskCategoryFilters,
                selection: $selectedCategory)

            Label(dueTaskSummary(filter: filter, count: dueTasks.count), systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RanchOSTheme.olive)
                .accessibilityLabel(dueTaskSummary(filter: filter, count: dueTasks.count))

            if dueTasks.isEmpty {
                Label("No due tasks match this category.", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
                    .foregroundStyle(RanchOSTheme.mutedInk)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
            } else {
                VStack(spacing: 12) {
                    ForEach(dueTasks) { task in
                        RanchOSPropertyLiveTaskCard(task: task)
                    }
                }
            }

            Label(environment.propertyLiveFooter, systemImage: "lock.shield")
                .font(.footnote.weight(.medium))
                .foregroundStyle(RanchOSTheme.mutedInk)
        }
    }

    private func dueTaskSummary(filter: RanchOSPropertyDueTaskCategoryFilter, count: Int) -> String {
        switch filter {
        case .all:
            "\(count) due tasks"
        case .category(let name):
            "\(count) due tasks in \(name)"
        }
    }
}

private struct RanchOSPropertyLiveTaskCard: View {
    let task: RanchOSPropertyLiveTask

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.headline).foregroundStyle(RanchOSTheme.ink)
                Text(task.detail).font(.subheadline).foregroundStyle(RanchOSTheme.mutedInk)
            }
            Spacer()
            Text(statusTitle).font(.caption.weight(.bold)).foregroundStyle(color)
        }
        .padding(18)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
    }

    private var color: Color {
        switch task.status {
        case .needsAttention: RanchOSTheme.accent
        case .upcoming: RanchOSTheme.olive
        case .current: Color(red: 0.19, green: 0.42, blue: 0.30)
        }
    }

    private var iconName: String { task.status == .needsAttention ? "exclamationmark.triangle.fill" : "calendar" }
    private var statusTitle: String { task.status == .needsAttention ? "Needs attention" : "Scheduled" }
}

private struct RanchOSPropertyAssetSnapshotView: View {
    let snapshot: RanchOSPropertyAssetSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                RanchOSTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("PROPERTY SNAPSHOT · READ ONLY", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(RanchOSTheme.olive)

                        Text(snapshot.title)
                            .font(.system(size: 36, weight: .bold, design: .serif))
                            .foregroundStyle(RanchOSTheme.ink)

                        RanchOSPropertySnapshotSection(
                            title: "Last checked",
                            detail: snapshot.lastChecked,
                            symbolName: "checkmark.circle")
                        RanchOSPropertySnapshotSection(
                            title: "Next action",
                            detail: snapshot.nextAction,
                            symbolName: "calendar")
                        RanchOSPropertySnapshotSection(
                            title: "Fixture boundary",
                            detail: snapshot.note,
                            symbolName: "lock.shield")
                    }
                    .padding(28)
                }
            }
            .navigationTitle("Property snapshot")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RanchOSPropertySnapshotSection: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(RanchOSTheme.mutedInk)
            }
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(RanchOSTheme.olive)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct RanchOSPropertySummaryCard: View {
    let summary: RanchOSPropertySummary

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 48, height: 48)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(RanchOSTheme.ink)
                Text(summary.detail)
                    .font(.subheadline)
                    .foregroundStyle(RanchOSTheme.mutedInk)
            }

            Spacer()

            Text(summary.status.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(18)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.84), lineWidth: 1)
        }
    }

    private var statusColor: Color {
        switch summary.status {
        case .needsAttention: RanchOSTheme.accent
        case .upcoming: RanchOSTheme.olive
        case .current: Color(red: 0.19, green: 0.42, blue: 0.30)
        }
    }

    private var iconName: String {
        switch summary.status {
        case .needsAttention: "exclamationmark.triangle.fill"
        case .upcoming: "calendar"
        case .current: "checkmark.circle.fill"
        }
    }
}

private struct RanchOSLivestockModuleView: View {
    let store: RanchOSLivestockStore
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    var body: some View {
        ZStack {
            RanchOSTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        RanchOSDevIdentityBadge(style: .canvas)
                        Label("LIVESTOCK · READ ONLY", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(RanchOSTheme.olive)
                        Text("Herd overview")
                            .font(.system(size: 40, weight: .bold, design: .serif))
                            .foregroundStyle(RanchOSTheme.ink)
                        Text(subtitle)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }

                    livestockContent
                }
                .padding(32)
            }
        }
        .navigationTitle("Livestock")
        .task { await store.load() }
    }

    private var subtitle: String {
        switch store.presentation {
        case .fixture(let dashboard), .available(let dashboard):
            dashboard.ranchName
        case .loading, .unavailable, .retryable:
            environment.tenantDisplayName
        }
    }

    @ViewBuilder
    private var livestockContent: some View {
        switch store.presentation {
        case .fixture(let dashboard):
            livestockFixtureContent(dashboard)
        case .loading:
            ProgressView("Loading Livestock…")
                .frame(maxWidth: .infinity, minHeight: 180)
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 16) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(RanchOSTheme.mutedInk)
                if store.canRetry {
                    Button("Retry") {
                        Task { await store.load() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        case .retryable:
            Button("Retry") {
                Task { await store.load() }
            }
            .buttonStyle(.bordered)
        case .available(let dashboard):
            livestockDashboardCards(dashboard)
            Label(store.presentation.banner, systemImage: "lock.shield")
                .font(.footnote.weight(.medium))
                .foregroundStyle(RanchOSTheme.mutedInk)
        }
    }

    @ViewBuilder
    private func livestockFixtureContent(_ dashboard: RanchOSLivestockDashboard) -> some View {
        livestockDashboardCards(dashboard)
        Label(environment.livestockPendingLabel, systemImage: "lock.shield")
            .font(.footnote.weight(.medium))
            .foregroundStyle(RanchOSTheme.mutedInk)
        if RanchOSLivestockBrowserModel.isBrowsingEligible(store.presentation) {
            NavigationLink {
                RanchOSLivestockBrowserView()
            } label: {
                Label("Browse sample animals", systemImage: "list.bullet")
                    .font(.headline)
                    .foregroundStyle(RanchOSTheme.ink)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
            }
            .accessibilityLabel("Browse sample animals")
            .accessibilityHint("Opens read-only DEV fixture sample animals")
        }
    }

    @ViewBuilder
    private func livestockDashboardCards(_ dashboard: RanchOSLivestockDashboard) -> some View {
        HStack(spacing: 14) {
            Label("\(dashboard.herdCount) animals", systemImage: "cow.fill")
            Label("2 care reminders", systemImage: "bell.fill")
        }
        .font(.headline)
        .foregroundStyle(RanchOSTheme.ink)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.40, green: 0.24, blue: 0.14).opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

        VStack(spacing: 12) {
            ForEach(dashboard.summaries) { summary in
                RanchOSLivestockSummaryCard(summary: summary)
            }
        }
    }
}

private struct RanchOSLivestockSummaryCard: View {
    let summary: RanchOSLivestockSummary

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 48, height: 48)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(RanchOSTheme.ink)
                Text(summary.detail)
                    .font(.subheadline)
                    .foregroundStyle(RanchOSTheme.mutedInk)
            }

            Spacer()

            Text(summary.status.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(18)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.84), lineWidth: 1)
        }
    }

    private var statusColor: Color {
        switch summary.status {
        case .careDue: RanchOSTheme.accent
        case .current: Color(red: 0.19, green: 0.42, blue: 0.30)
        case .review: RanchOSTheme.olive
        }
    }

    private var iconName: String {
        switch summary.status {
        case .careDue: "bell.fill"
        case .current: "checkmark.circle.fill"
        case .review: "doc.text.magnifyingglass"
        }
    }
}

private struct RanchOSFinanceModuleView: View {
    let dashboard: RanchOSFinanceDashboard

    var body: some View {
        ZStack {
            RanchOSTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        RanchOSDevIdentityBadge(style: .canvas)
                        Label("FINANCE · REPORT SUMMARY", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(RanchOSTheme.olive)
                        Text("Report summary")
                            .font(.system(size: 40, weight: .bold, design: .serif))
                            .foregroundStyle(RanchOSTheme.ink)
                        Text(dashboard.ranchName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }

                    Label(RanchOSFinanceDashboard.disconnectedCardLabel, systemImage: "chart.bar.doc.horizontal")
                        .font(.headline)
                        .foregroundStyle(RanchOSTheme.ink)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.19, green: 0.35, blue: 0.44).opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

                    if dashboard.summaries.isEmpty {
                        Label("No finance reports are loaded. This screen will summarize reports from the Finance application after that DEV app is mostly completed.", systemImage: "doc.text")
                            .font(.subheadline)
                            .foregroundStyle(RanchOSTheme.mutedInk)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
                    } else {
                        VStack(spacing: 12) {
                            ForEach(dashboard.summaries) { summary in
                                RanchOSFinanceSummaryCard(summary: summary)
                            }
                        }
                    }

                    Label(
                        RanchOSFinanceDashboard.disconnectedBanner,
                        systemImage: "lock.shield")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(RanchOSTheme.mutedInk)
                }
                .padding(32)
            }
        }
        .navigationTitle("Finance")
    }
}

private struct RanchOSFinanceSummaryCard: View {
    let summary: RanchOSFinanceSummary

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 48, height: 48)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(RanchOSTheme.ink)
                Text(summary.detail)
                    .font(.subheadline)
                    .foregroundStyle(RanchOSTheme.mutedInk)
            }

            Spacer()

            Text(summary.status.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(18)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.84), lineWidth: 1)
        }
    }

    private var statusColor: Color {
        switch summary.status {
        case .ready: Color(red: 0.19, green: 0.35, blue: 0.44)
        case .review: RanchOSTheme.olive
        case .upcoming: RanchOSTheme.accent
        }
    }

    private var iconName: String {
        switch summary.status {
        case .ready: "checkmark.circle.fill"
        case .review: "doc.text.magnifyingglass"
        case .upcoming: "calendar"
        }
    }
}

private struct RanchOSModuleCard: View {
    let module: RanchOSModule
    @Environment(\.ranchOSRuntimeEnvironment) private var environment

    private var moduleConnectionLabel: String {
        switch module {
        case .property: environment.propertyLiveCardLabel
        case .livestock: environment.livestockPendingLabel
        case .finance: RanchOSFinanceDashboard.disconnectedCardLabel
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: module.symbolName)
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(module.tint, in: RoundedRectangle(cornerRadius: 18))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(RanchOSTheme.olive)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.56), in: Circle())
            }

            Spacer(minLength: 18)

            Text(module.title)
                .font(.system(.title2, design: .serif).weight(.bold))
                .foregroundStyle(RanchOSTheme.ink)
            Text(module.detail)
                .font(.subheadline)
                .foregroundStyle(RanchOSTheme.mutedInk)
                .multilineTextAlignment(.leading)
            Label(moduleConnectionLabel, systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RanchOSTheme.olive)
        }
        .frame(maxWidth: .infinity, minHeight: 248, alignment: .leading)
        .padding(24)
        .background(module.cardGradient, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.68), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

private enum RanchOSTheme {
    static let sidebar = Color(red: 0.06, green: 0.15, blue: 0.12)
    static let canvas = LinearGradient(
        colors: [Color(red: 0.98, green: 0.97, blue: 0.92), Color(red: 0.91, green: 0.93, blue: 0.84)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.86)
    static let ink = Color(red: 0.09, green: 0.13, blue: 0.10)
    static let mutedInk = Color(red: 0.28, green: 0.33, blue: 0.27)
    static let olive = Color(red: 0.30, green: 0.40, blue: 0.25)
    static let accent = Color(red: 0.69, green: 0.51, blue: 0.12)
}

private extension RanchOSModule {
    var tint: Color {
        switch self {
        case .property: RanchOSTheme.olive
        case .livestock: Color(red: 0.36, green: 0.22, blue: 0.13)
        case .finance: Color(red: 0.19, green: 0.35, blue: 0.44)
        }
    }

    var cardGradient: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.88), tint.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}
#endif
