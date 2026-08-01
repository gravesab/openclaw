import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum TaskPhotoStore {
    /// Selects an existing photo for immediate upload. PropertyManager does not
    /// copy the file locally; PostgreSQL is the durable source of truth.
    static func choosePhoto() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Add photograph to task"
        panel.prompt = "Upload Photo"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP, .tiff, .gif]
        panel.message = "Choose a photo to upload to PropertyManager PostgreSQL."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

struct TaskPhotoThumbnail: View {
    let taskID: UUID
    let fileName: String
    let loadPhoto: (UUID, String) async throws -> Data
    var maxHeight: CGFloat = 160

    @State private var image: NSImage?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView("Loading photo from PostgreSQL…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: fileName) {
            do {
                let data = try await loadPhoto(taskID, fileName)
                guard let downloaded = NSImage(data: data) else {
                    loadError = "PostgreSQL returned an unreadable image."
                    return
                }
                image = downloaded
                loadError = nil
            } catch {
                loadError = "Could not load photo from PostgreSQL: \(error.localizedDescription)"
            }
        }
    }
}
