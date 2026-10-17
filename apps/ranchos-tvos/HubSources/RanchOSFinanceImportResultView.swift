import SwiftUI
import UniformTypeIdentifiers

/// DEV-only Finance import-result view. Renders a synthetic sample held in memory.
struct RanchOSFinanceImportResultView: View {
    @State private var sample: FinanceImportResult?
    @State private var loadFailed = false
    @State private var showingPicker = false

    var body: some View {
        #if os(tvOS)
        content
        #else
        content
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.json]
            ) { result in
                handlePicked(result)
            }
        #endif
    }

    private var content: some View {
        Group {
            if loadFailed {
                errorState
            } else if let sample {
                resultView(sample)
            } else {
                emptyState
            }
        }
        .navigationTitle("Finance")
    }

    private func resultView(_ result: FinanceImportResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(FinanceImportResultStrings.banner)
                        .font(.caption.weight(.bold))
                    Text(FinanceImportResultStrings.syntheticMarker)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Color(red: 0.19, green: 0.35, blue: 0.44).opacity(0.14),
                            in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Produced", value: result.producedAt)
                    LabeledContent("By", value: result.producedBy)
                    LabeledContent("Tenant", value: result.tenantLabel)
                }
                .font(.footnote)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.artifact.fileName)
                        .font(.headline)
                    Text(result.artifact.sha256)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Rows: \(result.artifact.rowCount)")
                        .font(.subheadline.weight(.medium))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(result.errors.count) validation errors")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(result.errors.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Row \(entry.row)")
                                .font(.footnote.weight(.semibold))
                            Text(entry.code)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 12) {
                    Button("Choose sample") { showingPicker = true }
                    Button("Clear") {
                        sample = nil
                        loadFailed = false
                    }
                }
            }
            .padding(24)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FinanceImportResultStrings.banner)
                .font(.caption.weight(.bold))
            Text("On iPhone: open Wallet, tap Apple Card, open Statements, export the monthly CSV.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(FinanceImportResultStrings.emptySentence)
                .font(.footnote.weight(.medium))
            Button("Choose sample") { showingPicker = true }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FinanceImportResultStrings.banner)
                .font(.caption.weight(.bold))
            Text("Could not read that sample.")
                .font(.footnote.weight(.medium))
            Button("Choose sample") { showingPicker = true }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                sample = try FinanceImportResultLoader.load(from: url)
                loadFailed = false
            } catch {
                sample = nil
                loadFailed = true
            }
        case .failure:
            sample = nil
            loadFailed = true
        }
    }
}
