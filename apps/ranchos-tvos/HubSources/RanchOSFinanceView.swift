import Charts
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Finance screen. Recent transactions lists what was just ingested. Accounts
/// is where each institution is added and its statement is brought in. History
/// lists statements already assigned and archived. Categories lists each
/// category and the vendors assigned to it. Charts totals expenses by
/// category. By week is 52 weeks, by month is 12 months, and semi-annual is
/// the six months of that half. Reports summarizes one month for one account.
/// The Mac and iPad present this screen. The iPhone shows the monthly report.
/// tvOS compiles this file and never presents it.
struct RanchOSFinanceScreen: View {
    private enum Page: Hashable {
        case recent
        case accounts
        case history
        case categories
        case charts
        case reports
    }

    @State private var store = RanchOSFinanceStore()
    @State private var page = Page.recent
    @State private var showingImporter = false
    @State private var newCategoryName = ""
    @State private var chartNewCategoryName = ""
    @State private var showingAddAccount = false
    @State private var loanNameDrafts: [UUID: String] = [:]
    @FocusState private var focusedLoanName: UUID?
    @State private var linkDrafts: [UUID: String] = [:]
    @State private var linkProblems: [UUID: String] = [:]
    @FocusState private var focusedLink: UUID?
    @State private var editingLinks: Set<UUID> = []
    @State private var accountPendingRemoval: RanchOSFinanceAccount?
    @State private var statementGuide: RanchOSFinanceAccount?
#if os(macOS)
    @State private var statementWatch: RanchOSFinanceStatementWatch?
#endif
    @State private var fileNotice: String?
    @Environment(\.openURL) private var openURL
    @State private var importAccount: RanchOSFinanceAccount?
    @State private var pendingFileName = ""
    @State private var pendingBytes: Data?
    @State private var sourceDraft = ""
    @State private var archivePrompt: RanchOSFinanceArchivePrompt?
    @State private var dismissedArchiveOffers: Set<String> = []
    @State private var chartAccount = RanchOSFinanceChartAccountFilter.all
    @State private var chartAllCategories = true
    @State private var chartCategoryIDs: Set<UUID> = []
    @State private var chartTime = RanchOSFinanceChartTime.allDates
    @State private var chartYear: Int?
    @State private var chartHalf: Int?
    @State private var chartDayMonth: Int?
    @State private var chartPeriodsAll = true
    @State private var chartPeriodIDs: Set<String> = []
    @State private var chartShow = ChartShow.allExpenses
    @State private var newProfileName = ""
    @State private var chartDraft = false
    @State private var chartDraftCategoryIDs: Set<UUID> = []
    @State private var chartDraftMessage: String?
    @State private var categoryListToken = 0
    @State private var chartHideZeros = false
    @State private var chartDrillCategoryID: UUID?

    private enum ChartShow: Hashable {
        case allExpenses
        case income
        case profile(UUID)
    }

    @ViewBuilder
    private var financePageBar: some View {
#if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(financePages, id: \.page) { item in
                    Button(item.title) { page = item.page }
                        .buttonStyle(.bordered)
                        .tint(page == item.page ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
#else
        Picker("Finance page", selection: $page) {
            Text("Recent transactions").tag(Page.recent)
            Text("Accounts").tag(Page.accounts)
            Text("History").tag(Page.history)
            Text("Categories").tag(Page.categories)
            Text("Charts").tag(Page.charts)
            Text("Reports").tag(Page.reports)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
#if os(tvOS)
        .background(.regularMaterial)
#else
        .background(.bar)
#endif
#endif
    }

#if os(iOS)
    /// iPhone cannot fit six full names in one segmented control, so each
    /// name stays whole and the row scrolls.
    private var financePages: [(page: Page, title: String)] {
        [
            (.recent, "Recent"),
            (.accounts, "Accounts"),
            (.history, "History"),
            (.categories, "Categories"),
            (.charts, "Charts"),
            (.reports, "Reports"),
        ]
    }
#endif

    var body: some View {
        NavigationStack {
            Group {
                if page == .charts {
                    chartPage
                } else if page == .reports {
                    RanchOSFinanceReportsPage(store: store)
                } else if page == .categories {
                    RanchOSFinanceCategoryVendorsView(store: store)
                } else {
                    List {
                        switch page {
                        case .recent:
                            recentContent
                        case .accounts:
                            accountsContent
                        case .history:
                            historyContent
                        case .categories, .charts, .reports:
                            EmptyView()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                financePageBar
            }
            .navigationTitle("Finance")
            .onAppear { presentArchivePrompt() }
            .onChange(of: page) { _, newPage in
                if newPage == .recent { presentArchivePrompt() }
            }
            .sheet(isPresented: $showingAddAccount) {
                RanchOSFinanceAddAccountSheet(store: store)
            }
#if os(macOS)
            .sheet(item: $statementGuide, onDismiss: stopStatementWatch) { account in
                RanchOSFinanceStatementGuideSheet(
                    accountName: store.accountDisplayName(account),
                    link: account.downloadURL.flatMap(URL.init(string:)),
                    folder: RanchOSFinanceAccountFolders.ensure(account, among: store.ledger.accounts),
                    watching: statementWatch != nil,
                    onOpenPage: openInBrowser,
                    onChoose: {
                        chooseManually(for: account)
                    })
            }
#endif
            .alert(
                accountPendingRemoval.map { "Remove \(store.accountLabel($0))?" } ?? "Remove account?",
                isPresented: Binding(
                    get: { accountPendingRemoval != nil },
                    set: { if !$0 { accountPendingRemoval = nil } }),
                presenting: accountPendingRemoval
            ) { account in
                Button("Remove account", role: .destructive) {
                    store.deleteAccount(id: account.id)
                    accountPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    accountPendingRemoval = nil
                }
            } message: { account in
                Text(store.accountRemovalConsequences(id: account.id).map { "• \($0)" }.joined(separator: "\n")
                    + "\n\nRemove it only if you are sure.")
            }
            .sheet(item: $archivePrompt) { prompt in
                RanchOSFinanceArchivePromptSheet(prompt: prompt) {
                    moveEarlierMonths()
                    page = .history
                } onDismiss: {
                    dismissedArchiveOffers.formUnion(prompt.offers.map(\.id))
                }
            }
#if !os(tvOS)
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText]
            ) { result in
                ingest(result: result)
            }
            .sheet(isPresented: pendingPresented) {
                RanchOSFinanceSourceSheet(fileName: pendingFileName, sourceDraft: $sourceDraft) { source in
                    if let source {
                        let outcome = store.ingest(fileName: pendingFileName, bytes: pendingBytes ?? Data(), source: source)
                        noteImport(outcome)
                    }
                    pendingBytes = nil
                    sourceDraft = ""
                }
            }
#endif
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        if let fileNotice {
            Section("Statement file") {
                Text(fileNotice)
                    .font(.subheadline)
                Button("Dismiss") { self.fileNotice = nil }
            }
        }
        let ready = store.accountsReadyToArchive()
        if !ready.isEmpty {
            Section("Clear earlier months") {
                Text("The latest month stays in Recent. Check categories on everything earlier, then move those months to History. History keeps the category each transaction has now. Vendors used only on those earlier months leave the Vendors list and keep their category. Categories and Add category stay at the bottom. Recent then shows only the latest month.")
#if os(iOS)
                    .font(.footnote)
#else
                    .font(.subheadline)
#endif
                    .foregroundStyle(.secondary)
                Text(earlierMonthSummary(ready))
                    .font(.subheadline)
                Button(earlierMonthButton(ready)) {
                    moveEarlierMonths()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        let openGroups = store.recentAccountGroups()
        if openGroups.isEmpty {
            Section {
                Text(
                    store.ledger.charges.isEmpty
                        ? "No transactions yet. Pull a statement from Accounts, or choose a CSV."
                        : "Recent transactions are the ones that have not been moved to History."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        ForEach(openGroups) { group in
            Section(group.title) {
                ForEach(group.charges) { charge in
                    RanchOSFinanceChargeRow(store: store, charge: charge)
                }
            }
        }
        Section("Months already in") {
            let months = store.monthsAlreadyIn()
            if months.isEmpty {
                Text("No transaction dates yet. Choose a CSV to begin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(coverageSources(months), id: \.self) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Text(source)
                        .font(.subheadline.weight(.medium))
                    Text(coverageLine(source: source, months: months))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section("Cost by thing") {
            NavigationLink {
                RanchOSFinanceCostView(store: store)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Targets and unallocated charges")
                        .font(.subheadline.weight(.medium))
                    Text("\(store.costByTarget().count) targets · \(store.chargesWithUnallocated().count) need allocation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section("Files") {
            if store.ledger.files.isEmpty {
                Text("No statements yet. Choose a CSV to begin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.ledger.files) { file in
                NavigationLink {
                    RanchOSFinanceFileView(store: store, fileID: file.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.fileName)
                            .font(.subheadline.weight(.medium))
                        Text("\(file.source ?? RanchOSFinanceDates.missingSource) · \(store.dateRangeLabel(fileID: file.id)) · \(file.rowCount) rows · \(file.errorCount) errors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
#if !os(tvOS)
            Button("Choose file") { showingImporter = true }
                .accessibilityHint("Opens a CSV statement from Apple Card or a bank")
#else
            Text("Use iPhone or Mac to add files.")
                .foregroundStyle(.secondary)
#endif
        }
        Section("Vendors") {
            let vendors = store.recentVendors()
            if vendors.isEmpty {
                Text(store.ledger.vendors.isEmpty
                    ? "Vendors appear after the first import."
                    : "No vendors on Recent. The Categories page lists every vendor.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(vendors) { vendor in
                NavigationLink {
                    RanchOSFinanceVendorView(store: store, vendorID: vendor.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vendor.name)
                            .font(.subheadline.weight(.medium))
                        Text(categoryName(vendor.categoryID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("Charges") {
            NavigationLink {
                RanchOSFinanceBulkAssignView(store: store)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assign selected charges")
                        .font(.subheadline.weight(.medium))
                    Text("Filter by vendor, then apply one category. The vendor rule stays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section("Categories") {
            ForEach(deletableCategories) { category in
                RanchOSFinanceCategoryRow(store: store, categoryID: category.id) {
                    _ = store.deleteCategory(id: category.id)
                }
            }
            if let uncategorized = store.ledger.categories.first(where: \.isUncategorized) {
                RanchOSFinanceCategoryRow(store: store, categoryID: uncategorized.id)
            }
            HStack {
                TextField("New category", text: $newCategoryName)
#if os(iOS)
                    .font(.subheadline)
#endif
#if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    .onSubmit { addCategory() }
                    .ranchEntry($newCategoryName)
                Button("Add") { addCategory() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var accountsContent: some View {
        Section {
#if os(iOS)
            Text("Add account asks for the type, then the institution. RanchOS does not sign in. Open the download page, get the CSV, then tap Import statement and choose that file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
#else
            Text("Add account asks for the type, then the institution for that type. RanchOS checks whether it can sign in and download. When it cannot, import the file you downloaded. Statement files are kept on T2 WD X, in RanchOS Account Transactions, one folder per account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
#endif
        }
        Section("Accounts") {
#if os(macOS)
            if !RanchOSFinanceAccountFolders.volumeIsMounted {
                Text("T2 WD X is not connected, so the account folders cannot be opened.")
                    .foregroundStyle(.secondary)
            }
#endif
            if store.ledger.accounts.isEmpty {
                Text("No accounts yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.accountsByName) { account in
                let check = RanchOSFinanceAccountCatalog.automation(
                    kind: account.kind ?? .other, name: account.name)
                let count = store.charges(forAccount: account.id).count
                VStack(alignment: .leading, spacing: 8) {
                    if store.loanNameWasTyped(account) {
                        Text("Account name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            "Account name",
                            text: loanNameDraft(account),
                            prompt: Text("Account name")
                        )
                        .font(.headline)
                        .focused($focusedLoanName, equals: account.id)
                        .onSubmit { commitLoanName(account.id) }
                        .onChange(of: focusedLoanName) { _, focused in
                            if focused != account.id { commitLoanName(account.id) }
                        }
#if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .ranchEntry(loanNameDraft(account))
                    } else {
                        Text(account.name)
                            .font(.headline)
                    }
                    Text(account.kind?.label ?? "Account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if account.kind == .loan {
                        TextField(
                            "What this loan is for",
                            text: loanPurposeBinding(account),
                            prompt: Text("What this loan is for")
                        )
#if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .ranchEntry(loanPurposeBinding(account))
                    }
                    downloadLinkEditor(account)
                    Text("\(count) transactions on this account")
                        .font(.subheadline)
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !check.automated {
                        Button("Import statement") { beginImport(for: account) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Remove", role: .destructive) {
                        accountPendingRemoval = account
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            for account in store.ledger.accounts {
                _ = RanchOSFinanceAccountFolders.ensure(account, among: store.ledger.accounts)
            }
        }
        Section {
            Button("Add account") { showingAddAccount = true }
        }
    }

    private var chartPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                chartFilters
                chartCategoryList
                if showsPeriodTrend {
                    periodTrend
                } else {
                    categoryChart
                }
                moneySummary
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chartFilters: some View {
        RanchOSFinanceChartBox("Filters") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Account", selection: $chartAccount) {
                    Text("All accounts").tag(RanchOSFinanceChartAccountFilter.all)
                    ForEach(store.accountsByName) { account in
                        Text(store.accountLabel(account)).tag(RanchOSFinanceChartAccountFilter.account(account.id))
                    }
                    if chartHasUnassigned {
                        Text("No account").tag(RanchOSFinanceChartAccountFilter.unassigned)
                    }
                }
                Picker("Show", selection: $chartShow) {
                    Text("All expenses").tag(ChartShow.allExpenses)
                    Text("Income").tag(ChartShow.income)
                    ForEach(store.chartProfilesByName) { profile in
                        Text(profile.name).tag(ChartShow.profile(profile.id))
                    }
                }
                .onChange(of: chartShow) { _, show in
                    chartDraft = false
                    chartDraftMessage = nil
                    applyChartShow(show)
                }
                chartFilterControls
                if let chartDraftMessage {
                    Text(chartDraftMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("Time", selection: $chartTime) {
                    ForEach(RanchOSFinanceChartTime.allCases, id: \.self) { time in
                        Text(time.label).tag(time)
                    }
                }
                .onChange(of: chartTime) { _, _ in
                    resetPeriodSelection()
                }
                .onChange(of: chartAccount) { _, _ in
                    resetPeriodSelection()
                }
                if showsYearPicker {
                    Picker("Year", selection: yearSelection) {
                        if chartYearChoices.isEmpty {
                            Text("No years").tag(0)
                        }
                        ForEach(chartYearChoices, id: \.self) { year in
                            Text(String(year)).tag(year)
                        }
                    }
                    .onChange(of: chartYear) { _, _ in
                        resetPeriodSelection()
                    }
                }
                if chartTime == .semiannual {
                    Picker("Half year", selection: halfSelection) {
                        Text("Jan–Jun").tag(1)
                        Text("Jul–Dec").tag(2)
                    }
                    .onChange(of: chartHalf) { _, _ in
                        resetPeriodSelection()
                    }
                }
                if chartTime == .daily {
                    Picker("Month", selection: dayMonthSelection) {
                        ForEach(1...12, id: \.self) { month in
                            Text(RanchOSFinanceDates.monthLabel(year: max(resolvedYear, 1), month: month)).tag(month)
                        }
                    }
                    .onChange(of: chartDayMonth) { _, _ in
                        resetPeriodSelection()
                    }
                }
                if showsPeriodTrend {
                    Text(trendHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if chartCompareLastYear {
                    Text("\(periodCompare.currentLabel) compared with \(periodCompare.priorLabel).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Hide zeros", isOn: $chartHideZeros)
                Text("Name a new filter, such as auto. Every category starts off. Turn on the ones that belong to that name, then save. After it is saved, turn on more categories to add them to that filter. Card purchases count as expenses. Bank withdrawals count as expenses. Payments, refunds, and deposits count as income.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chartCategoryList: some View {
        RanchOSFinanceChartBox("Categories") {
            if store.categoriesByName.isEmpty {
                Text("No categories yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if chartDraft {
                        Text("No categories are selected. Turn on the ones that belong to this filter, then save.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let name = activeProfileName {
                        Text("Turn a category on to add it to \(name). It stays the next time you choose this filter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Select all") { selectAllChartCategories() }
                            .disabled(allCategoriesAreShowing)
                        Button("Unselect all") { unselectAllChartCategories() }
                            .disabled(noCategoriesAreShowing)
                    }
                    let amounts = categoryAmountByID
                    let compares = chartCompareLastYear ? compareByID : [:]
                    ForEach(store.categoriesByName) { category in
                        Toggle(isOn: categoryIncluded(category.id)) {
                            categoryFilterLabel(
                                category,
                                amount: amounts[category.id] ?? 0,
                                compare: compares[category.id])
                        }
                    }
                    .id(categoryListToken)
                    HStack {
                        TextField("New category", text: $chartNewCategoryName)
#if !os(tvOS)
                            .textFieldStyle(.roundedBorder)
#endif
                            .onSubmit { addChartCategory() }
                            .ranchEntry($chartNewCategoryName)
                        Button("Add") { addChartCategory() }
                            .buttonStyle(.borderedProminent)
                            .disabled(chartNewCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var categoryChart: some View {
        if let drillID = chartDrillCategoryID, let category = store.category(id: drillID) {
            vendorDrillChart(category)
        } else {
            categoryParetoChart
        }
    }

    private var categoryParetoChart: some View {
        RanchOSFinanceChartBox(categoryChartTitle) {
            if categoryBars.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    chartDateRangeLine
                    Text("Nothing to chart for these filters.")
                        .foregroundStyle(.secondary)
                }
            } else if chartCompareLastYear {
                compareCategoryChart
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    chartDateRangeLine
                    if let paretoSummary {
                        Text(paretoSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(paretoHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RanchOSParetoPlot(
                        columns: chartBarsByValue.enumerated().map { index, bar in
                            RanchOSParetoColumn(
                                id: bar.categoryID.uuidString,
                                index: index,
                                label: bar.name,
                                value: NSDecimalNumber(decimal: bar.total).doubleValue,
                                color: paretoEightyIDs.contains(bar.categoryID) ? Color.accentColor : Color.secondary.opacity(0.35))
                        },
                        shares: paretoShares(categorySharePoints),
                        top: categoryChartTop,
                        phoneVisibleCount: 3,
                        onSelect: { id in
                            guard let bar = chartBarsByValue.first(where: { $0.categoryID.uuidString == id }) else { return }
                            drillInto(bar.categoryID)
                        })
                    ForEach(categoryBarsByName) { bar in
                        Button { drillInto(bar.categoryID) } label: {
                            chartValueRow(bar.name, value: RanchOSFinanceMoney.format(bar.total))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the vendors in \(bar.name)")
                    }
                }
            }
        }
    }

    private func drillInto(_ categoryID: UUID) {
        chartDrillCategoryID = categoryID
    }

    private func vendorDrillChart(_ category: RanchOSFinanceCategory) -> some View {
        let bars = store.vendorTotals(
            categoryID: category.id, query: chartQuery, currentPeriodOnly: chartCompareLastYear)
        let ranked = RanchOSFinancePareto.vendors(from: bars)
        let shown = bars.filter { $0.total > 0 }
        let top = max(shown.map { NSDecimalNumber(decimal: $0.total).doubleValue }.max() ?? 0, 1)
        let eightyIDs = Set(ranked.filter(\.inEighty).map(\.id))
        let points = sharePoints(
            ranked.map { (id: $0.id, label: $0.name, cumulative: $0.cumulative, inEighty: $0.inEighty) },
            top: top)
        return RanchOSFinanceChartBox("\(category.name) by vendor Pareto") {
            VStack(alignment: .leading, spacing: 12) {
                Button("All categories", systemImage: "chevron.backward") {
                    chartDrillCategoryID = nil
                }
                if chartCompareLastYear {
                    Text(periodCompare.currentLabel)
                        .font(.headline)
                    Text("Vendors for this period only. Last year is not shown here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    chartDateRangeLine
                }
                if shown.isEmpty {
                    Text("Nothing in \(category.name) for these filters.")
                        .foregroundStyle(.secondary)
                } else {
                    if let summary = vendorParetoSummary(ranked, category: category) {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Each number on the orange line is the running share. The dashed line is 80%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RanchOSParetoPlot(
                        columns: shown.enumerated().map { index, bar in
                            RanchOSParetoColumn(
                                id: bar.id,
                                index: index,
                                label: bar.name,
                                value: NSDecimalNumber(decimal: bar.total).doubleValue,
                                color: eightyIDs.contains(bar.id) ? Color.accentColor : Color.secondary.opacity(0.35))
                        },
                        shares: points.map {
                            RanchOSParetoShare(
                                id: $0.id, label: $0.label, y: $0.y, percent: $0.percent, marksEighty: $0.marksEighty)
                        },
                        top: top,
                        phoneVisibleCount: 3)
                    ForEach(shown) { bar in
                        if let vendorID = bar.vendorID {
                            NavigationLink {
                                RanchOSFinanceVendorView(store: store, vendorID: vendorID)
                            } label: {
                                chartValueRow(bar.name, value: RanchOSFinanceMoney.format(bar.total))
                            }
                        } else {
                            chartValueRow(bar.name, value: RanchOSFinanceMoney.format(bar.total))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func vendorParetoSummary(
        _ ranked: [RanchOSFinanceTrendBar], category: RanchOSFinanceCategory
    ) -> String? {
        let eighty = ranked.filter(\.inEighty)
        guard let last = eighty.last else { return nil }
        let names = eighty.map(\.name).formatted(.list(type: .and))
        let whole = ranked.reduce(Decimal(0)) { $0 + $1.total }
        let percent = RanchOSFinancePareto.percentText(last.cumulative, of: whole)
        return "\(names) \(eighty.count == 1 ? "is" : "are") \(percent) of \(category.name)."
    }

    private var compareCategoryChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartDateRangeLine
            if let paretoSummary {
                Text(paretoSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            compareLegend
            Text(paretoHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            RanchOSParetoPlot(
                columns: chartBarsByValue.enumerated().flatMap { index, bar in
                    [
                        RanchOSParetoColumn(
                            id: bar.categoryID.uuidString,
                            index: index,
                            label: bar.name,
                            value: NSDecimalNumber(decimal: bar.total).doubleValue,
                            color: paretoEightyIDs.contains(bar.categoryID) ? Color.accentColor : Color.accentColor.opacity(0.35),
                            series: periodCompare.currentLabel),
                        RanchOSParetoColumn(
                            id: "\(bar.categoryID.uuidString)-prior",
                            index: index,
                            label: bar.name,
                            value: NSDecimalNumber(decimal: priorTotal(for: bar.categoryID)).doubleValue,
                            color: .orange,
                            series: periodCompare.priorLabel),
                    ]
                },
                shares: paretoShares(categorySharePoints),
                top: categoryChartTop,
                phoneVisibleCount: 3,
                onSelect: { id in
                    guard let bar = chartBarsByValue.first(where: { $0.categoryID.uuidString == id }) else { return }
                    drillInto(bar.categoryID)
                })
            ForEach(categoryBarsByName) { bar in
                Button { drillInto(bar.categoryID) } label: {
                    chartValueRow(
                        bar.name,
                        value: "\(RanchOSFinanceMoney.format(bar.total)) · \(RanchOSFinanceMoney.format(priorTotal(for: bar.categoryID))) last year")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the vendors in \(bar.name)")
            }
        }
    }

    private var compareLegend: some View {
        HStack(spacing: 16) {
            legendItem(Color.accentColor, periodCompare.currentLabel)
            legendItem(Color.orange, periodCompare.priorLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var periodTrend: some View {
        RanchOSFinanceChartBox(trendTitle) {
            if trendBars.isEmpty {
                Text("Nothing to chart for these filters.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    chartDateRangeLine
                    if let trendSummary {
                        Text(trendSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if trendChartBars.isEmpty {
                        Text("Nothing to chart for these filters.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Each number on the orange line is the running share. The dashed line is 80%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        RanchOSParetoPlot(
                            columns: trendChartBars.enumerated().map { index, bar in
                                RanchOSParetoColumn(
                                    id: bar.id,
                                    index: index,
                                    label: bar.shortLabel,
                                    value: NSDecimalNumber(decimal: bar.total).doubleValue,
                                    color: trendEightyIDs.contains(bar.id) ? Color.accentColor : Color.secondary.opacity(0.35))
                            },
                            shares: paretoShares(trendSharePoints),
                            top: trendChartTop,
                            phoneVisibleCount: 6,
                            macSlot: 64)
                    }
                    Text("Turn off a period to leave it out of the chart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Select all") { resetPeriodSelection() }
                            .disabled(chartPeriodsAll)
                        Button("Unselect all") { unselectAllPeriods() }
                            .disabled(noPeriodsAreShowing)
                    }
                    ForEach(trendBars) { bar in
                        Toggle(isOn: periodIncluded(bar.id)) {
                            LabeledContent(bar.label, value: RanchOSFinanceMoney.format(bar.total))
                        }
                    }
                }
            }
        }
    }

    /// Income, expenses, and what is left for the chart's account and dates.
    /// Every category counts, whatever the category filter.
    private var moneySummary: some View {
        let totals = store.incomeAndExpenses(
            chartQuery,
            windows: showsPeriodTrend ? amountWindows : nil,
            currentPeriodOnly: chartCompareLastYear)
        let remaining = totals.income - totals.expenses
        return RanchOSFinanceChartBox("Income and expenses") {
            VStack(alignment: .leading, spacing: 8) {
                if chartCompareLastYear {
                    Text(periodCompare.currentLabel)
                        .font(.headline)
                } else {
                    chartDateRangeLine
                }
                LabeledContent("Income", value: RanchOSFinanceMoney.format(totals.income))
                LabeledContent("Expenses", value: RanchOSFinanceMoney.format(totals.expenses))
                Divider()
                LabeledContent("Remaining") {
                    Text(RanchOSFinanceMoney.format(remaining))
                        .fontWeight(.semibold)
                        .foregroundStyle(remaining < 0 ? Color.red : Color.primary)
                }
                Text(moneySummaryCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var moneySummaryCaption: String {
        var caption = "Remaining is income minus expenses for this account and these dates. Every category counts, whatever is turned on above."
        if chartCompareLastYear {
            caption += " This period only."
        } else if showsPeriodTrend {
            caption += " Only the periods that are on."
        }
        return caption + " A card payment counts as income on the card and as an expense at the bank."
    }

    @ViewBuilder
    private var chartDateRangeLine: some View {
        if let chartDateRangeLabel {
            Text(chartDateRangeLabel)
                .font(.headline)
        }
    }

    private var chartDateRangeLabel: String? {
        if chartCompareLastYear {
            let spans = store.chartComparisonSpans(chartQuery)
            switch (spans.current, spans.prior) {
            case let (current?, prior?):
                return "\(RanchOSFinanceDates.daySpan([current.start, current.end])) compared with \(RanchOSFinanceDates.daySpan([prior.start, prior.end]))"
            case let (current?, nil):
                return RanchOSFinanceDates.daySpan([current.start, current.end])
            case let (nil, prior?):
                return RanchOSFinanceDates.daySpan([prior.start, prior.end])
            case (nil, nil):
                return nil
            }
        }
        let windows = showsPeriodTrend ? amountWindows : nil
        guard let span = store.chartDateSpan(chartQuery, windows: windows) else { return nil }
        return RanchOSFinanceDates.daySpan([span.start, span.end])
    }

    /// On the iPhone the filter name sits on its own line. A saved filter is
    /// still the only time Remove this filter is shown.
    @ViewBuilder
    private var chartFilterControls: some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter name", text: $newProfileName)
                .ranchEntry($newProfileName)
                .onChange(of: newProfileName) { _, name in
                    guard !chartDraft else { return }
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    beginChartFilter()
                }
            HStack(spacing: 8) {
                chartFilterButtons
            }
        }
#else
        HStack(alignment: .center, spacing: 8) {
            chartFilterButtons
            TextField("Filter name", text: $newProfileName)
                .ranchEntry($newProfileName)
                .onChange(of: newProfileName) { _, name in
                    guard !chartDraft else { return }
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    beginChartFilter()
                }
                .containerRelativeFrame(.horizontal) { width, _ in width / 2 }
            Spacer(minLength: 0)
        }
#endif
    }

    @ViewBuilder
    private var chartFilterButtons: some View {
        if chartDraft {
            Button("Save filter") { saveChartFilter() }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { cancelChartFilter() }
        } else {
            Button("New filter") { beginChartFilter() }
            if activeProfileName != nil {
                Button("Remove this filter", role: .destructive) {
                    guard case .profile(let id) = chartShow else { return }
                    store.deleteChartProfile(id: id)
                    chartShow = .allExpenses
                    applyChartShow(.allExpenses)
                }
            }
        }
    }

    private var paretoHelp: String {
#if os(iOS)
        "Each number on the orange line is the running share. The dashed line is 80%. Tap a bar or a category below to see its vendors."
#else
        "Each number on the orange line is the running share. The dashed line is 80%. Click a bar or a category below to see its vendors."
#endif
    }

    /// A name and its amount. On iPhone the amount sits under the name so a
    /// long category does not collide with the figure.
    @ViewBuilder
    private func chartValueRow(_ title: String, value: String) -> some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
#else
        LabeledContent(title, value: value)
#endif
    }

    private func paretoShares(_ points: [SharePoint]) -> [RanchOSParetoShare] {
        points.map {
            RanchOSParetoShare(
                id: $0.id, label: $0.label, y: $0.y, percent: $0.percent, marksEighty: $0.marksEighty)
        }
    }

    private var categoryChartTop: Double {
        let current = chartBarsByValue.map { NSDecimalNumber(decimal: $0.total).doubleValue }.max() ?? 0
        let prior = chartCompareLastYear
            ? chartBarsByValue.map { NSDecimalNumber(decimal: priorTotal(for: $0.categoryID)).doubleValue }.max() ?? 0
            : 0
        let peak = max(current, prior)
        return peak > 0 ? peak : 1
    }

    @ViewBuilder
    private var historyContent: some View {
        if store.ledger.accounts.isEmpty && store.ledger.archives.isEmpty {
            Section {
                Text("Nothing in History yet. Archive a statement after its categories are assigned.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(store.historyGroups()) { group in
            Section(group.account) {
                if group.archives.isEmpty {
                    Text("No archives yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(group.archives) { archive in
                    NavigationLink {
                        RanchOSFinanceArchiveView(archive: archive)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(archiveTitle(archive))
                                .font(.subheadline.weight(.medium))
                            Text("\(store.archiveDaySpan(archive)) · \(archive.charges.count) charges")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var deletableCategories: [RanchOSFinanceCategory] {
        store.ledger.categories.filter { !$0.isUncategorized }
    }

    private var chartHasUnassigned: Bool {
        store.ledger.charges.contains { store.file(id: $0.fileID)?.accountID == nil }
    }

    private var chartCompareLastYear: Bool {
        chartTime == .samePeriodLastYear
    }

    private var showsPeriodTrend: Bool {
        switch chartTime {
        case .daily, .week, .month, .semiannual, .annual:
            return true
        case .allDates, .samePeriodLastYear:
            return false
        }
    }

    private var showsYearPicker: Bool {
        switch chartTime {
        case .daily, .week, .month, .semiannual:
            return true
        case .allDates, .annual, .samePeriodLastYear:
            return false
        }
    }

    private var chartYearChoices: [Int] {
        store.chartYears(account: chartAccount)
    }

    private var resolvedYear: Int {
        if let chartYear, chartYearChoices.contains(chartYear) { return chartYear }
        return chartYearChoices.first ?? 0
    }

    private var resolvedHalf: Int {
        if let chartHalf, chartHalf == 1 || chartHalf == 2 { return chartHalf }
        let months = store.chartMonths(account: chartAccount).filter { $0.year == resolvedYear }
        return (months.last?.month ?? 1) > 6 ? 2 : 1
    }

    private var resolvedDayMonth: Int {
        if let chartDayMonth, (1...12).contains(chartDayMonth) { return chartDayMonth }
        let months = store.chartMonths(account: chartAccount).filter { $0.year == resolvedYear }
        return months.last?.month ?? 1
    }

    private var yearSelection: Binding<Int> {
        Binding(get: { resolvedYear }, set: { chartYear = $0 })
    }

    private var halfSelection: Binding<Int> {
        Binding(get: { resolvedHalf }, set: { chartHalf = $0 })
    }

    private var dayMonthSelection: Binding<Int> {
        Binding(get: { resolvedDayMonth }, set: { chartDayMonth = $0 })
    }

    private var chartQuery: RanchOSFinanceChartQuery {
        let limited = chartDraft || !chartAllCategories
        let categoryIDs = chartDraft
            ? chartDraftCategoryIDs
            : (chartAllCategories ? [] : chartCategoryIDs)
        return RanchOSFinanceChartQuery(
            account: chartAccount,
            categoryIDs: categoryIDs,
            year: nil, month: nil, money: chartMoney,
            limitsCategories: limited)
    }

    private var periodCompare: RanchOSFinancePeriodCompare {
        store.samePeriodLastYear(chartQuery)
    }

    private var periodCompareAllCategories: RanchOSFinancePeriodCompare {
        var query = chartQuery
        query.categoryIDs = []
        query.limitsCategories = false
        return store.samePeriodLastYear(query)
    }

    private var displayedCategoryCompares: [RanchOSFinanceCategoryCompare] {
        let rows = periodCompare.categories
        guard chartHideZeros else { return rows }
        return rows.filter { $0.total > 0 || $0.priorTotal > 0 }
    }

    private var categoryBars: [RanchOSFinanceCategoryBar] {
        if chartCompareLastYear {
            return displayedCategoryCompares.map {
                RanchOSFinanceCategoryBar(categoryID: $0.categoryID, name: $0.name, total: $0.total)
            }
        }
        let bars = store.categoryTotals(chartQuery)
        guard chartHideZeros else { return bars }
        return bars.filter { $0.total > 0 }
    }

    private var categoryChartTitle: String {
        if chartCompareLastYear {
            return "\(periodCompare.currentLabel) \(chartSliceName) compared with \(periodCompare.priorLabel)"
        }
        return "\(chartSliceName) Pareto"
    }

    private var trendBars: [RanchOSFinancePeriodBar] {
        store.periodBars(
            time: chartTime, year: resolvedYear, month: resolvedDayMonth,
            half: resolvedHalf, query: chartQuery)
    }

    private var selectedTrendBars: [RanchOSFinancePeriodBar] {
        if chartPeriodsAll { return trendBars }
        return trendBars.filter { chartPeriodIDs.contains($0.id) }
    }

    private var trendChartBars: [RanchOSFinancePeriodBar] {
        let shown = chartHideZeros ? selectedTrendBars.filter { $0.total > 0 } : selectedTrendBars
        return shown.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.start < rhs.start
        }
    }

    private var trendRanked: [RanchOSFinanceTrendBar] {
        RanchOSFinancePareto.trend(from: trendChartBars)
    }

    private var trendEightyIDs: Set<String> {
        Set(trendRanked.filter(\.inEighty).map(\.id))
    }

    private var trendSummary: String? {
        let eighty = trendRanked.filter(\.inEighty)
        guard let last = eighty.last else { return nil }
        let names = eighty.map(\.name).formatted(.list(type: .and))
        let whole = trendRanked.reduce(Decimal(0)) { $0 + $1.total }
        let percent = RanchOSFinancePareto.percentText(last.cumulative, of: whole)
        return "\(names) are \(percent) of \(chartSliceName.lowercased())."
    }

    private var trendTitle: String {
        let name = chartSliceName
        switch chartTime {
        case .daily:
            return "\(RanchOSFinanceDates.monthLabel(year: max(resolvedYear, 1), month: resolvedDayMonth)) \(name) by day"
        case .week:
            return "\(resolvedYear) \(name) by week"
        case .month:
            return "\(resolvedYear) \(name) by month"
        case .semiannual:
            let half = resolvedHalf == 1 ? "Jan–Jun" : "Jul–Dec"
            return "\(half) \(resolvedYear) \(name) by month"
        case .annual:
            return "\(name) by year"
        case .allDates, .samePeriodLastYear:
            return "\(name) Pareto"
        }
    }

    private var trendHelp: String {
        switch chartTime {
        case .week:
            "By week is the 52 weeks of the year, from the categories that are on. Turn off the weeks you do not want to see."
        case .month:
            "By month is the 12 months of the year, from the categories that are on. Turn off the months you do not want to see."
        case .semiannual:
            "Semi-annual is the six months of that half, from the categories that are on. Turn off the months you do not want to see."
        case .daily:
            "Daily is each day of the month, from the categories that are on. Turn off the days you do not want to see."
        case .annual:
            "Annual is each year, from the categories that are on. Turn off the years you do not want to see."
        case .allDates, .samePeriodLastYear:
            ""
        }
    }

    private var trendChartTop: Double {
        let peak = trendChartBars.map { NSDecimalNumber(decimal: $0.total).doubleValue }.max() ?? 0
        return peak > 0 ? peak : 1
    }

    private var noPeriodsAreShowing: Bool {
        if trendBars.isEmpty { return true }
        return !chartPeriodsAll && chartPeriodIDs.isEmpty
    }

    private var amountWindows: [(start: Date, end: Date)] {
        if chartPeriodsAll, let first = trendBars.first, let last = trendBars.last {
            return [(start: first.start, end: last.end)]
        }
        return selectedTrendBars.map { (start: $0.start, end: $0.end) }
    }

    private var chartMoney: RanchOSFinanceChartMoney {
        if case .income = chartShow { return .income }
        return .expenses
    }

    private var chartSliceName: String {
        if chartDraft {
            let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "New filter" : trimmed
        }
        return activeProfileName ?? chartMoney.label
    }

    private var activeProfileID: UUID? {
        guard case .profile(let id) = chartShow else { return nil }
        return id
    }

    private var activeProfileName: String? {
        guard let id = activeProfileID else { return nil }
        return store.ledger.chartProfiles.first { $0.id == id }?.name
    }

    private var allCategoriesAreShowing: Bool {
        let all = Set(store.categoriesByName.map(\.id))
        if all.isEmpty { return true }
        if chartDraft { return chartDraftCategoryIDs == all }
        if activeProfileID != nil { return chartCategoryIDs == all }
        return chartAllCategories
    }

    private var noCategoriesAreShowing: Bool {
        if store.categoriesByName.isEmpty { return true }
        if chartDraft { return chartDraftCategoryIDs.isEmpty }
        if activeProfileID != nil { return chartCategoryIDs.isEmpty }
        return !chartAllCategories && chartCategoryIDs.isEmpty
    }

    private func selectAllChartCategories() {
        let all = Set(store.categoriesByName.map(\.id))
        if chartDraft {
            chartDraftCategoryIDs = all
            chartAllCategories = false
            chartCategoryIDs = all
        } else if let profileID = activeProfileID {
            chartAllCategories = false
            chartCategoryIDs = all
            store.setChartProfileCategories(id: profileID, categoryIDs: all)
        } else {
            chartAllCategories = true
            chartCategoryIDs = []
        }
        categoryListToken += 1
    }

    private func unselectAllChartCategories() {
        if let profileID = activeProfileID, !chartDraft {
            store.setChartProfileCategories(id: profileID, categoryIDs: [])
        }
        chartAllCategories = false
        chartCategoryIDs = []
        if chartDraft {
            chartDraftCategoryIDs = []
        }
        categoryListToken += 1
    }

    private struct SharePoint: Identifiable {
        var id: String
        var label: String
        var y: Double
        var percent: String
        /// The point where the running share first reaches 80 percent.
        var marksEighty: Bool
    }

    /// Room above the tallest bar so a percent sitting on the line is not clipped.
    private func chartDomain(top: Double) -> ClosedRange<Double> {
        0 ... (top > 0 ? top * 1.16 : 1)
    }

    private struct ParetoChartAxes: ViewModifier {
        var top: Double

        func body(content: Content) -> some View {
            content.chartYAxis {
                AxisMarks(position: .leading)
                AxisMarks(position: .trailing, values: [0, 0.2, 0.4, 0.6, 0.8, 1].map { $0 * top }) { value in
                    AxisValueLabel {
                        if let amount = value.as(Double.self), top > 0 {
                            Text("\(Int((amount / top * 100).rounded()))%")
                                .font(.caption2)
                        }
                    }
                }
            }
        }
    }

    private var categorySharePoints: [SharePoint] {
        sharePoints(
            paretoRanked.map {
                (id: $0.categoryID.uuidString, label: $0.name, cumulative: $0.cumulative, inEighty: $0.inEighty)
            },
            top: categoryChartTop)
    }

    private var trendSharePoints: [SharePoint] {
        let labels = Dictionary(uniqueKeysWithValues: trendChartBars.map { ($0.id, $0.shortLabel) })
        return sharePoints(
            trendRanked.map {
                (id: $0.id, label: labels[$0.id] ?? $0.name, cumulative: $0.cumulative, inEighty: $0.inEighty)
            },
            top: trendChartTop)
    }

    private func sharePoints(
        _ items: [(id: String, label: String, cumulative: Decimal, inEighty: Bool)], top: Double
    ) -> [SharePoint] {
        let whole = items.last?.cumulative ?? 0
        guard whole > 0, top > 0 else { return [] }
        return items.enumerated().map { index, item in
            let fraction = NSDecimalNumber(decimal: item.cumulative / whole).doubleValue
            let marksEighty = item.inEighty && (index == items.count - 1 || !items[index + 1].inEighty)
            return SharePoint(
                id: item.id, label: item.label, y: fraction * top,
                percent: RanchOSFinancePareto.percentText(item.cumulative, of: whole),
                marksEighty: marksEighty)
        }
    }

    @ChartContentBuilder
    private func paretoShareMarks(_ points: [SharePoint], top: Double) -> some ChartContent {
        ForEach(points) { point in
            LineMark(
                x: .value("Item", point.label),
                y: .value("Share", point.y)
            )
            .foregroundStyle(Color.orange)
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(
                x: .value("Item", point.label),
                y: .value("Share", point.y)
            )
            .foregroundStyle(Color.orange)
            .symbolSize(point.marksEighty ? 90 : 36)
            .annotation(position: .top, spacing: 4) {
                Text(point.percent)
                    .font(.caption2.weight(point.marksEighty ? .bold : .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 3)
                    .background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        if !points.isEmpty {
            RuleMark(y: .value("80%", top * 0.8))
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("80%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                }
        }
    }

    private struct CompareMark: Identifiable {
        var id: String
        var name: String
        var series: String
        var total: Decimal
        var isCurrent: Bool
        var inEighty: Bool
    }

    private var categoryCompareMarks: [CompareMark] {
        let currentLabel = periodCompare.currentLabel
        let priorLabel = periodCompare.priorLabel
        return chartBarsByValue.flatMap { bar in
            [
                CompareMark(
                    id: "\(bar.categoryID.uuidString)-now", name: bar.name, series: currentLabel,
                    total: bar.total, isCurrent: true,
                    inEighty: paretoEightyIDs.contains(bar.categoryID)),
                CompareMark(
                    id: "\(bar.categoryID.uuidString)-prior", name: bar.name, series: priorLabel,
                    total: priorTotal(for: bar.categoryID), isCurrent: false, inEighty: false),
            ]
        }
    }

    private func compareColor(_ mark: CompareMark) -> Color {
        guard mark.isCurrent else { return .orange }
        return mark.inEighty ? Color.accentColor : Color.accentColor.opacity(0.35)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(title)
        }
    }

    private func priorTotal(for id: UUID) -> Decimal {
        periodCompare.categories.first { $0.categoryID == id }?.priorTotal ?? 0
    }

    /// One pass for the category list. Week, month, and half-year totals use
    /// the periods that are on.
    private var categoryAmountByID: [UUID: Decimal] {
        var query = chartQuery
        query.categoryIDs = []
        query.limitsCategories = false
        let totals = showsPeriodTrend
            ? store.categoryTotals(query, windows: amountWindows)
            : store.categoryTotals(query)
        return Dictionary(totals.map { ($0.categoryID, $0.total) }, uniquingKeysWith: { first, _ in first })
    }

    private var compareByID: [UUID: RanchOSFinanceCategoryCompare] {
        Dictionary(
            periodCompareAllCategories.categories.map { ($0.categoryID, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    @ViewBuilder
    private func categoryFilterLabel(
        _ category: RanchOSFinanceCategory,
        amount: Decimal,
        compare: RanchOSFinanceCategoryCompare?
    ) -> some View {
        if chartCompareLastYear, let compare {
            LabeledContent(category.name) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(RanchOSFinanceMoney.format(compare.total))
                    Text("\(RanchOSFinanceMoney.format(compare.priorTotal)) last year")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent(category.name, value: RanchOSFinanceMoney.format(amount))
        }
    }

    private var chartBarsByValue: [RanchOSFinanceCategoryBar] {
        categoryBars.sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var categoryBarsByName: [RanchOSFinanceCategoryBar] {
        categoryBars.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var paretoRanked: [RanchOSFinanceParetoBar] {
        RanchOSFinancePareto.bars(from: categoryBars)
    }

    private var paretoEightyIDs: Set<UUID> {
        Set(paretoRanked.filter(\.inEighty).map(\.categoryID))
    }

    private var paretoSummary: String? {
        let eighty = paretoRanked.filter(\.inEighty)
        guard let last = eighty.last else { return nil }
        let names = eighty.map(\.name).formatted(.list(type: .and))
        let whole = paretoRanked.reduce(Decimal(0)) { $0 + $1.total }
        let percent = RanchOSFinancePareto.percentText(last.cumulative, of: whole)
        return "\(names) are \(percent) of \(chartSliceName.lowercased())."
    }

    private func resetPeriodSelection() {
        chartPeriodsAll = true
        chartPeriodIDs = []
    }

    private func unselectAllPeriods() {
        chartPeriodsAll = false
        chartPeriodIDs = []
    }

    private func periodIncluded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { chartPeriodsAll || chartPeriodIDs.contains(id) },
            set: { on in
                let all = Set(trendBars.map(\.id))
                var selected = chartPeriodsAll ? all : chartPeriodIDs
                if on {
                    selected.insert(id)
                } else {
                    selected.remove(id)
                }
                if selected == all {
                    chartPeriodsAll = true
                    chartPeriodIDs = []
                } else {
                    chartPeriodsAll = false
                    chartPeriodIDs = selected
                }
            })
    }

    private func applyChartShow(_ show: ChartShow) {
        switch show {
        case .allExpenses, .income:
            chartAllCategories = true
            chartCategoryIDs = []
        case .profile(let id):
            chartAllCategories = false
            let saved = store.ledger.chartProfiles.first { $0.id == id }?.categoryIDs ?? []
            chartCategoryIDs = Set(saved)
        }
    }

    private func beginChartFilter() {
        chartDraft = true
        chartDraftCategoryIDs = []
        chartAllCategories = false
        chartCategoryIDs = []
        chartDraftMessage = nil
        categoryListToken += 1
    }

    private func cancelChartFilter() {
        chartDraft = false
        chartDraftCategoryIDs = []
        chartDraftMessage = nil
        newProfileName = ""
        applyChartShow(chartShow)
    }

    private func saveChartFilter() {
        let selected = chartDraftCategoryIDs
        guard let profile = store.createChartProfile(name: newProfileName, categoryIDs: selected) else {
            chartDraftMessage = "Use a different name."
            return
        }
        chartDraft = false
        chartDraftMessage = nil
        newProfileName = ""
        chartAllCategories = false
        chartCategoryIDs = selected
        chartShow = .profile(profile.id)
    }

    private func categoryIncluded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                if chartDraft { return chartDraftCategoryIDs.contains(id) }
                if activeProfileID != nil { return chartCategoryIDs.contains(id) }
                return chartAllCategories || chartCategoryIDs.contains(id)
            },
            set: { on in
                if chartDraft {
                    if on {
                        chartDraftCategoryIDs.insert(id)
                    } else {
                        chartDraftCategoryIDs.remove(id)
                    }
                    chartAllCategories = false
                    chartCategoryIDs = chartDraftCategoryIDs
                    return
                }
                if let profileID = activeProfileID {
                    var selected = chartCategoryIDs
                    if on {
                        selected.insert(id)
                    } else {
                        selected.remove(id)
                    }
                    chartAllCategories = false
                    chartCategoryIDs = selected
                    store.setChartProfileCategories(id: profileID, categoryIDs: selected)
                    return
                }
                let all = Set(store.categoriesByName.map(\.id))
                var selected = chartAllCategories ? all : chartCategoryIDs
                if on {
                    selected.insert(id)
                } else {
                    selected.remove(id)
                }
                if selected == all {
                    chartAllCategories = true
                    chartCategoryIDs = []
                } else {
                    chartAllCategories = false
                    chartCategoryIDs = selected
                }
            })
    }

    private func categoryName(_ id: UUID) -> String {
        store.category(id: id)?.name ?? RanchOSFinanceSuggestionLabels.uncategorized
    }

    private var pendingPresented: Binding<Bool> {
        Binding(
            get: { pendingBytes != nil },
            set: { if !$0 { pendingBytes = nil } })
    }

    private func coverageSources(_ months: [RanchOSFinanceMonth]) -> [String] {
        var seen: [String] = []
        for month in months where !seen.contains(month.source) {
            seen.append(month.source)
        }
        return seen
    }

    private func coverageLine(source: String, months: [RanchOSFinanceMonth]) -> String {
        let labels = months.filter { $0.source == source }.map(\.label)
        let count = months.filter { $0.source == source }.reduce(0) { $0 + $1.chargeCount }
        return "\(labels.joined(separator: ", ")) · \(count) charges"
    }

    private func addCategory() {
        if store.createCategory(name: newCategoryName) != nil {
            newCategoryName = ""
        }
    }

    private func addChartCategory() {
        guard let created = store.createCategory(name: chartNewCategoryName) else { return }
        chartNewCategoryName = ""
        if chartDraft {
            chartDraftCategoryIDs.insert(created.id)
            chartAllCategories = false
            chartCategoryIDs = chartDraftCategoryIDs
        } else if let profileID = activeProfileID {
            var selected = chartCategoryIDs
            selected.insert(created.id)
            chartAllCategories = false
            chartCategoryIDs = selected
            store.setChartProfileCategories(id: profileID, categoryIDs: selected)
        }
        categoryListToken += 1
    }

    private func loanNameDraft(_ account: RanchOSFinanceAccount) -> Binding<String> {
        Binding(
            get: { loanNameDrafts[account.id] ?? account.name },
            set: { loanNameDrafts[account.id] = $0 })
    }

    private func commitLoanName(_ id: UUID) {
        let current = store.ledger.accounts.first { $0.id == id }?.name ?? ""
        let draft = loanNameDrafts[id] ?? current
        if store.renameTypedLoan(accountID: id, name: draft),
            let account = store.ledger.accounts.first(where: { $0.id == id })
        {
            _ = RanchOSFinanceAccountFolders.ensure(account, among: store.ledger.accounts)
            loanNameDrafts[id] = nil
        } else {
            loanNameDrafts[id] = current
        }
    }

    private func loanPurposeBinding(_ account: RanchOSFinanceAccount) -> Binding<String> {
        Binding(
            get: { account.purpose ?? "" },
            set: { store.setLoanPurpose(accountID: account.id, purpose: $0) })
    }

    @ViewBuilder
    private func downloadLinkEditor(_ account: RanchOSFinanceAccount) -> some View {
        if let link = account.downloadURL, let url = URL(string: link), !editingLinks.contains(account.id) {
            HStack(spacing: 8) {
                Button {
                    openInBrowser(url)
                } label: {
                    Label(url.host ?? link, systemImage: "arrow.up.right.square")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Color.accentColor)
                        .underline()
                }
                .buttonStyle(.plain)
#if !os(tvOS)
                .help("Opens \(link) in your web browser")
#endif
                .accessibilityHint("Opens the statement download page in your web browser")
                Spacer(minLength: 0)
                Button("Edit") {
                    linkDrafts[account.id] = link
                    editingLinks.insert(account.id)
                    focusedLink = account.id
                }
                .buttonStyle(.bordered)
            }
        } else {
            HStack(spacing: 8) {
                TextField(
                    "Statement download page",
                    text: linkDraft(account),
                    prompt: Text("Statement download page, such as https://bank.example/statements")
                )
                .focused($focusedLink, equals: account.id)
                .onSubmit { commitLink(account.id) }
                .onChange(of: focusedLink) { old, _ in
                    if old == account.id { commitLink(account.id) }
                }
#if !os(tvOS)
                .textFieldStyle(.roundedBorder)
#endif
                .ranchEntry(linkDraft(account), kind: .address)
                if editingLinks.contains(account.id) {
                    Button("Done") { commitLink(account.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
        if let problem = linkProblems[account.id] {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
        } else if account.downloadURL == nil {
            Text("Paste the page where you download this account's CSV. It opens in your browser; RanchOS never signs in there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func linkDraft(_ account: RanchOSFinanceAccount) -> Binding<String> {
        Binding(
            get: { linkDrafts[account.id] ?? account.downloadURL ?? "" },
            set: { text in
                linkDrafts[account.id] = text
                linkProblems[account.id] = nil
            })
    }

    private func commitLink(_ accountID: UUID) {
        guard let draft = linkDrafts[accountID] else { return }
        if let problem = store.setDownloadLink(accountID: accountID, text: draft) {
            linkProblems[accountID] = problem
        } else {
            linkDrafts[accountID] = nil
            linkProblems[accountID] = nil
            editingLinks.remove(accountID)
        }
    }

    private func openInBrowser(_ url: URL) {
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        openURL(url)
#endif
    }

    /// Mac: the download page opens first, then a guide names the account
    /// folder; the chosen file is filed there before it comes in. While the
    /// guide is up, Downloads is watched for the finished CSV.
    private func beginImport(for account: RanchOSFinanceAccount) {
#if os(macOS)
        if let link = account.downloadURL, let url = URL(string: link) {
            openInBrowser(url)
        }
        statementGuide = account
        stopStatementWatch()
        let watch = RanchOSFinanceStatementWatch { urls in
            Task { @MainActor in autoIngest(urls, for: account) }
        } onAmbiguous: {
            Task { @MainActor in chooseManually(for: account) }
        }
        statementWatch = watch
        watch.start()
#else
        importAccount = account
        showingImporter = true
#endif
    }

#if os(macOS)
    /// Ends the Downloads wait. The guide's dismiss and its Choose button
    /// both land here; stopping twice is harmless.
    private func stopStatementWatch() {
        statementWatch?.stop()
        statementWatch = nil
    }

    /// The guide's Choose button and every watch dead end land here: the wait
    /// is over and the panel asks which file. Nothing happens when the guide
    /// is already gone (the person cancelled while a callback was queued).
    private func chooseManually(for account: RanchOSFinanceAccount) {
        guard statementGuide != nil else {
            stopStatementWatch()
            return
        }
        stopStatementWatch()
        statementGuide = nil
        Task { @MainActor in chooseStatement(for: account) }
    }

    /// The wait found exactly one finished statement. It goes through the
    /// same filing and ingest as a chosen file, but only when it parses as a
    /// statement. Anything else is left alone and the panel asks instead.
    private func autoIngest(_ urls: [URL], for account: RanchOSFinanceAccount) {
        stopStatementWatch()
        guard urls.count == 1, let statement = urls.first else { return }
        guard let bytes = try? Data(contentsOf: statement),
            RanchOSFinanceCSV.isRecognizedStatement(bytes: bytes)
        else {
            fileNotice = "\(statement.lastPathComponent) is not a recognized statement, so it was left alone. Choose the statement file."
            chooseManually(for: account)
            return
        }
        statementGuide = nil
        fileAndIngest(statement, for: account)
    }

    private func chooseStatement(for account: RanchOSFinanceAccount) {
        let folder = RanchOSFinanceAccountFolders.ensure(account, among: store.ledger.accounts)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = "Import"
        panel.message = "Choose the statement file for \(store.accountDisplayName(account)). A file from Downloads or anywhere else is copied into its folder."
        if let folder {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        fileAndIngest(chosen, for: account)
    }

    /// Files a statement into the account folder, then ingests it. Used by
    /// the panel and by the Downloads watch alike.
    private func fileAndIngest(_ chosen: URL, for account: RanchOSFinanceAccount) {
        let folder = RanchOSFinanceAccountFolders.ensure(account, among: store.ledger.accounts)
        var statement = chosen
        if let folder {
            do {
                statement = try RanchOSFinanceAccountFolders.file(chosen, into: folder)
                fileNotice = statement == chosen
                    ? "\(chosen.lastPathComponent) is already in \(folder.lastPathComponent) on T2 WD X."
                    : "Copied \(chosen.lastPathComponent) into \(folder.lastPathComponent) on T2 WD X as \(statement.lastPathComponent). The original is still where the browser put it."
            } catch {
                fileNotice = "Could not copy \(chosen.lastPathComponent) into \(folder.lastPathComponent): \(error.localizedDescription). It came in from where it is."
            }
        } else {
            fileNotice = "T2 WD X is not connected, so \(chosen.lastPathComponent) was not filed in the account folder. It came in from where it is."
        }
        importAccount = account
        ingest(result: .success(statement))
    }
#endif

    private func ingest(result: Result<URL, Error>) {
#if !os(tvOS)
        let account = importAccount
        importAccount = nil
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: url) else { return }
        if let account {
            let outcome = store.ingest(
                fileName: url.lastPathComponent, bytes: bytes, source: account.name, accountID: account.id)
            noteImport(outcome)
            page = .recent
            return
        }
        let parsed = RanchOSFinanceCSV.parse(bytes: bytes)
        if parsed.kind == .appleCard {
            let outcome = store.ingest(fileName: url.lastPathComponent, bytes: bytes, source: RanchOSFinanceDates.apple)
            noteImport(outcome)
            return
        }
        pendingFileName = url.lastPathComponent
        sourceDraft = ""
        pendingBytes = bytes
#endif
    }

    private func noteImport(_ outcome: (file: RanchOSFinanceFile, newVendors: [RanchOSFinanceVendor])) {
        for vendor in outcome.newVendors where vendor.categoryID == store.uncategorizedID {
            Task { await store.requestSuggestion(vendorID: vendor.id) }
        }
        let months = store.accountsReadyToArchive()
        guard !months.isEmpty else { return }
        presentArchivePrompt()
    }

    private func earlierMonthButton(_ offers: [RanchOSFinanceArchiveOffer]) -> String {
        if offers.count == 1, let offer = offers.first {
            return "Move \(offer.month.label) to History"
        }
        return "Move earlier months to History"
    }

    private func earlierMonthSummary(_ offers: [RanchOSFinanceArchiveOffer]) -> String {
        let names = Array(Set(offers.map(\.accountName))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return names.map { name in
            let accountOffers = offers.filter { $0.accountName == name }
            let open = accountOffers.first?.openMonthLabel ?? ""
            let labels = accountOffers.map(\.month.label)
            let leaving = labels.count == 1
                ? (labels.first ?? "")
                : "\(labels.first ?? "") through \(labels.last ?? "")"
            return "\(name) keeps \(open). \(leaving) moves to History."
        }.joined(separator: " ")
    }

    private func moveEarlierMonths() {
        for offer in store.accountsReadyToArchive() {
            moveClosedMonth(offer)
        }
    }

    private func moveClosedMonth(_ offer: RanchOSFinanceArchiveOffer) {
        for fileID in offer.fileIDs {
            _ = store.archiveMonths(fileID: fileID, months: [offer.month])
        }
    }

    private func presentArchivePrompt() {
        guard page == .recent, archivePrompt == nil else { return }
        let offers = store.accountsReadyToArchive().filter { !dismissedArchiveOffers.contains($0.id) }
        guard !offers.isEmpty else { return }
        archivePrompt = RanchOSFinanceArchivePrompt(offers: offers)
    }

    private func archiveTitle(_ archive: RanchOSFinanceArchive) -> String {
        if let year = archive.year, let month = archive.month {
            return RanchOSFinanceDates.monthLabel(year: year, month: month)
        }
        return archive.rangeLabel
    }
}

/// Accounts whose newest month has started, so the month before it can be archived.
struct RanchOSFinanceArchivePrompt: Identifiable {
    var offers: [RanchOSFinanceArchiveOffer]
    var id: String { offers.map(\.id).joined(separator: "|") }
}

struct RanchOSFinanceArchivePromptSheet: View {
    let prompt: RanchOSFinanceArchivePrompt
    var onArchive: () -> Void
    var onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text("The latest month stays in Recent. Check the categories on every earlier month, then move those to History. History keeps the category each transaction has now. Vendors used only on those earlier months leave the Vendors list and keep their category. Categories stay. Recent then shows only the latest month.")
                .foregroundStyle(.secondary)
            ForEach(prompt.offers) { offer in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(offer.accountName) · \(offer.month.label)")
                        .font(.headline)
                    Text("\(offer.openMonthLabel) has started. \(RanchOSFinanceDates.display(offer.earliest)) – \(RanchOSFinanceDates.display(offer.latest))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Check categories") {
                    onDismiss()
                    dismiss()
                }
                Spacer()
                Button(archiveButton) {
                    onArchive()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }

    private var title: String {
        let labels = Array(Set(prompt.offers.map(\.month.label))).sorted()
        if labels.count == 1, let label = labels.first {
            return "Move \(label) to History?"
        }
        return "Move earlier months to History?"
    }

    private var archiveButton: String {
        if prompt.offers.count == 1, let offer = prompt.offers.first {
            return "Move \(offer.month.label) to History"
        }
        return "Move earlier months to History"
    }
}

/// Add account starts here. Type comes first, then only the institutions for
/// that type. Nothing is added until he confirms after the sign-in check.
struct RanchOSFinanceAddAccountSheet: View {
    @Bindable var store: RanchOSFinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RanchOSFinanceAccountKind?
    @State private var selectedName: String?
    @State private var customName = ""
    @State private var loanPurpose = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    Text("Choose a type").tag(RanchOSFinanceAccountKind?.none)
                    ForEach(RanchOSFinanceAccountKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(Optional(kind))
                    }
                }
                .onChange(of: kind) { _, _ in
                    selectedName = nil
                    customName = ""
                    loanPurpose = ""
                }
                if let kind, !typesNameOnly(kind) {
                    Picker("Name", selection: $selectedName) {
                        Text("Choose a name").tag(String?.none)
                        ForEach(store.pickerNames(for: kind), id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                        Text(RanchOSFinanceAccountCatalog.otherName).tag(Optional(RanchOSFinanceAccountCatalog.otherName))
                    }
                }
                if let kind, typesNameOnly(kind) || selectedName == RanchOSFinanceAccountCatalog.otherName {
                    TextField("Account name", text: $customName)
#if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .ranchEntry($customName)
                }
                if kind == .loan {
                    TextField("What this loan is for", text: $loanPurpose, prompt: Text("What this loan is for"))
#if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .ranchEntry($loanPurpose)
                }
                if let addProblem {
                    Text(addProblem)
                        .foregroundStyle(.red)
                }
                if let kind, let name = resolvedName(kind: kind),
                    RanchOSFinanceDates.normalizedSource(name) != nil
                {
                    Section("Automatic download") {
                        Text(RanchOSFinanceAccountCatalog.automation(kind: kind, name: name).detail)
                    }
                }
            }
            .navigationTitle("Add account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add account") { add() }
                        .disabled(!canAdd)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var canAdd: Bool {
        guard let kind, let name = resolvedName(kind: kind) else { return false }
        return RanchOSFinanceDates.normalizedSource(name) != nil && addProblem == nil
    }

    private var addProblem: String? {
        guard let kind, let name = resolvedName(kind: kind) else { return nil }
        return store.accountAddProblem(name: name, kind: kind, purpose: kind == .loan ? loanPurpose : nil)
    }

    /// Type Other has no built-in names, so it skips the picker until he has typed one.
    private func typesNameOnly(_ kind: RanchOSFinanceAccountKind) -> Bool {
        store.pickerNames(for: kind).isEmpty
    }

    private func resolvedName(kind: RanchOSFinanceAccountKind) -> String? {
        if typesNameOnly(kind) || selectedName == RanchOSFinanceAccountCatalog.otherName {
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : customName
        }
        return selectedName
    }

    private func add() {
        guard let kind, let name = resolvedName(kind: kind) else { return }
        if let created = store.createAccount(name: name, kind: kind, purpose: loanPurpose) {
            _ = RanchOSFinanceAccountFolders.ensure(created, among: store.ledger.accounts)
            dismiss()
        }
    }
}

#if os(macOS)
/// Import statement on the Mac: the download page is already open in the
/// browser. This names the account folder so the CSV lands there, then picks it.
struct RanchOSFinanceStatementGuideSheet: View {
    let accountName: String
    let link: URL?
    let folder: URL?
    var watching = false
    var onOpenPage: (URL) -> Void
    var onChoose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Download the statement") {
                    if let link {
                        Text("Your browser opened the download page for \(accountName). Sign in there and download the CSV.")
                        Button("Open the download page again") { onOpenPage(link) }
                    } else {
                        Text("\(accountName) has no download page yet. Add one on Accounts so it opens here next time. For now, download the CSV from the institution's website yourself.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("2. Put it in the account folder") {
                    if let folder {
                        Text("If the browser asks where to put it, choose this folder:")
                        Text(folder.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button("Show folder in Finder") { NSWorkspace.shared.open(folder) }
                            Button("Copy folder path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(folder.path, forType: .string)
                            }
                        }
                        Text("If it went to Downloads instead, that is fine: RanchOS copies it into this folder when you choose it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("T2 WD X is not connected, so there is no account folder right now. Connect it first, or the statement comes in without being filed.")
                            .foregroundStyle(.red)
                    }
                }
                Section("3. Bring it in") {
                    if watching {
                        Text("Watching Downloads: when the download finishes, the statement files and imports itself. You can also choose it now.")
                    } else {
                        Text("Choose the file you downloaded.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import \(accountName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose statement file") { onChoose() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
#endif

struct RanchOSParetoColumn: Identifiable {
    var id: String
    var index: Int
    var label: String
    var value: Double
    var color: Color
    var series: String?
}

struct RanchOSParetoShare: Identifiable {
    var id: String
    var label: String
    var y: Double
    var percent: String
    var marksEighty: Bool
}

/// Category bars with the running-share line. On iPhone the plot uses the
/// screen width and keeps both scales in place while the bars scroll. Mac
/// keeps the wide chart with vertical names.
struct RanchOSParetoPlot: View {
    var columns: [RanchOSParetoColumn]
    var shares: [RanchOSParetoShare]
    var top: Double
    /// How many bars stay on screen before the iPhone chart scrolls.
    var phoneVisibleCount: Int = 4
    /// Width of one bar slot in the Mac chart.
    var macSlot: CGFloat = 72
    var onSelect: ((String) -> Void)?

    @State private var selectedIndex: Int?
    @State private var selectedLabel: String?
    @State private var scrollX: Int = 0

    private var grouped: Bool { columns.contains { $0.series != nil } }

    private var itemCount: Int { Set(columns.map(\.index)).count }

    private var scrollsOnPhone: Bool { itemCount > phoneVisibleCount }

    private var domainTop: Double { top > 0 ? top * 1.16 : 1 }

    var body: some View {
#if os(iOS)
        phoneChart
#else
        macChart
#endif
    }

    private var phoneChart: some View {
        chartBody(indexed: true)
            .chartYScale(domain: 0 ... domainTop)
            .modifier(PhoneScroll(enabled: scrollsOnPhone, visibleCount: phoneVisibleCount, scrollX: $scrollX))
            .chartXAxis {
                AxisMarks(values: visibleIndexes) { value in
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let index = value.as(Int.self),
                           let label = columns.first(where: { $0.index == index })?.label {
                            Text(label)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: phoneVisibleCount <= 4 ? 72 : 44)
                        }
                    }
                }
            }
            .chartYAxis { phoneAxes }
            .chartLegend(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .modifier(IndexSelect(selection: $selectedIndex, enabled: onSelect != nil))
            .onChange(of: selectedIndex) { _, index in
                guard let index, let onSelect else { return }
                selectedIndex = nil
                guard let column = columns.first(where: { $0.index == index }) else { return }
                onSelect(column.id)
            }
    }

    private var visibleIndexes: [Int] {
        let all = Array(Set(columns.map(\.index))).sorted()
        guard scrollsOnPhone else { return all }
        return all.filter { $0 >= scrollX && $0 < scrollX + phoneVisibleCount }
    }

    @AxisContentBuilder
    private var phoneAxes: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(Self.axisMoney(amount))
                        .font(.caption2)
                }
            }
        }
        AxisMarks(position: .trailing, values: [0, 0.5, 1].map { $0 * top }) { value in
            AxisValueLabel {
                if let amount = value.as(Double.self), top > 0 {
                    Text("\(Int((amount / top * 100).rounded()))%")
                        .font(.caption2)
                }
            }
        }
    }

    private var macChart: some View {
        ScrollView(.horizontal) {
            chartBody(indexed: false)
                .chartYScale(domain: 0 ... domainTop)
                .chartXScale(domain: orderedLabels)
                .chartYAxis { macAxes }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel(orientation: .vertical)
                    }
                }
                .chartLegend(.hidden)
                .frame(width: CGFloat(max(itemCount, 1)) * (grouped ? 120 : macSlot), height: 360)
                .modifier(LabelSelect(selection: $selectedLabel, enabled: onSelect != nil))
        }
        .onChange(of: selectedLabel) { _, label in
            guard let label, let onSelect else { return }
            selectedLabel = nil
            guard let column = columns.first(where: { $0.label == label }) else { return }
            onSelect(column.id)
        }
    }

    private var orderedLabels: [String] {
        var seen: Set<String> = []
        return columns.compactMap { column in
            seen.insert(column.label).inserted ? column.label : nil
        }
    }

    @AxisContentBuilder
    private var macAxes: some AxisContent {
        AxisMarks(position: .leading)
        AxisMarks(position: .trailing, values: [0, 0.2, 0.4, 0.6, 0.8, 1].map { $0 * top }) { value in
            AxisValueLabel {
                if let amount = value.as(Double.self), top > 0 {
                    Text("\(Int((amount / top * 100).rounded()))%")
                        .font(.caption2)
                }
            }
        }
    }

    private func chartBody(indexed: Bool) -> some View {
        Chart {
            columnMarks(indexed: indexed)
            shareMarks(indexed: indexed)
        }
    }

    @ChartContentBuilder
    private func columnMarks(indexed: Bool) -> some ChartContent {
        if indexed {
            indexedColumns
        } else {
            labeledColumns
        }
    }

    @ChartContentBuilder
    private var indexedColumns: some ChartContent {
        if grouped {
            ForEach(columns) { column in
                BarMark(
                    x: .value("Item", column.index),
                    y: .value("Total", column.value)
                )
                .foregroundStyle(column.color)
                .position(by: .value("Period", column.series ?? ""))
            }
        } else {
            ForEach(columns) { column in
                BarMark(
                    x: .value("Item", column.index),
                    y: .value("Total", column.value)
                )
                .foregroundStyle(column.color)
            }
        }
    }

    @ChartContentBuilder
    private var labeledColumns: some ChartContent {
        if grouped {
            ForEach(columns) { column in
                BarMark(
                    x: .value("Item", column.label),
                    y: .value("Total", column.value)
                )
                .foregroundStyle(column.color)
                .position(by: .value("Period", column.series ?? ""))
            }
        } else {
            ForEach(columns) { column in
                BarMark(
                    x: .value("Item", column.label),
                    y: .value("Total", column.value)
                )
                .foregroundStyle(column.color)
            }
        }
    }

    @ChartContentBuilder
    private func shareMarks(indexed: Bool) -> some ChartContent {
        if indexed {
            indexedShares
        } else {
            labeledShares
        }
    }

    @ChartContentBuilder
    private var indexedShares: some ChartContent {
        ForEach(shares) { point in
            LineMark(
                x: .value("Item", columns.first { $0.label == point.label }?.index ?? 0),
                y: .value("Share", point.y)
            )
            .foregroundStyle(Color.orange)
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(
                x: .value("Item", columns.first { $0.label == point.label }?.index ?? 0),
                y: .value("Share", point.y)
            )
            .foregroundStyle(Color.orange)
            .symbolSize(point.marksEighty ? 90 : 36)
            .annotation(position: .top, spacing: 2) {
                Text(point.percent)
                    .font(.caption2.weight(point.marksEighty ? .bold : .semibold))
                    .foregroundStyle(.orange)
            }
        }
        eightyRule
    }

    @ChartContentBuilder
    private var labeledShares: some ChartContent {
        ForEach(shares) { point in
            LineMark(
                x: .value("Item", point.label),
                y: .value("Share", point.y)
            )
            .foregroundStyle(Color.orange)
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(
                x: .value("Item", point.label),
                y: .value("Share", point.y)
            )
            .foregroundStyle(Color.orange)
            .symbolSize(point.marksEighty ? 90 : 36)
            .annotation(position: .top, spacing: 4) {
                Text(point.percent)
                    .font(.caption2.weight(point.marksEighty ? .bold : .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 3)
                    .background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        eightyRule
    }

    @ChartContentBuilder
    private var eightyRule: some ChartContent {
        if !shares.isEmpty {
            RuleMark(y: .value("80%", top * 0.8))
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("80%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                }
        }
    }

    private static func axisMoney(_ value: Double) -> String {
        let negative = value < 0
        let amount = abs(value)
        let body: String
        if amount >= 1000 {
            let thousands = amount / 1000
            body = thousands >= 10 ? "$\(Int(thousands.rounded()))k" : String(format: "$%.1fk", thousands)
        } else {
            body = "$\(Int(amount.rounded()))"
        }
        return negative ? "-\(body)" : body
    }

    /// Scrolls the bars and leaves the dollar and percent scales on screen.
    private struct PhoneScroll: ViewModifier {
        var enabled: Bool
        var visibleCount: Int
        @Binding var scrollX: Int

        func body(content: Content) -> some View {
            if enabled {
                content
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: visibleCount)
                    .chartScrollPosition(x: $scrollX)
                    .chartScrollTargetBehavior(.valueAligned(unit: 1))
            } else {
                content
            }
        }
    }

    private struct IndexSelect: ViewModifier {
        @Binding var selection: Int?
        var enabled: Bool

        func body(content: Content) -> some View {
#if os(tvOS)
            content
#else
            if enabled {
                content.chartXSelection(value: $selection)
            } else {
                content
            }
#endif
        }
    }

    private struct LabelSelect: ViewModifier {
        @Binding var selection: String?
        var enabled: Bool

        func body(content: Content) -> some View {
#if os(tvOS)
            content
#else
            if enabled {
                content.chartXSelection(value: $selection)
            } else {
                content
            }
#endif
        }
    }
}

/// A titled box on the Charts page. tvOS has no GroupBox and never presents
/// Finance, so it gets a plain titled stack that only has to compile.
struct RanchOSFinanceChartBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
#if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
#else
        GroupBox(title) { content }
#endif
    }
}

/// Asks which account a bank or other statement came from before the charges
/// are kept. Apple Card files skip this and use Apple.
struct RanchOSFinanceSourceSheet: View {
    let fileName: String
    @Binding var sourceDraft: String
    var onFinish: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fileName)
                        .font(.headline)
                    Text("Name the account these transactions came from. The date range is taken from the transaction dates.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Source") {
                    ForEach(RanchOSFinanceDates.choices, id: \.self) { choice in
                        Button(choice) { finish(choice) }
                    }
                    TextField("Other account", text: $sourceDraft)
                        .ranchEntry($sourceDraft)
                    Button("Use this name") { finish(sourceDraft) }
                        .disabled(RanchOSFinanceDates.normalizedSource(sourceDraft) == nil)
                }
            }
            .navigationTitle("Statement source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onFinish(nil)
                        dismiss()
                    }
                }
            }
        }
    }

    private func finish(_ source: String) {
        onFinish(source)
        dismiss()
    }
}

/// One ingested file: pinned summary that never scrolls away, then errors,
/// then charges. Duplicate charges stay visible and flagged.
struct RanchOSFinanceFileView: View {
    @Bindable var store: RanchOSFinanceStore
    let fileID: UUID

    var body: some View {
        if let file = store.ledger.files.first(where: { $0.id == fileID }) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEV · Finance import result · read only")
                        .font(.caption.weight(.bold))
                    Text(file.fileName)
                        .font(.headline)
                    Text(file.source ?? RanchOSFinanceDates.missingSource)
                        .font(.subheadline.weight(.medium))
                    Text(store.dateRangeLabel(fileID: file.id))
                        .font(.subheadline)
                    Text("SHA-256 \(file.sha256Hex)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
#if !os(tvOS)
                        .textSelection(.enabled)
#endif
                    Text("\(file.rowCount) rows · \(file.errorCount) validation errors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(RanchOSFinanceDates.choices, id: \.self) { choice in
                            Button(choice) { _ = store.setSource(fileID: file.id, source: choice) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Button(store.archive(fileID: file.id) == nil ? "Archive this statement" : "Update history") {
                        _ = store.archiveStatement(fileID: file.id)
                    }
                    .buttonStyle(.borderedProminent)
#if os(macOS)
                    Text("This file is kept on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#else
                    Text("This file is kept on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial)

                List {
                    if !file.errors.isEmpty {
                        Section("Validation errors") {
                            ForEach(file.errors.indices, id: \.self) { index in
                                let error = file.errors[index]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Row \(error.row) · \(error.code)")
                                        .font(.caption.weight(.medium))
                                    Text(error.message)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                    Section("Charges") {
                        let charges = store.charges(fileID: file.id)
                        if charges.isEmpty {
                            Text("Zero charges.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(charges) { charge in
                            RanchOSFinanceChargeRow(store: store, charge: charge)
                        }
                    }
                }
            }
            .navigationTitle("Statement")
        } else {
            Text("That file is no longer listed.")
                .foregroundStyle(.secondary)
        }
    }
}

/// A finished statement, opened from History. Shows the date, supplier,
/// amount, and category each charge had when the statement was archived.
struct RanchOSFinanceArchiveView: View {
    let archive: RanchOSFinanceArchive

    var body: some View {
        List {
            Section {
#if os(iOS)
                Text("\(archive.source) · \(archive.rangeLabel)")
                    .font(.subheadline.weight(.medium))
                Text(archive.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
#else
                Text("\(archive.source) · \(archive.rangeLabel)")
                    .font(.headline)
                Text(archive.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
#endif
                Text("\(archive.charges.count) charges")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Charges") {
                if archive.charges.isEmpty {
                    Text("Zero charges.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(archive.charges) { charge in
#if os(iOS)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(charge.amountText)
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        Text(RanchOSFinanceDates.display(charge.dateText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(charge.categoryName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let parts = charge.splitParts, !parts.isEmpty {
                            Text(parts.map { "\($0.categoryName) \(RanchOSFinanceMoney.format($0.amount))" }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
#else
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(charge.categoryName)
                                .font(.subheadline.weight(.semibold))
                            Text(RanchOSFinanceDates.display(charge.dateText))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 148, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                            Text(charge.amountText)
                                .foregroundStyle(.secondary)
                            if let parts = charge.splitParts, !parts.isEmpty {
                                Text(parts.map { "\($0.categoryName) \(RanchOSFinanceMoney.format($0.amount))" }
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                    }
#endif
                }
            }
        }
        .navigationTitle("History")
    }
}

/// Categories page. Each category opens to the vendors assigned to it.
/// Uncategorized is first. Search matches a category name or a vendor name.
struct RanchOSFinanceCategoryVendorsView: View {
    @Bindable var store: RanchOSFinanceStore
    @State private var query = ""
    @State private var expanded: Set<UUID> = []
    @State private var addingCategoryFor: UUID?
    @State private var newCategoryName = ""
    @State private var newCategoryProblem: String?

    var body: some View {
        let groups = store.categoryVendorGroups(matching: query)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        List {
            Section {
#if os(iOS)
                Text("Open a category to see the vendors assigned to it. Uncategorized is first. Choose a category under a vendor to move it and its transactions there. Add a category here, the same way as on Recent. Delete moves that category's vendors to Uncategorized. A transaction you set one by one keeps its own category.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
#else
                Text("Open a category to see the vendors assigned to it. Uncategorized is first. Choose a category at the right of a vendor to move it and its transactions there. Add a category here, the same way as on Recent transactions. Delete moves that category's vendors to Uncategorized. A transaction you set one by one keeps its own category.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
#endif
            }
            Section {
                HStack {
                    TextField("New category", text: $newCategoryName)
#if os(iOS)
                        .font(.subheadline)
#endif
#if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .onSubmit { addListedCategory() }
                        .onChange(of: newCategoryName) { _, _ in newCategoryProblem = nil }
                        .ranchEntry($newCategoryName)
                    Button("Add") { addListedCategory() }
                        .buttonStyle(.borderedProminent)
#if os(iOS)
                        .controlSize(.small)
#endif
                        .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let newCategoryProblem {
                    Text(newCategoryProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if groups.isEmpty {
                Section {
                    Text(searching ? "No category or vendor matches." : "No categories yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
#if os(tvOS)
                Section {
                    categoryDelete(group.category)
                    vendorRows(group)
                } header: {
                    Text(group.category.name)
                }
#elseif os(iOS)
                DisclosureGroup(isExpanded: expansion(group.category.id, searching: searching)) {
                    vendorRows(group)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.category.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text("\(group.vendors.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        categoryDelete(group.category)
                            .controlSize(.small)
                    }
                }
#else
                DisclosureGroup(isExpanded: expansion(group.category.id, searching: searching)) {
                    vendorRows(group)
                } label: {
                    HStack {
                        Text(group.category.name)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text("\(group.vendors.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        categoryDelete(group.category)
                    }
                }
#endif
            }
        }
        .searchable(text: $query, prompt: "Category or vendor")
    }

    @ViewBuilder
    private func categoryDelete(_ category: RanchOSFinanceCategory) -> some View {
        if !category.isUncategorized {
            Button("Delete", role: .destructive) {
                _ = store.deleteCategory(id: category.id)
            }
            .buttonStyle(.bordered)
        }
    }

    private func addListedCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 64 {
            newCategoryProblem = "Use 64 characters or fewer."
            return
        }
        if trimmed.lowercased() == "other" {
            newCategoryProblem = "Other is Uncategorized. Choose another name."
            return
        }
        if store.ledger.categories.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            newCategoryProblem = "\(trimmed) is already a category."
            return
        }
        guard let created = store.createCategory(name: trimmed) else {
            newCategoryProblem = "Type a name."
            return
        }
        newCategoryName = ""
        newCategoryProblem = nil
        expanded.insert(created.id)
    }

    @ViewBuilder
    private func vendorRows(_ group: RanchOSFinanceCategoryVendors) -> some View {
        if group.vendors.isEmpty {
            Text("No vendors assigned.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        ForEach(group.vendors) { vendor in
            vendorLine(vendor)
        }
    }

    @ViewBuilder
    private func vendorLine(_ vendor: RanchOSFinanceVendor) -> some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink {
                RanchOSFinanceVendorView(store: store, vendorID: vendor.id)
            } label: {
                Text(vendor.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            HStack(alignment: .center, spacing: 8) {
                vendorCategoryPicker(vendor)
                    .font(.subheadline)
                    .controlSize(.small)
                Spacer(minLength: 0)
                Button("New category") {
                    addingCategoryFor = vendor.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            vendorCategoryField(vendor)
        }
        .padding(.vertical, 2)
#else
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                NavigationLink {
                    RanchOSFinanceVendorView(store: store, vendorID: vendor.id)
                } label: {
                    Text(vendor.name)
                }
                Spacer()
                vendorCategoryPicker(vendor)
                    .fixedSize()
                Button("New category") {
                    addingCategoryFor = vendor.id
                }
                .buttonStyle(.bordered)
            }
            vendorCategoryField(vendor)
        }
#endif
    }

    private func vendorCategoryPicker(_ vendor: RanchOSFinanceVendor) -> some View {
        Picker("Category for \(vendor.name)", selection: Binding(
            get: { vendor.categoryID },
            set: { store.assign(vendorID: vendor.id, categoryID: $0) }
        )) {
            ForEach(store.categoriesByName) { category in
                Text(category.name).tag(category.id)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private func vendorCategoryField(_ vendor: RanchOSFinanceVendor) -> some View {
        if addingCategoryFor == vendor.id {
            RanchOSFinanceNewCategoryField(store: store, vendorID: vendor.id) { categoryID in
                addingCategoryFor = nil
                expanded.insert(categoryID)
            }
        }
    }

    private func expansion(_ id: UUID, searching: Bool) -> Binding<Bool> {
        Binding(
            get: { searching || expanded.contains(id) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(id)
                } else {
                    expanded.remove(id)
                }
            }
        )
    }
}

/// Types a category for one vendor. A new name joins the category list and
/// the vendor moves into it. An existing name just moves the vendor.
struct RanchOSFinanceNewCategoryField: View {
    @Bindable var store: RanchOSFinanceStore
    let vendorID: UUID
    var onAdded: (UUID) -> Void = { _ in }

    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("New category", text: $name)
#if os(iOS)
                    .font(.subheadline)
#endif
#if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    .onSubmit { add() }
                    .onChange(of: name) { _, _ in problem = nil }
                    .ranchEntry($name)
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
#if os(iOS)
                    .controlSize(.small)
#endif
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func add() {
        let outcome = store.addCategory(name: name, forVendor: vendorID)
        if let problem = outcome.problem {
            self.problem = problem
        } else if let categoryID = outcome.categoryID {
            name = ""
            problem = nil
            onAdded(categoryID)
        }
    }
}

/// One vendor: category assignment, suggestion label, and every charge from
/// that vendor.
struct RanchOSFinanceVendorView: View {
    @Bindable var store: RanchOSFinanceStore
    let vendorID: UUID

    var body: some View {
        if let vendor = store.vendor(id: vendorID) {
            List {
                Section("Category") {
                    Picker("Category", selection: Binding(
                        get: { vendor.categoryID },
                        set: { store.assign(vendorID: vendor.id, categoryID: $0) }
                    )) {
                        ForEach(store.categoriesByName) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    if vendor.suggestion == .suggested {
                        Text(RanchOSFinanceSuggestionLabels.suggested)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if vendor.suggestion == .unavailable {
                        Text(RanchOSFinanceSuggestionLabels.unavailable)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if vendor.suggestion == .notObvious {
                        Text(RanchOSFinanceSuggestionLabels.notObvious)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    RanchOSFinanceNewCategoryField(store: store, vendorID: vendor.id)
                    Text("Adds the name to the category list and moves this vendor into it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Charges") {
                    let charges = store.charges(vendorID: vendor.id)
                    if charges.isEmpty {
                        Text("No charges from this vendor.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(charges) { charge in
                        RanchOSFinanceChargeRow(store: store, charge: charge)
                    }
                }
            }
            .navigationTitle(vendor.name)
        } else {
            Text("That vendor is no longer listed.")
                .foregroundStyle(.secondary)
        }
    }
}

struct RanchOSFinanceChargeRow: View {
    @Bindable var store: RanchOSFinanceStore
    let charge: RanchOSFinanceCharge
    @State private var pendingAssignment: RanchOSFinanceAssignRequest?
    @State private var showingSplit = false

    private var splitSummary: String? {
        let parts = store.splitParts(for: charge)
        guard !parts.isEmpty else { return nil }
        return parts.map { part in
            "\(store.category(id: part.categoryID)?.name ?? RanchOSFinanceSuggestionLabels.uncategorized) \(RanchOSFinanceMoney.format(part.amount))"
        }.joined(separator: " · ")
    }

    private var merchantName: String {
        charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText
    }

    var body: some View {
        row
            .sheet(isPresented: $showingSplit) {
                RanchOSFinanceSplitSheet(store: store, chargeID: charge.id)
            }
            .sheet(item: $pendingAssignment) { request in
                RanchOSFinanceAssignScopeSheet(store: store, request: request)
            }
    }

    @ViewBuilder
    private var row: some View {
#if os(iOS)
        phoneRow
#else
        macRow
#endif
    }

    /// Vendor and amount share one size. The category sits on the next line
    /// so a long name does not collide with the amount.
    private var phoneRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(merchantName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(charge.amountText)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(RanchOSFinanceDates.display(charge.dateText))
                .font(.caption)
                .foregroundStyle(.secondary)
            if charge.isDuplicate {
                Text("Possible duplicate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let splitSummary {
                Text(splitSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if store.allocatableAmount(charge: charge) > 0 || !store.isSplit(charge) {
                HStack(alignment: .center, spacing: 8) {
                    if store.allocatableAmount(charge: charge) > 0 {
                        Button(store.isSplit(charge) ? "Edit split" : "Split") { showingSplit = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("Divides this transaction across categories")
                    }
                    Spacer(minLength: 0)
                    categoryMenu
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var macRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(categoryName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(RanchOSFinanceDates.display(charge.dateText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(merchantName)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(charge.amountText)
                    if charge.isDuplicate {
                        Text("Possible duplicate")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let splitSummary {
                    Text(splitSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.allocatableAmount(charge: charge) > 0 {
                Button(store.isSplit(charge) ? "Edit split" : "Split") { showingSplit = true }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Divides this transaction across categories")
            }

            if store.isSplit(charge) {
                EmptyView()
            } else if let selectedCategoryID {
                categoryPicker(selectedCategoryID)
                    .frame(minWidth: 148, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(categoryName)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 148, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var categoryMenu: some View {
        if store.isSplit(charge) {
            EmptyView()
        } else if let selectedCategoryID {
            categoryPicker(selectedCategoryID)
                .font(.subheadline)
                .controlSize(.small)
        } else {
            Text(categoryName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func categoryPicker(_ selectedCategoryID: UUID) -> some View {
        Picker("Category", selection: Binding(
            get: { selectedCategoryID },
            set: { propose($0) }
        )) {
            ForEach(store.categoriesByName) { category in
                Text(category.name).tag(category.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityValue(categoryName)
    }

    private var categoryName: String {
        store.categoryName(for: charge)
    }

    private var selectedCategoryID: UUID? {
        store.categoryID(for: charge) ?? store.uncategorizedID
    }

    private func propose(_ categoryID: UUID) {
        guard categoryID != selectedCategoryID else { return }
        pendingAssignment = RanchOSFinanceAssignRequest(chargeID: charge.id, categoryID: categoryID)
    }
}

/// Divides one transaction across categories. He types every amount; Rest
/// fills a piece with whatever is left. Save stays off until the pieces add
/// up to the transaction. Remove split puts it back on its vendor's category.
struct RanchOSFinanceSplitSheet: View {
    @Bindable var store: RanchOSFinanceStore
    let chargeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []

    private struct Row: Identifiable {
        let id = UUID()
        var categoryID: UUID?
        var amountText: String
    }

    private var charge: RanchOSFinanceCharge? {
        store.ledger.charges.first { $0.id == chargeID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let charge {
                    let total = store.allocatableAmount(charge: charge)
                    Section {
                        Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                            .font(.headline)
                        Text("\(RanchOSFinanceDates.display(charge.dateText)) · \(RanchOSFinanceMoney.format(total)) to split")
                            .foregroundStyle(.secondary)
                    }
                    Section("Pieces") {
                        ForEach($rows) { $row in
                            HStack {
                                Picker("Category", selection: $row.categoryID) {
                                    Text("Choose a category").tag(UUID?.none)
                                    ForEach(store.categoriesByName) { category in
                                        Text(category.name).tag(Optional(category.id))
                                    }
                                }
                                .labelsHidden()
                                TextField("Amount", text: $row.amountText, prompt: Text("0.00"))
#if !os(tvOS)
                                    .textFieldStyle(.roundedBorder)
#endif
                                    .frame(width: 140)
                                    .ranchEntry($row.amountText, kind: .number)
                                Button("Rest") { fillRest(rowID: row.id, total: total) }
                                    .buttonStyle(.bordered)
                                    .accessibilityHint("Puts whatever is left in this piece")
                                Button {
                                    rows.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(rows.count <= 2)
                                .accessibilityLabel("Remove this piece")
                            }
                        }
                        Button("Add piece") { rows.append(Row(categoryID: nil, amountText: "")) }
                    }
                    Section {
                        Text(balanceLine(total: total))
                        if let problem = problem(total: total) {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    if store.isSplit(charge) {
                        Section {
                            Button("Remove split", role: .destructive) {
                                store.removeSplit(chargeID: chargeID)
                                dismiss()
                            }
                            Text("The transaction goes back to \(vendorCategoryName(charge)).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("That transaction is no longer listed.")
                }
            }
            .navigationTitle("Split transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save split") { save() }
                        .disabled(charge.map { problem(total: store.allocatableAmount(charge: $0)) != nil } ?? true)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear(perform: load)
    }

    private func load() {
        guard rows.isEmpty, let charge else { return }
        let parts = store.splitParts(for: charge)
        if parts.isEmpty {
            rows = [
                Row(categoryID: store.categoryID(for: charge) ?? store.uncategorizedID, amountText: ""),
                Row(categoryID: nil, amountText: ""),
            ]
        } else {
            rows = parts.map {
                Row(categoryID: $0.categoryID, amountText: NSDecimalNumber(decimal: $0.amount).stringValue)
            }
        }
    }

    private static func parse(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var entered: Decimal {
        rows.reduce(Decimal(0)) { $0 + RanchOSFinanceMoney.roundedCents(Self.parse($1.amountText) ?? 0) }
    }

    private func balanceLine(total: Decimal) -> String {
        let gap = total - entered
        if gap > 0 { return "Left to assign: \(RanchOSFinanceMoney.format(gap))" }
        if gap < 0 { return "Over by \(RanchOSFinanceMoney.format(-gap))" }
        return "The pieces add up to \(RanchOSFinanceMoney.format(total))."
    }

    private func problem(total: Decimal) -> String? {
        var parts: [(categoryID: UUID, amount: Decimal)] = []
        for row in rows {
            guard let categoryID = row.categoryID, let amount = Self.parse(row.amountText) else {
                return "Choose a category and type an amount for every piece."
            }
            parts.append((categoryID, amount))
        }
        return store.splitProblem(chargeID: chargeID, parts: parts)
    }

    private func fillRest(rowID: UUID, total: Decimal) {
        let others = rows.filter { $0.id != rowID }
            .reduce(Decimal(0)) { $0 + RanchOSFinanceMoney.roundedCents(Self.parse($1.amountText) ?? 0) }
        let rest = total - others
        guard rest > 0, let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].amountText = NSDecimalNumber(decimal: RanchOSFinanceMoney.roundedCents(rest)).stringValue
    }

    private func save() {
        let parts = rows.compactMap { row -> (categoryID: UUID, amount: Decimal)? in
            guard let categoryID = row.categoryID, let amount = Self.parse(row.amountText) else { return nil }
            return (categoryID, amount)
        }
        if store.splitCharge(chargeID: chargeID, parts: parts) {
            dismiss()
        }
    }

    private func vendorCategoryName(_ charge: RanchOSFinanceCharge) -> String {
        guard let vendorID = charge.vendorID, let vendor = store.vendor(id: vendorID),
            let category = store.category(id: vendor.categoryID)
        else { return RanchOSFinanceSuggestionLabels.uncategorized }
        return category.name
    }
}

/// The category chosen for one transaction, held until he answers the two
/// scope questions.
struct RanchOSFinanceAssignRequest: Identifiable {
    let id = UUID()
    var chargeID: UUID
    var categoryID: UUID
}

/// Asks, separately, whether the new category covers the current import and
/// whether it covers History. This transaction changes only after Apply.
struct RanchOSFinanceAssignScopeSheet: View {
    @Bindable var store: RanchOSFinanceStore
    let request: RanchOSFinanceAssignRequest
    @Environment(\.dismiss) private var dismiss
    @State private var currentImport: Bool?
    @State private var history: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let charge = store.ledger.charges.first(where: { $0.id == request.chargeID }),
                let category = store.category(id: request.categoryID)
            {
                Text("Apply \(category.name)?")
                    .font(.title3.weight(.semibold))
                Text("\(supplierName(charge)) on \(RanchOSFinanceDates.display(charge.dateText)) will use \(category.name).")
                    .foregroundStyle(.secondary)

                scopeChoice(
                    title: "Current import",
                    prompt: "Change every \(supplierName(charge)) transaction already imported?",
                    answer: $currentImport)
                scopeChoice(
                    title: "History",
                    prompt: "Change every \(supplierName(charge)) transaction in History?",
                    answer: $history)

                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Spacer()
                    Button("Apply") {
                        store.applyAssignment(
                            chargeID: charge.id,
                            categoryID: category.id,
                            currentImport: currentImport == true,
                            history: history == true)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentImport == nil || history == nil)
#if !os(tvOS)
                    .keyboardShortcut(.defaultAction)
#endif
                }
            } else {
                Text("That transaction is no longer listed.")
                Button("Close") { dismiss() }
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }

    private func supplierName(_ charge: RanchOSFinanceCharge) -> String {
        if let vendorID = charge.vendorID, let name = store.vendor(id: vendorID)?.name, !name.isEmpty {
            return name
        }
        return charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText
    }

    private func scopeChoice(title: String, prompt: String, answer: Binding<Bool?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(prompt)
            HStack(spacing: 8) {
                answerButton("Yes", chosen: answer.wrappedValue == true) { answer.wrappedValue = true }
                answerButton("No", chosen: answer.wrappedValue == false) { answer.wrappedValue = false }
            }
        }
    }

    private func answerButton(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: chosen ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .tint(chosen ? Color.accentColor : Color.secondary)
    }
}

/// Filter charges by vendor or merchant, select any number, and apply one
/// category to that selection. The vendor's category is not changed.
struct RanchOSFinanceBulkAssignView: View {
    @Bindable var store: RanchOSFinanceStore
    @State private var filter = ""
    @State private var selection = Set<UUID>()
    @State private var categoryID: UUID?

    var body: some View {
        let charges = store.charges(matchingVendorFilter: filter)
        List(charges, selection: $selection) { charge in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(charge.amountText)
                        .font(.subheadline)
                }
                Text("\(charge.dateText) · \(categoryName(charge))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(charge.id)
        }
        .navigationTitle("Assign charges")
        .searchable(text: $filter, prompt: "Vendor, supplier, or store")
#if os(iOS)
        .environment(\.editMode, .constant(.active))
#endif
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Category", selection: $categoryID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(store.categoriesByName) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                Button("Apply to \(selection.count) selected") {
                    if let categoryID {
                        store.assign(chargeIDs: selection, categoryID: categoryID)
                        selection.removeAll()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || categoryID == nil)
                Text("This changes the selected charges only. A split on a selected charge ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
        }
    }

    private func categoryName(_ charge: RanchOSFinanceCharge) -> String {
        store.categoryName(for: charge)
    }
}

/// One category row. Rename opens the name for editing; Return or Save keeps
/// it, Escape or Cancel puts the old name back. A refused name stays open
/// with the reason under it. Uncategorized cannot be renamed or deleted.
struct RanchOSFinanceCategoryRow: View {
    @Bindable var store: RanchOSFinanceStore
    let categoryID: UUID
    var onDelete: (() -> Void)?

    @State private var draft = ""
    @State private var editing = false
    @State private var problem: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if let category = store.category(id: categoryID) {
#if os(iOS)
            VStack(alignment: .leading, spacing: 6) {
                categoryText(category)
                categoryActions(category)
            }
            .padding(.vertical, 2)
#else
            HStack {
                categoryText(category)
                Spacer()
                categoryActions(category)
            }
#endif
        }
    }

    @ViewBuilder
    private func categoryText(_ category: RanchOSFinanceCategory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if editing {
                TextField("Category name", text: $draft)
                    .font(.subheadline.weight(.medium))
#if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    .ranchEntry($draft)
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit { commit(category: category) }
#if !os(iOS)
                    .onExitCommand { cancel(category: category) }
#endif
                    .onChange(of: draft) { _, _ in problem = nil }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text(category.name)
                    .font(.subheadline.weight(.medium))
            }
            Text("\(store.vendors(categoryID: category.id).count) vendors")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func categoryActions(_ category: RanchOSFinanceCategory) -> some View {
        if editing {
            HStack(spacing: 8) {
                Button("Cancel") { cancel(category: category) }
                    .buttonStyle(.bordered)
                Button("Save") { commit(category: category) }
                    .buttonStyle(.borderedProminent)
            }
#if os(iOS)
            .controlSize(.small)
#endif
        } else if !category.isUncategorized {
            HStack(spacing: 8) {
                Button("Rename") { beginRename(category: category) }
                    .buttonStyle(.bordered)
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                }
            }
#if os(iOS)
            .controlSize(.small)
#endif
        }
    }

    private func beginRename(category: RanchOSFinanceCategory) {
        draft = category.name
        problem = nil
        editing = true
    }

    private func commit(category: RanchOSFinanceCategory) {
        if let reason = store.categoryRenameProblem(id: category.id, newName: draft) {
            problem = reason
            fieldFocused = true
            return
        }
        store.renameCategory(id: category.id, newName: draft)
        editing = false
    }

    private func cancel(category: RanchOSFinanceCategory) {
        draft = category.name
        problem = nil
        editing = false
    }
}
