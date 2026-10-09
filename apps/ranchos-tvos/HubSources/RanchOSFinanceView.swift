import SwiftUI
import UniformTypeIdentifiers

/// Finance screen: ingested statement files, vendors, and categories.
/// iPhone-first; macOS presents the same view. tvOS compiles this file and
/// never presents it. A charge follows its vendor unless he assigned that
/// charge on its own.
struct RanchOSFinanceScreen: View {
    @State private var store = RanchOSFinanceStore()
    @State private var showingImporter = false
    @State private var newCategoryName = ""

    var body: some View {
        NavigationStack {
            List {
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
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.ledger.files) { file in
                        NavigationLink {
                            RanchOSFinanceFileView(store: store, fileID: file.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.fileName)
                                    .font(.subheadline.weight(.medium))
                                Text("\(kindLabel(file.kind)) · \(file.rowCount) rows · \(file.errorCount) errors")
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
                    if store.ledger.vendors.isEmpty {
                        Text("Vendors appear after the first import.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.ledger.vendors) { vendor in
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
#if !os(tvOS)
                            .textFieldStyle(.roundedBorder)
#endif
                            .onSubmit { addCategory() }
                        Button("Add") { addCategory() }
                            .buttonStyle(.borderedProminent)
                            .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Finance")
#if !os(tvOS)
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText]
            ) { result in
                ingest(result: result)
            }
#endif
        }
    }

    private var deletableCategories: [RanchOSFinanceCategory] {
        store.ledger.categories.filter { !$0.isUncategorized }
    }

    private func categoryName(_ id: UUID) -> String {
        store.category(id: id)?.name ?? RanchOSFinanceSuggestionLabels.uncategorized
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case RanchOSFinanceCSV.Kind.appleCard.rawValue: "Apple Card"
        case RanchOSFinanceCSV.Kind.bank.rawValue: "Bank CSV"
        default: "Unrecognized"
        }
    }

    private func addCategory() {
        if store.createCategory(name: newCategoryName) != nil {
            newCategoryName = ""
        }
    }

    private func ingest(result: Result<URL, Error>) {
#if !os(tvOS)
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: url) else { return }
        let outcome = store.ingest(fileName: url.lastPathComponent, bytes: bytes)
        for vendor in outcome.newVendors {
            Task { await store.requestSuggestion(vendorID: vendor.id) }
        }
#endif
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
                    Text("SHA-256 \(file.sha256Hex)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
#if !os(tvOS)
                        .textSelection(.enabled)
#endif
                    Text("\(file.rowCount) rows · \(file.errorCount) validation errors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            NavigationLink {
                                RanchOSFinanceChargeView(store: store, chargeID: charge.id)
                            } label: {
                                RanchOSFinanceChargeRow(store: store, charge: charge)
                            }
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
                        ForEach(store.ledger.categories) { category in
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
                }
                Section("Charges") {
                    let charges = store.charges(vendorID: vendor.id)
                    if charges.isEmpty {
                        Text("No charges from this vendor.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(charges) { charge in
                        NavigationLink {
                            RanchOSFinanceChargeView(store: store, chargeID: charge.id)
                        } label: {
                            RanchOSFinanceChargeRow(store: store, charge: charge)
                        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(charge.merchantText.isEmpty ? "Unknown vendor" : charge.merchantText)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(charge.amountText)
                    .font(.subheadline)
            }
            HStack {
                Text(charge.dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(categoryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if charge.isDuplicate {
                    Text("Possible duplicate")
                        .font(.caption.weight(.medium))
                }
            }
        }
    }

    private var categoryName: String {
        guard let categoryID = store.categoryID(for: charge),
            let category = store.category(id: categoryID)
        else {
            return RanchOSFinanceSuggestionLabels.uncategorized
        }
        return category.name
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
                    ForEach(store.ledger.categories) { category in
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
                Text("This changes the selected charges only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
        }
    }

    private func categoryName(_ charge: RanchOSFinanceCharge) -> String {
        guard let categoryID = store.categoryID(for: charge),
            let category = store.category(id: categoryID)
        else {
            return RanchOSFinanceSuggestionLabels.uncategorized
        }
        return category.name
    }
}

/// One category row: the name is a text field, RenameButton sits in the
/// context menu, and renameAction focuses the field. Same control on iPhone
/// and Mac. Return commits; Escape or leaving the field without committing
/// restores the previous name. The store rejects blank and duplicate names,
/// so a failed commit also restores the previous name.
struct RanchOSFinanceCategoryRow: View {
    @Bindable var store: RanchOSFinanceStore
    let categoryID: UUID
    var onDelete: (() -> Void)?

    @State private var draft = ""
    @FocusState private var isRenaming: Bool

    var body: some View {
        if let category = store.category(id: categoryID) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Category name", text: $draft)
                        .font(.subheadline.weight(.medium))
                        .focused($isRenaming)
                        .onSubmit { commit(category: category) }
#if !os(iOS)
                        .onExitCommand { cancel(category: category) }
#endif
                        .onChange(of: isRenaming) { _, editing in
                            if editing {
                                draft = category.name
                            } else {
                                draft = store.category(id: categoryID)?.name ?? category.name
                            }
                        }
                    Text("\(store.vendors(categoryID: category.id).count) vendors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                }
            }
            .renameAction($isRenaming)
            .contextMenu { RenameButton() }
            .onAppear { draft = category.name }
        }
    }

    private func commit(category: RanchOSFinanceCategory) {
        _ = store.renameCategory(id: category.id, newName: draft)
        isRenaming = false
    }

    private func cancel(category: RanchOSFinanceCategory) {
        draft = category.name
        isRenaming = false
    }
}
