import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Finance's Reports page: one month for one account, as the summary cards
/// read it. The iPhone and Apple TV open this summary. The Mac and iPad keep
/// the full Finance screens.

/// Monthly expense report for the iPhone and Apple TV. Accounts, categories,
/// and statements stay on the Mac and iPad.
struct RanchOSFinancePhoneSummary: View {
    @State private var store = RanchOSFinanceStore()

    var body: some View {
#if os(iOS)
        summary
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { summaryBanner }
#elseif os(tvOS)
        summary
            .safeAreaInset(edge: .top, spacing: 0) { summaryBanner }
#else
        summary
#endif
    }

    private var summary: some View {
        RanchOSFinanceReportsPage(store: store)
            .navigationTitle("Finance")
            .background(.background)
    }

    private var summaryBanner: some View {
        Text("Monthly summary. Accounts, categories, and statements stay on the Mac and iPad.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background {
#if os(tvOS)
                Rectangle().fill(.regularMaterial)
#else
                Rectangle().fill(.bar)
#endif
            }
    }
}
struct RanchOSFinanceReportsPage: View {
    let store: RanchOSFinanceStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var account = RanchOSFinanceChartAccountFilter.all
    @State private var monthID: String?
    @State private var openCategoryIDs: Set<UUID> = []
    @State private var exporting = false
    @State private var exportMessage: String?

    /// Menu pickers fit the iPhone. Apple TV keeps the focus picker.
    private var usesMenuPickers: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    /// iPhone and Apple TV use the same stacked summary. Mac and iPad keep one line.
    private var usesStackedSummary: Bool {
#if os(tvOS)
        true
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    private var months: [RanchOSFinanceReadyMonth] { store.reportMonths(account: account) }

    private var selectedMonth: RanchOSFinanceReadyMonth? {
        months.first(where: { $0.id == monthID }) ?? months.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filters
                if let month = selectedMonth {
                    let report = store.summaryReport(month: month, account: account)
                    summary(report)
                    categories(report)
                    groups(report)
                    lastYear(report)
                    export(report)
                } else {
                    Text(store.ledger.charges.isEmpty
                        ? "No transactions yet. Reports appear after the first statement comes in."
                        : "No transactions for this account.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.reloadFromDisk() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reloadFromDisk() }
        }
    }

    private var filters: some View {
        RanchOSFinanceChartBox("Report") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Account", selection: $account) {
                    Text("All accounts").tag(RanchOSFinanceChartAccountFilter.all)
                    ForEach(store.accountsByName) { account in
                        Text(store.accountLabel(account)).tag(RanchOSFinanceChartAccountFilter.account(account.id))
                    }
                    if !store.chartMonths(account: .unassigned).isEmpty {
                        Text("No account").tag(RanchOSFinanceChartAccountFilter.unassigned)
                    }
                }
                .ranchReportPicker(phone: usesMenuPickers)
                .onChange(of: account) { _, _ in
                    monthID = nil
                    openCategoryIDs = []
                    exportMessage = nil
                }
                if !months.isEmpty {
                    Picker("Month", selection: monthSelection) {
                        ForEach(months) { month in
                            Text(month.label).tag(month.id)
                        }
                    }
                    .ranchReportPicker(phone: usesMenuPickers)
                }
                Text("Opens on the latest month. Totals include every transaction kept for that month, through the newest one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var monthSelection: Binding<String> {
        Binding(
            get: { selectedMonth?.id ?? "" },
            set: { id in
                monthID = id
                openCategoryIDs = []
                exportMessage = nil
            })
    }

    private func summary(_ report: RanchOSFinanceSummaryReport) -> some View {
        RanchOSFinanceChartBox("Monthly summary") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(report.month.label) · \(report.accountLabel)")
                    .font(usesStackedSummary ? .subheadline.weight(.medium) : .headline)
                Text(report.throughLabel)
                    .font(.subheadline)
                Text("These totals match the transactions kept for this month.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                reportLine("Income", value: RanchOSFinanceMoney.format(report.income))
                reportLine("Expenses", value: RanchOSFinanceMoney.format(report.expenses))
                Divider()
                reportLine(
                    "Remaining",
                    value: RanchOSFinanceMoney.format(report.remaining),
                    emphasize: true,
                    tint: report.remaining < 0 ? Color.red : Color.primary)
                reportLine("Transactions", value: "\(report.transactionCount)")
                if report.duplicatesLeftOut > 0 {
                    reportLine("Duplicates left out", value: "\(report.duplicatesLeftOut)")
                }
                reportLine(
                    RanchOSFinanceSuggestionLabels.uncategorized,
                    value: RanchOSFinanceMoney.format(report.uncategorizedExpenses))
                if report.uncategorizedExpenses > 0 {
                    Text(usesStackedSummary
                        ? "These are assigned on the Mac or iPad."
                        : "Assign these on Recent transactions or the Categories page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(RanchOSFinanceSummaryReport.treatment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func categories(_ report: RanchOSFinanceSummaryReport) -> some View {
        RanchOSFinanceChartBox("Expenses by category") {
            VStack(alignment: .leading, spacing: 8) {
                if report.categories.isEmpty {
                    Text("No expenses this month.")
                        .foregroundStyle(.secondary)
                }
                ForEach(report.categories) { category in
                    Button {
                        if openCategoryIDs.contains(category.categoryID) {
                            openCategoryIDs.remove(category.categoryID)
                        } else {
                            openCategoryIDs.insert(category.categoryID)
                        }
                    } label: {
                        categoryLine(category)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the vendors in this category")
                    if openCategoryIDs.contains(category.categoryID) {
                        ForEach(category.vendors) { vendor in
                            reportLine(vendor.name, value: RanchOSFinanceMoney.format(vendor.total))
                                .padding(.leading, 28)
                        }
                    }
                }
                if !report.categories.isEmpty {
                    Text(usesStackedSummary
                        ? "Largest first. Select a category to see its vendors."
                        : "Largest first. Click a category to see its vendors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func groups(_ report: RanchOSFinanceSummaryReport) -> some View {
        RanchOSFinanceChartBox("Expenses by chart filter") {
            VStack(alignment: .leading, spacing: 8) {
                if report.groups.isEmpty {
                    Text(usesStackedSummary
                        ? "No chart filters yet. Filters are made on the Mac or iPad."
                        : "No chart filters yet. On Charts, use New filter to make groups such as Ranch or Household.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(report.groups) { group in
                        reportLine(group.name, value: RanchOSFinanceMoney.format(group.expenses))
                    }
                    reportLine("In no chart filter", value: RanchOSFinanceMoney.format(report.expensesOutsideGroups))
                        .foregroundStyle(.secondary)
                    Text(report.groupsOverlap
                        ? "Some categories are in more than one filter, so they count in each, and these lines add up to more than Expenses."
                        : "Each category is in at most one filter, so these lines add up to Expenses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lastYear(_ report: RanchOSFinanceSummaryReport) -> some View {
        let prior = report.lastYear
        return RanchOSFinanceChartBox("Same month last year") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(report.month.label) compared with \(prior.label)")
                    .font(usesStackedSummary ? .subheadline.weight(.medium) : .headline)
                compareRow("Income", now: report.income, then: prior.income)
                compareRow("Expenses", now: report.expenses, then: prior.expenses)
                if prior.categories.isEmpty {
                    Text("No expenses in either month.")
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    ForEach(prior.categories) { row in
                        compareRow(row.name, now: row.total, then: row.priorTotal)
                            .font(.subheadline)
                    }
                }
                Text("Each line is this month, then last year.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compareRow(_ name: String, now: Decimal, then: Decimal) -> some View {
        let figures = "\(RanchOSFinanceMoney.format(now)) · \(RanchOSFinanceMoney.format(then))"
        return Group {
            if usesStackedSummary {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline)
                    Text(figures)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text(name)
                    Spacer()
                    Text(figures)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func categoryLine(_ category: RanchOSFinanceReportCategory) -> some View {
        let figures = "\(RanchOSFinanceMoney.format(category.total)) · \(category.percent)"
        if usesStackedSummary {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: openCategoryIDs.contains(category.categoryID)
                        ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(category.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }
                Text(figures)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Image(systemName: openCategoryIDs.contains(category.categoryID)
                    ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                Text(category.name)
                Spacer()
                Text(figures)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func reportLine(
        _ title: String, value: String, emphasize: Bool = false, tint: Color = .primary
    ) -> some View {
        if usesStackedSummary {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(value)
                    .font(.subheadline.weight(emphasize ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        } else if emphasize {
            LabeledContent(title) {
                Text(value)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
            }
        } else {
            LabeledContent(title, value: value)
        }
    }

    @ViewBuilder
    private func export(_ report: RanchOSFinanceSummaryReport) -> some View {
#if os(tvOS)
        RanchOSFinanceChartBox("Export") {
            Text("Export the CSV from the Mac or iPad.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
#elseif !os(tvOS)
        RanchOSFinanceChartBox("Export") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Export CSV") {
                    exportMessage = nil
                    exporting = true
                }
                .buttonStyle(.borderedProminent)
                Text("Writes this month's report as a CSV file. Opens in Numbers or any spreadsheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileExporter(
            isPresented: $exporting,
            document: RanchOSFinanceReportDocument(text: RanchOSFinanceReportCSV.text(report)),
            contentType: .commaSeparatedText,
            defaultFilename: RanchOSFinanceReportCSV.fileName(report)
        ) { result in
            switch result {
            case .success(let url):
                exportMessage = "Exported \(url.lastPathComponent)."
            case .failure(let error):
                exportMessage = "Export did not finish: \(error.localizedDescription)"
            }
        }
#endif
    }
}

private extension View {
    @ViewBuilder
    func ranchReportPicker(phone: Bool) -> some View {
        if phone {
            self.pickerStyle(.menu)
        } else {
            self
        }
    }
}

#if !os(tvOS)
struct RanchOSFinanceReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
#endif
