import SwiftUI

/// Shared empty-confirm + reassign-before-delete flow for categories.
struct CategoryDeletePresenter: ViewModifier {
    @EnvironmentObject private var store: PropertyStore

    @Binding var categoryPendingDelete: MaintenanceCategory?
    @Binding var showEmptyConfirm: Bool
    @Binding var showReassignSheet: Bool
    @State private var reassignToName: String = "House"

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                categoryPendingDelete.map { "Delete \($0.name)?" } ?? "Delete category?",
                isPresented: $showEmptyConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Category", role: .destructive) {
                    guard let category = categoryPendingDelete else { return }
                    Task {
                        _ = await store.deleteCategory(category)
                        categoryPendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    categoryPendingDelete = nil
                }
            } message: {
                Text("This category has no active tasks and will be removed.")
            }
            .sheet(isPresented: $showReassignSheet) {
                NavigationStack {
                    Form {
                        if let category = categoryPendingDelete {
                            Section {
                                Text(
                                    "\(store.activeTaskCount(inCategoryNamed: category.name)) active task(s) use \(category.name). Choose where to move them, then delete the category."
                                )
                                .foregroundStyle(.secondary)
                            }

                            Section("Move tasks to") {
                                Picker("Destination", selection: $reassignToName) {
                                    ForEach(store.destinationCategories(excluding: category.name)) { destination in
                                        Text(destination.name).tag(destination.name)
                                    }
                                }
                                .pickerStyle(.inline)
                                .labelsHidden()
                            }
                        }
                    }
                    .navigationTitle("Move & Delete")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showReassignSheet = false
                                categoryPendingDelete = nil
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Move & Delete", role: .destructive) {
                                guard let category = categoryPendingDelete else { return }
                                Task {
                                    _ = await store.deleteCategory(category, reassignTo: reassignToName)
                                    showReassignSheet = false
                                    categoryPendingDelete = nil
                                }
                            }
                            .disabled(reassignToName.isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .onChange(of: showReassignSheet) { _, isPresented in
                guard isPresented, let category = categoryPendingDelete else { return }
                let destinations = store.destinationCategories(excluding: category.name)
                if let house = destinations.first(where: { $0.name.caseInsensitiveCompare("House") == .orderedSame }) {
                    reassignToName = house.name
                } else {
                    reassignToName = destinations.first?.name ?? ""
                }
            }
    }
}

extension View {
    func categoryDeleteFlow(
        categoryPendingDelete: Binding<MaintenanceCategory?>,
        showEmptyConfirm: Binding<Bool>,
        showReassignSheet: Binding<Bool>
    ) -> some View {
        modifier(
            CategoryDeletePresenter(
                categoryPendingDelete: categoryPendingDelete,
                showEmptyConfirm: showEmptyConfirm,
                showReassignSheet: showReassignSheet
            )
        )
    }
}

enum CategoryDeleteRouting {
    enum NextStep {
        case emptyConfirm
        case reassignSheet
    }

    @MainActor
    static func nextStep(for category: MaintenanceCategory, store: PropertyStore) -> NextStep {
        if store.activeTaskCount(inCategoryNamed: category.name) == 0 {
            return .emptyConfirm
        }
        return .reassignSheet
    }
}
