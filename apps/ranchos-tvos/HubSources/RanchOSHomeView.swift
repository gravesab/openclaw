import SwiftUI

#if !os(tvOS)
private enum RanchOSDestination: Hashable {
    case home
    case jarvis
    case module(RanchOSModule)
}

/// Mac/iPad detail selection. Top-level choices clear the sample-animal browser.
private struct RanchOSHubNavigation: Equatable, Hashable {
    var destination: RanchOSDestination = .home
    var showsSampleAnimals = false

    mutating func select(_ destination: RanchOSDestination) {
        self.destination = destination
        showsSampleAnimals = false
    }

    mutating func showSampleAnimals() {
        destination = .module(.livestock)
        showsSampleAnimals = true
    }
}

private enum RanchOSCompactRoute: Hashable {
    case jarvis
    case module(String)
    case sampleAnimals
    case sampleAnimal(String)
}

struct RanchOSHomeView: View {
    let dashboard: RanchOSHubDashboard
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore
    @Binding var appearance: RanchOSAppearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var navigation = RanchOSHubNavigation()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hasInitializedHome = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                RanchOSCompactHomeView(
                    dashboard: dashboard,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    appearance: $appearance)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    RanchOSSidebar(
                        dashboard: dashboard,
                        onSelect: { navigation.select($0) },
                        appearance: $appearance)
                } detail: {
                    // Detail content is chosen here. A NavigationLink push would stay
                    // visible after the sidebar changes selection.
                    Group {
                        switch navigation.destination {
                        case .home:
                            RanchOSDashboardView(dashboard: dashboard) { module in
                                navigation.select(.module(module))
                            }
                        case .jarvis:
                            RanchVADEVWorkspace(propertyStore: propertyStore).navigationTitle("Jarvis · DEV")
                        case .module(let module):
                            if module == .livestock, navigation.showsSampleAnimals {
                                RanchOSLivestockBrowserView(
                                    style: .embedded,
                                    onRevealSidebar: { columnVisibility = .all },
                                    onReturnHome: {
                                        navigation.select(.home)
                                        columnVisibility = .all
                                    },
                                    onCloseBrowser: {
                                        navigation.select(.module(.livestock))
                                    })
                            } else {
                                RanchOSModuleHostView(
                                    module: module,
                                    propertyStore: propertyStore,
                                    livestockStore: livestockStore,
                                    onReturnHome: {
                                        navigation.select(.home)
                                        columnVisibility = .all
                                    },
                                    onRevealSidebar: { columnVisibility = .all },
                                    sidebarHidden: columnVisibility == .detailOnly,
                                    onBrowseSampleAnimals: module == .livestock
                                        ? { navigation.showSampleAnimals() }
                                        : nil)
                            }
                        }
                    }
                    .id(navigation)
                    .toolbar {
                        if columnVisibility == .detailOnly {
                            ToolbarItem(placement: .navigation) {
                                Button {
                                    columnVisibility = .all
                                } label: {
                                    Label("Show sidebar", systemImage: "sidebar.left")
                                }
                                .accessibilityHint("Shows the RanchOS sidebar")
                            }
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .tint(RanchOSTheme.accent)
        .onAppear {
            guard !hasInitializedHome else { return }
            hasInitializedHome = true
            Task { @MainActor in
                navigation.select(.home)
            }
        }
    }
}

private struct RanchOSCompactHomeView: View {
    let dashboard: RanchOSHubDashboard
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore
    @Binding var appearance: RanchOSAppearance
    @State private var compactPath: [RanchOSCompactRoute] = []

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 18)]

    var body: some View {
        NavigationStack(path: $compactPath) {
            ZStack {
                RanchOSTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RANCHOS · DEVELOPMENT")
                                .font(.caption.weight(.bold))
                                .tracking(2.2)
                                .foregroundStyle(RanchOSTheme.olive)
                            Text("Welcome to RanchOS")
                                .font(.system(size: 36, weight: .bold, design: .serif))
                                .foregroundStyle(RanchOSTheme.ink)
                            Text("\(dashboard.tenantDisplayName)\n\(RanchOSBuildInfo.display)")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(RanchOSTheme.olive)
                        }

                        NavigationLink(value: RanchOSCompactRoute.jarvis) {
                            Label("Jarvis · DEV", systemImage: "sparkle")
                                .font(.headline).padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)

                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(dashboard.modules) { module in
                                NavigationLink(value: RanchOSCompactRoute.module(module.rawValue)) {
                                    RanchOSModuleCard(module: module)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(module.title)")
                            }
                        }

                        Label(RanchOSHubDashboard.developmentFixtureBanner, systemImage: "lock.shield")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("RanchOS")
            .navigationDestination(for: RanchOSCompactRoute.self) { route in
                compactDestination(route)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(RanchOSAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compactDestination(_ route: RanchOSCompactRoute) -> some View {
        switch route {
        case .jarvis:
            RanchVADEVWorkspace(propertyStore: propertyStore).navigationTitle("Jarvis · DEV")
        case .module(let rawValue):
            if let module = RanchOSModule(rawValue: rawValue) {
                RanchOSModuleHostView(
                    module: module,
                    propertyStore: propertyStore,
                    livestockStore: livestockStore,
                    onReturnHome: { compactPath.removeAll() },
                    onBrowseSampleAnimals: {
                        if !compactPath.contains(.sampleAnimals) {
                            compactPath.append(.sampleAnimals)
                        }
                    })
            }
        case .sampleAnimals:
            RanchOSLivestockBrowserView(
                style: .stacked,
                onReturnHome: { compactPath.removeAll() },
                onOpenAnimal: { animalID in
                    compactPath.removeAll { route in
                        if case .sampleAnimal = route { return true }
                        return false
                    }
                    compactPath.append(.sampleAnimal(animalID))
                },
                onAnimalCleared: {
                    compactPath.removeAll { route in
                        if case .sampleAnimal = route { return true }
                        return false
                    }
                })
        case .sampleAnimal(let animalID):
            RanchOSLivestockSampleDetailContainer(
                animal: RanchOSLivestockSampleCatalog.developmentSamples.first { $0.id == animalID },
                onReturnHome: { compactPath.removeAll() },
                showsNavigationTitle: true)
        }
    }
}

private struct RanchOSSidebar: View {
    let dashboard: RanchOSHubDashboard
    var onSelect: (RanchOSDestination) -> Void
    @Binding var appearance: RanchOSAppearance

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 20) {
                Label(dashboard.title, systemImage: "mountain.2")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundStyle(RanchOSTheme.cream)
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 2) {
                    Label(dashboard.tenantDisplayName, systemImage: "house")
                        .font(.headline)
                        .lineLimit(1)
                    Text(RanchOSBuildInfo.display)
                        .font(.caption)
                        .foregroundStyle(RanchOSTheme.cream.opacity(0.75))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(RanchOSTheme.cream)
                .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 20, trailing: 16))

            Button {
                onSelect(.home)
            } label: {
                Label("Home", systemImage: "house.fill")
                    .foregroundStyle(RanchOSTheme.cream)
            }
            .buttonStyle(.plain)

            Section("Assistant") {
                Button { onSelect(.jarvis) } label: {
                    Label("Jarvis · DEV", systemImage: "sparkle")
                        .foregroundStyle(RanchOSTheme.cream)
                }.buttonStyle(.plain)
            }

            Section("Applications") {
                ForEach(dashboard.modules) { module in
                    Button {
                        onSelect(.module(module))
                    } label: {
                        Label(module.title, systemImage: module.symbolName)
                            .foregroundStyle(RanchOSTheme.cream)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Display") {
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
}

private struct RanchOSDashboardView: View {
    let dashboard: RanchOSHubDashboard
    var onOpenModule: (RanchOSModule) -> Void

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
                                onOpenModule(module)
                            } label: {
                                RanchOSModuleCard(module: module)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(module.title)")
                        }
                    }

                    Label(RanchOSHubDashboard.developmentFixtureBanner, systemImage: "lock.shield")
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
            Text("RANCHOS · DEVELOPMENT")
                .font(.caption.weight(.bold))
                .tracking(2.2)
                .foregroundStyle(RanchOSTheme.olive)
            Text("Welcome to RanchOS")
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(RanchOSTheme.ink)
            Text("\(dashboard.tenantDisplayName)\n\(RanchOSBuildInfo.display)")
                .font(.title2.weight(.medium))
                .foregroundStyle(RanchOSTheme.olive)
        }
    }
}

private struct RanchOSModuleHostView: View {
    private let hostedModule: RanchOSHostedModule
    let propertyStore: RanchOSPropertyLiveStore
    let livestockStore: RanchOSLivestockStore
    var onReturnHome: () -> Void = {}
    var onRevealSidebar: () -> Void = {}
    var sidebarHidden = false
    var onBrowseSampleAnimals: (() -> Void)? = nil

    init(
        module: RanchOSModule,
        propertyStore: RanchOSPropertyLiveStore,
        livestockStore: RanchOSLivestockStore,
        onReturnHome: @escaping () -> Void = {},
        onRevealSidebar: @escaping () -> Void = {},
        sidebarHidden: Bool = false,
        onBrowseSampleAnimals: (() -> Void)? = nil
    ) {
        hostedModule = RanchOSModuleHost.developmentFixture.hostedModule(for: module)
        self.propertyStore = propertyStore
        self.livestockStore = livestockStore
        self.onReturnHome = onReturnHome
        self.onRevealSidebar = onRevealSidebar
        self.sidebarHidden = sidebarHidden
        self.onBrowseSampleAnimals = onBrowseSampleAnimals
    }

    var body: some View {
        switch hostedModule {
        case .property:
            RanchOSPropertyModuleView(propertyStore: propertyStore)
        case .livestock:
            RanchOSLivestockModuleView(
                store: livestockStore,
                onReturnHome: onReturnHome,
                onRevealSidebar: onRevealSidebar,
                sidebarHidden: sidebarHidden,
                onBrowseSampleAnimals: onBrowseSampleAnimals)
        case .finance(let dashboard):
            RanchOSFinanceModuleView(dashboard: dashboard)
        }
    }
}

private struct RanchOSPropertyModuleView: View {
    let propertyStore: RanchOSPropertyLiveStore

    var body: some View {
        ZStack {
            RanchOSTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("PROPERTY MANAGER · READ ONLY", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(RanchOSTheme.olive)
                        Text("Property overview")
                            .font(.system(size: 40, weight: .bold, design: .serif))
                            .foregroundStyle(RanchOSTheme.ink)
                        Text("Ranch OS DEV · Live PropertyManager")
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
            Label("\(dashboard.activeTaskCount) active tasks · \(dashboard.attentionCount) need attention", systemImage: "checkmark.icloud")
                .font(.headline)
                .foregroundStyle(RanchOSTheme.ink)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))

            VStack(spacing: 12) {
                ForEach(Array(dashboard.tasks.filter(\.isActive).prefix(12))) { task in
                    RanchOSPropertyLiveTaskCard(task: task)
                }
            }

            Label("Live DEV data · read only. RanchOS cannot create, complete, edit, or delete PropertyManager records.", systemImage: "lock.shield")
                .font(.footnote.weight(.medium))
                .foregroundStyle(RanchOSTheme.mutedInk)
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
    var onReturnHome: () -> Void = {}
    var onRevealSidebar: () -> Void = {}
    var sidebarHidden = false
    var onBrowseSampleAnimals: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RanchOSTheme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
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
        .toolbar {
            if sidebarHidden {
                ToolbarItem(placement: .navigation) {
                    Button {
                        onRevealSidebar()
                    } label: {
                        Label("Show sidebar", systemImage: "sidebar.left")
                    }
                    .accessibilityHint("Shows the RanchOS sidebar")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onReturnHome()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .accessibilityHint("Returns to RanchOS Home")
            }
        }
        .task { await store.load() }
    }

    private var subtitle: String {
        switch store.presentation {
        case .fixture(let dashboard), .available(let dashboard):
            dashboard.ranchName
        case .loading, .unavailable, .retryable:
            "Ranch OS DEV"
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
        Label(RanchOSLivestockConnection.pendingLabel, systemImage: "lock.shield")
            .font(.footnote.weight(.medium))
            .foregroundStyle(RanchOSTheme.mutedInk)
        if RanchOSLivestockBrowserModel.isBrowsingEligible(store.presentation), let onBrowseSampleAnimals {
            Button(action: onBrowseSampleAnimals) {
                sampleBrowseLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browse sample animals")
            .accessibilityHint("Opens read-only DEV fixture sample animals")
        }
    }

    private var sampleBrowseLabel: some View {
        Label("Browse sample animals", systemImage: "list.bullet")
            .font(.headline)
            .foregroundStyle(RanchOSTheme.ink)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
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
                        Label("FINANCE · READ ONLY", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .tracking(1.6)
                            .foregroundStyle(RanchOSTheme.olive)
                        Text("Financial overview")
                            .font(.system(size: 40, weight: .bold, design: .serif))
                            .foregroundStyle(RanchOSTheme.ink)
                        Text(dashboard.ranchName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(RanchOSTheme.mutedInk)
                    }

                    Label("Household and ranch, together", systemImage: "chart.bar.doc.horizontal")
                        .font(.headline)
                        .foregroundStyle(RanchOSTheme.ink)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.19, green: 0.35, blue: 0.44).opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

                    VStack(spacing: 12) {
                        ForEach(dashboard.summaries) { summary in
                            RanchOSFinanceSummaryCard(summary: summary)
                        }
                    }

                    Label(
                        "Read-only development fixture · No accounts, transactions, or budgets can be changed here.",
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

    private var moduleConnectionLabel: String {
        switch module {
        case .property: "Live DEV data · read only"
        case .livestock: RanchOSLivestockConnection.pendingLabel
        case .finance: "Development fixture"
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
