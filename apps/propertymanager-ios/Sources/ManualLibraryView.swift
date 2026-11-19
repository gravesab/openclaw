import SwiftUI
import UniformTypeIdentifiers

struct ManualLibraryView: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var assetID: UUID?
    @State private var manuals: [AssetManualLibraryEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showFileImporter = false
    @State private var isUploading = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var extractingManualID: UUID?
    @State private var extractionProgress: ManualExtractionProgress?
    @State private var extractionTask: Task<Void, Never>?
    @State private var review: ManualImportReview?
    @State private var libraryPDFs: [DashboardLibraryPDF] = []
    @State private var isLoadingLibrary = false
    @State private var libraryError: String?
    @State private var connectingPath: String?

    init(initialAssetID: UUID?) {
        _assetID = State(initialValue: initialAssetID)
    }

    private var sortedAssets: [RanchAsset] {
        store.assets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isBusy: Bool { isUploading || extractingManualID != nil || connectingPath != nil }

    private var suggestedPDFs: [DashboardLibraryPDF] {
        guard let name = store.assets.first(where: { $0.id == assetID })?.name else { return [] }
        return libraryPDFs.filter { $0.isSuggested(forAssetName: name) }
    }

    var body: some View {
        List {
            Section("Asset") {
                Picker("Asset", selection: $assetID) {
                    Text("Choose an asset").tag(UUID?.none)
                    ForEach(sortedAssets) { asset in
                        Text(asset.name).tag(Optional(asset.id))
                    }
                }
                .disabled(isBusy)
            }

            if assetID != nil {
                Section {
                    if isLoadingLibrary && libraryPDFs.isEmpty {
                        ProgressView("Loading Dashboard library…")
                    } else if let libraryError {
                        Text(libraryError)
                            .foregroundStyle(.red)
                    }
                    ForEach(suggestedPDFs) { pdf in
                        libraryRow(pdf)
                    }
                    if !libraryPDFs.isEmpty {
                        NavigationLink {
                            DashboardLibraryPickerView(pdfs: libraryPDFs) { pdf in
                                connectAndExtract(pdf)
                            }
                        } label: {
                            Label("All Library PDFs (\(libraryPDFs.count))", systemImage: "folder")
                        }
                        .disabled(isBusy)
                    }
                } header: {
                    Text("Dashboard Library")
                } footer: {
                    Text("Upload PDFs on the Dashboard into the Assets folder. Tap one to connect it to this asset and Extract.")
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(messageIsError ? .red : .secondary)
                    }
                }

                Section("Connected manuals") {
                    if isLoading && manuals.isEmpty {
                        ProgressView("Loading manuals…")
                    } else if let loadError {
                        Text(loadError)
                            .foregroundStyle(.red)
                    } else if manuals.isEmpty {
                        Text("No manuals connected yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manuals) { manual in
                            manualRow(manual)
                        }
                    }
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Upload a PDF from Files…", systemImage: "doc.badge.plus")
                    }
                    .disabled(isBusy)
                    if isUploading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Uploading and connecting…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("An identical copy already in the library is reused.")
                }
            }
        }
        .navigationTitle("Manual Library")
        .refreshable {
            await loadManuals()
            await loadLibrary()
        }
        .task(id: assetID) {
            message = nil
            await loadManuals()
        }
        .task {
            await loadLibrary()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await loadManuals()
                    await loadLibrary()
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                Task { await upload(url) }
            case .failure(let error):
                show(error.localizedDescription, isError: true)
            }
        }
        .sheet(item: $review) { current in
            ManualImportReviewView(review: current) { selected in
                await importSelected(selected, from: current)
            }
            .interactiveDismissDisabled()
        }
        .onDisappear {
            extractionTask?.cancel()
        }
    }

    private func libraryRow(_ pdf: DashboardLibraryPDF) -> some View {
        Button {
            connectAndExtract(pdf)
        } label: {
            HStack(spacing: 12) {
                DashboardLibraryPDFLabel(pdf: pdf)
                Spacer()
                if connectingPath == pdf.relativePath {
                    ProgressView()
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private func manualRow(_ manual: AssetManualLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(manual.title)
                .font(.headline)
            Text(statusLine(manual))
                .font(.caption)
                .foregroundStyle(.secondary)
            if extractingManualID == manual.id {
                if let progress = extractionProgress, progress.totalSections > 0 {
                    ProgressView(
                        value: Double(progress.completedSections),
                        total: Double(progress.totalSections)
                    ) {
                        Text("Reading section \(min(progress.completedSections + 1, progress.totalSections)) of \(progress.totalSections) · \(progress.discoveredDrafts) tasks found")
                            .font(.caption)
                    }
                } else {
                    ProgressView("Downloading manual…")
                        .font(.caption)
                }
                Button("Cancel", role: .cancel) {
                    extractionTask?.cancel()
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    startExtract(manual)
                } label: {
                    Label("Extract", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusLine(_ manual: AssetManualLibraryEntry) -> String {
        var parts = [manual.documentType.replacingOccurrences(of: "_", with: " ").capitalized]
        parts.append("v\(manual.versionNumber)")
        parts.append(manual.taskCount == 1 ? "1 task" : "\(manual.taskCount) tasks")
        parts.append(manual.extractedAt == nil ? "not extracted" : "extracted")
        return parts.joined(separator: " · ")
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    private func loadManuals() async {
        guard let assetID else {
            manuals = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await store.client.fetchAssetManuals(assetID: assetID)
            guard assetID == self.assetID else { return }
            manuals = fetched
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.localizedDescription
        }
    }

    private func loadLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            libraryPDFs = try await store.client.fetchDashboardLibraryPDFs(
                manualLibraryBaseURL: store.manualLibraryBaseURL
            )
            libraryError = nil
        } catch {
            guard !error.isCancellation else { return }
            libraryError = error.localizedDescription
        }
    }

    private func connectAndExtract(_ pdf: DashboardLibraryPDF) {
        guard let assetID, !isBusy else { return }
        connectingPath = pdf.relativePath
        message = nil
        Task {
            do {
                let versionID = try await store.client.connectDashboardLibraryPDF(
                    pdf,
                    assetID: assetID,
                    manualLibraryBaseURL: store.manualLibraryBaseURL
                )
                await loadManuals()
                connectingPath = nil
                if let manual = manuals.first(where: { $0.versionID == versionID }) {
                    startExtract(manual)
                } else {
                    show("\(pdf.filename) is connected. Tap Extract on it below.", isError: false)
                }
            } catch {
                connectingPath = nil
                show(error.localizedDescription, isError: true)
            }
        }
    }

    private func upload(_ url: URL) async {
        guard let assetID else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let pdf = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            let reply = try await store.client.uploadManualToLibrary(
                pdf: pdf,
                filename: url.lastPathComponent,
                assetID: assetID,
                manualLibraryBaseURL: store.manualLibraryBaseURL
            )
            show(reply, isError: false)
            await loadManuals()
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func startExtract(_ manual: AssetManualLibraryEntry) {
        extractingManualID = manual.id
        extractionProgress = nil
        message = nil
        extractionTask = Task {
            await extract(manual)
            extractingManualID = nil
            extractionProgress = nil
            extractionTask = nil
        }
    }

    private func extract(_ manual: AssetManualLibraryEntry) async {
        do {
            let pdf = try await store.client.downloadAssetManual(
                manual,
                manualLibraryBaseURL: store.manualLibraryBaseURL
            )
            let result = try await AppleManualExtractor.extract(
                pdf: pdf,
                manualName: manual.sourceDisplayName
            ) { progress in
                extractionProgress = progress
            }
            _ = try await store.client.recordAssetManualExtraction(
                manual,
                extractorName: AppleManualExtractor.extractorName,
                extractorVersion: AppleManualExtractor.extractorVersion,
                chunks: result.chunks
            )
            if store.tasks.isEmpty {
                await store.refresh()
            }
            let drafts = ManualImportReviewSelection.applyingDefaultSelection(
                drafts: result.drafts,
                existingTasks: store.tasks,
                assetID: manual.assetID
            )
            let notes = ManualImportReviewSelection.notes(
                drafts: result.drafts,
                existingTasks: store.tasks,
                assetID: manual.assetID
            )
            review = ManualImportReview(
                manual: manual,
                assetName: store.assets.first { $0.id == manual.assetID }?.name ?? manual.title,
                drafts: drafts,
                duplicateNotes: notes,
                unreadSections: result.unreadSections
            )
            await loadManuals()
        } catch is CancellationError {
            show("Extract cancelled. Nothing was imported.", isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func importSelected(_ drafts: [ManualImportDraft], from review: ManualImportReview) async -> ManualImportOutcome {
        var createdIDs: [UUID] = []
        var importedDraftIDs: Set<UUID> = []
        var failures: [String] = []
        for draft in drafts {
            do {
                let task = try await store.client.createTask(payload: draft.taskPayload(assetID: review.manual.assetID))
                createdIDs.append(task.id)
                importedDraftIDs.insert(draft.id)
            } catch {
                failures.append("\(draft.item): \(error.localizedDescription)")
            }
        }
        if !createdIDs.isEmpty {
            do {
                try await store.client.linkAssetManualTasks(review.manual, taskIDs: createdIDs)
            } catch {
                failures.append("Linking to the manual failed: \(error.localizedDescription)")
            }
        }
        await store.refresh()
        await loadManuals()
        let summary = createdIDs.count == 1 ? "Imported 1 task." : "Imported \(createdIDs.count) tasks."
        if failures.isEmpty {
            show(summary, isError: false)
            return ManualImportOutcome(importedDraftIDs: importedDraftIDs, failure: nil)
        }
        show(summary + " " + failures.joined(separator: " "), isError: true)
        return ManualImportOutcome(
            importedDraftIDs: importedDraftIDs,
            failure: summary + "\n" + failures.joined(separator: "\n")
        )
    }
}

struct DashboardLibraryPDFLabel: View {
    let pdf: DashboardLibraryPDF

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pdf.title.isEmpty ? pdf.filename : pdf.title)
                .foregroundStyle(.primary)
            Text(pdf.folder.isEmpty ? pdf.filename : "\(pdf.folder) · \(pdf.filename)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Every Assets-library PDF, filtered by any word. Picking one returns to the library to connect and Extract.
struct DashboardLibraryPickerView: View {
    let pdfs: [DashboardLibraryPDF]
    let onPick: (DashboardLibraryPDF) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var visiblePDFs: [DashboardLibraryPDF] {
        let words = TaskSearch.words(in: searchText)
        return pdfs.filter { TaskSearch.matches(fields: [$0.title, $0.relativePath], words: words) }
    }

    var body: some View {
        List(visiblePDFs) { pdf in
            Button {
                dismiss()
                onPick(pdf)
            } label: {
                DashboardLibraryPDFLabel(pdf: pdf)
            }
        }
        .overlay {
            if visiblePDFs.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Dashboard Library")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Filter PDFs (any word)"
        )
    }
}

struct ManualImportReview: Identifiable {
    let id = UUID()
    let manual: AssetManualLibraryEntry
    let assetName: String
    let drafts: [ManualImportDraft]
    let duplicateNotes: [UUID: String]
    let unreadSections: Int
}
