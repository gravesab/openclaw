import SwiftUI
import UniformTypeIdentifiers

/// Finance's Reports page: one month for one account, as the summary cards
/// read it. tvOS compiles this and never presents it.
struct RanchOSFinanceReportsPage: View {
    let store: RanchOSFinanceStore

    @State private var account = RanchOSFinanceChartAccountFilter.all
    @State private var monthID: String?
    @State private var openCategoryIDs: Set<UUID> = []
    @State private var exporting = false
    @State private var exportMessage: String?

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
                }
                Text("Opens on the latest month with transactions.")
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
                    .font(.headline)
                LabeledContent("Income", value: RanchOSFinanceMoney.format(report.income))
                LabeledContent("Expenses", value: RanchOSFinanceMoney.format(report.expenses))
                Divider()
                LabeledContent("Remaining") {
                    Text(RanchOSFinanceMoney.format(report.remaining))
                        .fontWeight(.semibold)
                        .foregroundStyle(report.remaining < 0 ? Color.red : Color.primary)
                }
                LabeledContent("Transactions", value: "\(report.transactionCount)")
                if report.duplicatesLeftOut > 0 {
                    LabeledContent("Duplicates left out", value: "\(report.duplicatesLeftOut)")
                }
                LabeledContent(
                    RanchOSFinanceSuggestionLabels.uncategorized,
                    value: RanchOSFinanceMoney.format(report.uncategorizedExpenses))
                if report.uncategorizedExpenses > 0 {
                    Text("Assign these on Recent transactions or the Categories page.")
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
                        HStack {
                            Image(systemName: openCategoryIDs.contains(category.categoryID)
                                ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                            Text(category.name)
                            Spacer()
                            Text("\(RanchOSFinanceMoney.format(category.total)) · \(category.percent)")
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the vendors in this category")
                    if openCategoryIDs.contains(category.categoryID) {
                        ForEach(category.vendors) { vendor in
                            LabeledContent(vendor.name, value: RanchOSFinanceMoney.format(vendor.total))
                                .font(.subheadline)
                                .padding(.leading, 28)
                        }
                    }
                }
                if !report.categories.isEmpty {
                    Text("Largest first. Click a category to see its vendors.")
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
                    Text("No chart filters yet. On Charts, use New filter to make groups such as Ranch or Household.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(report.groups) { group in
                        LabeledContent(group.name, value: RanchOSFinanceMoney.format(group.expenses))
                    }
                    LabeledContent("In no chart filter", value: RanchOSFinanceMoney.format(report.expensesOutsideGroups))
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
                    .font(.headline)
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
        HStack {
            Text(name)
            Spacer()
            Text("\(RanchOSFinanceMoney.format(now)) · \(RanchOSFinanceMoney.format(then))")
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func export(_ report: RanchOSFinanceSummaryReport) -> some View {
#if !os(tvOS)
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
