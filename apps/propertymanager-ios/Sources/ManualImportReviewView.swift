import SwiftUI

/// Proposed tasks from Extract. Duplicates of stored tasks or of earlier
/// proposals start unchecked, matching the Mac review sheet.
struct ManualImportReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let review: ManualImportReview
    let onImport: ([ManualImportDraft]) async -> ManualImportOutcome

    @State private var drafts: [ManualImportDraft]
    @State private var isImporting = false
    @State private var importError: String?

    init(review: ManualImportReview, onImport: @escaping ([ManualImportDraft]) async -> ManualImportOutcome) {
        self.review = review
        self.onImport = onImport
        _drafts = State(initialValue: review.drafts)
    }

    private var newIndices: [Int] {
        drafts.indices.filter { review.duplicateNotes[drafts[$0].id] == nil }
    }

    private var duplicateIndices: [Int] {
        drafts.indices.filter { review.duplicateNotes[drafts[$0].id] != nil }
    }

    private var selectedCount: Int { drafts.filter(\.selected).count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(review.manual.title) for \(review.assetName)")
                        .font(.subheadline)
                    if review.unreadSections > 0 {
                        Text("\(review.unreadSections) manual section(s) could not be read on this device. Review the PDF for anything missing.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let importError {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("New tasks (\(newIndices.count))") {
                    if newIndices.isEmpty {
                        Text("Every proposal matches a task already stored for this asset.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(newIndices, id: \.self) { index in
                        draftRow(index)
                    }
                }

                if !duplicateIndices.isEmpty {
                    Section {
                        ForEach(duplicateIndices, id: \.self) { index in
                            draftRow(index)
                        }
                    } header: {
                        Text("Duplicates (\(duplicateIndices.count))")
                    } footer: {
                        Text("Unchecked so the same maintenance is not added twice. Check one only if it is really different work.")
                    }
                }
            }
            .navigationTitle("Review Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button("Import Selected (\(selectedCount))") {
                            Task { await importSelected() }
                        }
                        .disabled(selectedCount == 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func draftRow(_ index: Int) -> some View {
        let draft = drafts[index]
        Toggle(isOn: $drafts[index].selected) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.item)
                    .font(.body.weight(.semibold))
                Text("\(draft.frequency.rawValue) · \(draft.category) · \(draft.estimatedMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = review.duplicateNotes[draft.id] {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(draft.responseInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .disabled(isImporting)
    }

    private func importSelected() async {
        isImporting = true
        importError = nil
        let outcome = await onImport(drafts.filter(\.selected))
        isImporting = false
        guard let failure = outcome.failure else {
            dismiss()
            return
        }
        drafts.removeAll { outcome.importedDraftIDs.contains($0.id) }
        importError = failure
    }
}

struct ManualImportOutcome {
    let importedDraftIDs: Set<UUID>
    let failure: String?
}
