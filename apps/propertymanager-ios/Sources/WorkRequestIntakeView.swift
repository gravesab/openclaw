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

    var body: some View {
        Form {
            Section("Describe the work") {
                TextEditor(text: $draft.description)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Describe the work")
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
                Button("Add material") { draft.materials.append(WorkRequestMaterial()) }
            }
            Section {
                Button(isSubmitting ? "Submitting…" : "Submit work request") {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
            } footer: {
                Text("Submitting does not schedule maintenance, change meters, purchase materials, or create a cost.")
            }
        }
        .navigationTitle("Submit Work Request")
        .onChange(of: photoItems) { _, newItems in
            Task {
                photos = await newItems.asyncCompactMap { item in
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return nil }
                    return image.jpegData(compressionQuality: 0.9)
                }
                draft.replacePhotoSelection()
            }
        }
        .alert("Work request submitted", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("OK", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation.map { "Request \($0.requestNumber) is \($0.intakeState)." } ?? "")
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            draft.attachmentIDs = try await store.uploadWorkRequestPhotos(
                photos,
                existingAttachmentIDs: draft.attachmentIDs,
                idempotencyKey: draft.idempotencyKey
            )
            confirmation = try await draft.submit { payload, idempotencyKey in
                try await store.submitWorkRequest(payload, idempotencyKey: idempotencyKey)
            }
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
