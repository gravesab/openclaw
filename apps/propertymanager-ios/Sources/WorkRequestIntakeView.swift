import PhotosUI
import SwiftUI
import UIKit

struct WorkRequestIntakeView: View {
    @EnvironmentObject private var store: PropertyStore
    @State private var draft = WorkRequestIntakeDraft()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var isSubmitting = false
    @State private var confirmation: SubmittedWorkRequest?
    @State private var assistant = WorkRequestDraftAssistant()
    @State private var dictation = WorkRequestDictation()
    @State private var quantityEdits: [Int: String] = [:]

    var body: some View {
        Form {
            Section("Describe the work") {
                TextEditor(text: $draft.description)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Describe the work")
                Button(dictation.isListening ? "Stop dictation" : "Dictate report") {
                    Task { await dictation.toggle() }
                }
                .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate report")
                if !dictation.transcript.isEmpty {
                    Text(dictation.transcript)
                        .accessibilityLabel("Dictation transcript")
                    Button("Add transcript to description") { insertTranscript() }
                        .accessibilityLabel("Add transcript to description")
                }
                Text(dictation.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Organize draft") {
                Button(assistant.isOrganizing ? "Organizing…" : "Organize draft") {
                    quantityEdits = [:]
                    assistant.organize(report: draft.description, using: AppleWorkRequestDraftGenerator())
                }
                .disabled(assistant.isOrganizing || draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Organize draft")
                if assistant.isOrganizing {
                    Button("Cancel organization") { assistant.cancel() }
                        .accessibilityLabel("Cancel organization")
                }
                Text(assistant.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let review = assistant.review {
                    reviewControls(review)
                }
            }
            Section("Location") {
                Picker("Asset", selection: $draft.assetID) {
                    Text("No asset selected").tag(UUID?.none)
                    ForEach(store.assets) { asset in
                        Text(asset.name).tag(UUID?.some(asset.id))
                    }
                }
                TextField("Area or location", text: $draft.area)
            }
            Section("Photos") {
                PhotosPicker("Add photos", selection: $photoItems, maxSelectionCount: 5, matching: .images)
                if !photos.isEmpty { Text("\(photos.count) photo(s) ready to upload") }
            }
            Section("Draft parts or materials") {
                ForEach($draft.materials) { $material in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $material.name)
                        HStack {
                            TextField("Quantity", text: $material.quantity).keyboardType(.decimalPad)
                            TextField("Unit", text: $material.unit)
                        }
                        TextField("Note", text: $material.note)
                    }
                }
                Button("Add material") { draft.materials.append(.manualEntry()) }
            }
            if draft.hasFrozenSubmission {
                Section("Retry") {
                    Text("A submission already started. Retry sends that same request.")
                    Button("Start a new request") { draft.releaseFrozenSubmission() }
                        .accessibilityLabel("Start a new request")
                }
            }
            Section {
                Button(submitTitle) {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
                .accessibilityLabel(submitTitle)
            } footer: {
                Text("Organize draft stays on this device. Submit sends the reviewed request and selected photos to the configured PropertyManager service. Submitting does not schedule maintenance, change meters, purchase materials, or create a cost.")
            }
        }
        .navigationTitle("Submit Work Request")
        .onDisappear { dictation.stop() }
        .onChange(of: draft.description) { _, newValue in
            assistant.invalidateIfReportChanged(newValue)
        }
        .onChange(of: photoItems) { _, newItems in
            guard draft.replacePhotoSelection() else {
                store.errorMessage = "Retry sends the original request. Start a new request before changing photos."
                return
            }
            Task {
                photos = await newItems.asyncCompactMap { item in
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return nil }
                    return image.jpegData(compressionQuality: 0.9)
                }
            }
        }
        .alert("Work request submitted", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("OK", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation.map { "Request \($0.requestNumber) is \($0.intakeState)." } ?? "")
        }
    }

    private var submitTitle: String {
        if isSubmitting { return "Submitting…" }
        return draft.hasFrozenSubmission ? "Retry work request" : "Submit work request"
    }

    @ViewBuilder
    private func reviewControls(_ review: WorkRequestDraftReview) -> some View {
        if let area = review.areaText {
            LabeledContent("Suggested area", value: area)
            Button("Apply area") {
                if let message = assistant.applyArea(report: draft.description, to: &draft) {
                    assistantStatus(message)
                }
            }
            .accessibilityLabel("Apply suggested area")
        }
        assetSuggestion(review)
        ForEach(Array(review.materials.enumerated()), id: \.offset) { index, material in
            VStack(alignment: .leading, spacing: 6) {
                Text(material.name)
                Text(material.sourceExcerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if material.quantityText == nil {
                    TextField("Quantity", text: quantityBinding(index))
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Quantity for \(material.name)")
                } else {
                    Text("Quantity \(material.quantityText ?? "") \(material.unit)")
                }
                Button("Apply \(material.name)") { applyMaterial(index) }
                    .accessibilityLabel("Apply \(material.name)")
            }
        }
        ForEach(Array(review.reviewNotes.enumerated()), id: \.offset) { _, note in
            Text(note)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func assetSuggestion(_ review: WorkRequestDraftReview) -> some View {
        switch AssetMentionMatcher.match(
            mention: review.assetMention,
            assets: store.assets.map { NamedAsset(id: $0.id, name: $0.name) }
        ) {
        case .notSuggested:
            EmptyView()
        case .noMatch:
            Text("No loaded asset matches “\(review.assetMention ?? "")”. Choose an asset or keep the area.")
        case .unique(let asset):
            Button("Use asset \(asset.name)") { draft.assetID = asset.id }
                .accessibilityLabel("Use asset \(asset.name)")
        case .ambiguous(let assets):
            Text("More than one asset matches. Choose the asset yourself: \(assets.map(\.name).joined(separator: ", ")).")
        }
    }

    private func quantityBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { quantityEdits[index, default: ""] },
            set: { quantityEdits[index] = $0 }
        )
    }

    private func applyMaterial(_ index: Int) {
        switch assistant.preparedMaterial(
            report: draft.description,
            index: index,
            quantityOverride: quantityEdits[index]
        ) {
        case .ready(let material):
            draft.materials.append(material)
        case .rejected(let message):
            store.errorMessage = message
        }
    }

    private func assistantStatus(_ message: String) {
        store.errorMessage = message
    }

    private func insertTranscript() {
        let addition = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return }
        if draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.description = addition
        } else {
            draft.description += "\n\(addition)"
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if !draft.hasFrozenSubmission {
                draft.attachmentIDs = try await store.uploadWorkRequestPhotos(
                    photos,
                    existingAttachmentIDs: draft.attachmentIDs,
                    idempotencyKey: draft.idempotencyKey
                )
            }
            let (payload, idempotencyKey) = try draft.beginSubmissionAttempt()
            confirmation = try await store.submitWorkRequest(payload, idempotencyKey: idempotencyKey)
            draft.resetAfterSuccessfulSubmission()
            photoItems = []
            photos = []
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var results: [T] = []
        for element in self {
            if let value = await transform(element) { results.append(value) }
        }
        return results
    }
}
