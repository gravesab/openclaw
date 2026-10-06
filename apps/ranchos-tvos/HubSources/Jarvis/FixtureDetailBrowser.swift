#if !os(tvOS)
import SwiftUI

extension FixtureRecord {
    var summary: String {
        switch self {
        case .mower: "The sample asset that connects these expenses, service records, reference material and dealer contact."
        case .repair: "A sample spindle repair associated with the X300. Warranty coverage has not been verified."
        case .fuel: "A sample fuel expense associated with the X300. Quantity and unit price are not supplied."
        case .parts: "A sample replacement-belt expense. Part number and compatibility have not been supplied."
        case .service: "A sample maintenance expense. The service checklist and next due date have not been supplied."
        case .attachment: "A sample attachment expense. The attachment model and serial number have not been supplied."
        case .manual: "A placeholder for the X300 owner manual. No document has been imported or verified."
        case .dealer: "A placeholder dealer associated with the X300. No business identity, telephone number or recipient has been verified."
        }
    }
    var relatedRecords: [FixtureRecord] {
        switch self {
        case .mower: Self.allCases.filter { $0 != .mower }
        case .repair: [.mower, .parts, .service, .dealer]
        case .parts, .service: [.mower, .repair, .manual]
        case .fuel, .attachment, .manual: [.mower]
        case .dealer: [.mower, .repair]
        }
    }
    var expenses: [FixtureExpense] {
        self == .mower ? FixtureExpense.samples : FixtureExpense.samples.filter { $0.record == self }
    }
}

@MainActor struct FixtureDetailBrowser: View {
    let root: FixtureRecord
    let onSelect: (FixtureRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FixtureRecord] = []
    var body: some View {
        NavigationStack(path: $path) {
            detail(root)
                .navigationDestination(for: FixtureRecord.self) { detail($0) }
        }
        .onChange(of: path) { _, records in onSelect(records.last ?? root) }
        .frame(minWidth: 320, idealWidth: 680, minHeight: 460, idealHeight: 650)
    }
    private func detail(_ record: FixtureRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("DEV · SYNTHETIC RECORD", systemImage: "testtube.2")
                    .font(.caption.bold()).foregroundStyle(.mint)
                Text(record.title).font(.largeTitle.bold())
                Text(record.summary).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Record context").font(.headline)
                    LabeledContent("Record ID", value: "sample-\(record.rawValue)")
                    LabeledContent("Asset", value: FixtureRecord.mower.title)
                    LabeledContent("Source", value: "Jarvis fixture · revision 1")
                }
                Divider()
                if !record.expenses.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(record == .mower ? "Related transactions" : "Source transaction").font(.headline)
                        Text(FixtureExpense.format(record.expenses.reduce(0) { $0 + $1.cents }))
                            .font(.title.bold()).monospacedDigit()
                        Text("USD · January–September 2026 · Sample ledger").font(.caption).foregroundStyle(.secondary)
                        ForEach(record.expenses) { expense in
                            if record == .mower {
                                NavigationLink(value: expense.record) {
                                    transactionRow(expense)
                                }.buttonStyle(.plain)
                            } else {
                                transactionRow(expense)
                                Text("Synthetic transaction only. No receipt, bank import or posted ledger entry is connected.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Label(record == .manual ? "Document not connected" : "Contact not verified",
                          systemImage: "info.circle").font(.headline)
                    Text(record == .manual
                         ? "There are no manual pages or maintenance instructions to open in this fixture."
                         : "Calling remains unavailable. A real recipient must be verified before any future call.")
                        .foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Related records").font(.headline)
                    ForEach(record.relatedRecords) { related in
                        NavigationLink(value: related) {
                            HStack {
                                Label(related.title, systemImage: "link")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(24)
        }
        .navigationTitle(record.title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Back to graph") { dismiss() }
            }
        }
    }
    private func transactionRow(_ expense: FixtureExpense) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(expense.record.title).font(.body.bold())
                Text("\(expense.id) · \(expense.date)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(expense.amount).monospacedDigit()
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

#endif
