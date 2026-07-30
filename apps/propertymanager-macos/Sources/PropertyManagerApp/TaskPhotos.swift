import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum TaskPhotoStore {
    static func attachmentsRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let folder = appSupport
            .appendingPathComponent("PropertyManagerApp", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func folder(for taskID: UUID) -> URL {
        let folder = attachmentsRoot().appendingPathComponent(taskID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(taskID: UUID, fileName: String) -> URL {
        folder(for: taskID).appendingPathComponent(fileName)
    }

    static func chooseAndCopyPhoto(into taskID: UUID) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Add photograph to work request"
        panel.prompt = "Add Photo"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP, .tiff, .gif]
        panel.message = "Choose a photo of the problem (fence, damage, location, etc.)."

        guard panel.runModal() == .OK, let source = panel.url else {
            return nil
        }

        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = url(taskID: taskID, fileName: fileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return fileName
        } catch {
            return nil
        }
    }

    static func removePhoto(taskID: UUID, fileName: String) {
        let fileURL = url(taskID: taskID, fileName: fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func removeAllPhotos(taskID: UUID) {
        let folderURL = folder(for: taskID)
        try? FileManager.default.removeItem(at: folderURL)
    }
}

struct TaskPhotoThumbnail: View {
    let taskID: UUID
    let fileName: String
    var maxHeight: CGFloat = 160

    var body: some View {
        let fileURL = TaskPhotoStore.url(taskID: taskID, fileName: fileName)
        if let nsImage = NSImage(contentsOf: fileURL) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.25))
                )
        } else {
            Text("Missing photo file")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
