import SwiftUI

/// DEV Finance import-result view. Reads a chosen Apple Card CSV in memory only.
struct RanchOSFinanceImportResultView: View {
    @State private var display: FinanceImportDisplay?
    @State private var failure: FinanceImportParseError?
    @State private var showingPicker = false

    var body: some View {
        #if os(tvOS)
        content
        #else
        content
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: FinanceImportResultLoader.readableTypes
            ) { result in
                handlePicked(result)
            }
        #endif
    }

    private var content: some View {
        Group {
            if failure != nil {
                errorState
            } else if let display {
                resultView(display)
            } else {
                emptyState
            }
        }
        .navigationTitle("Finance")
    }

    private func resultView(_ result: FinanceImportDisplay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FinanceImportResultStrings.banner)
                .font(.caption.weight(.bold))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.fileName)
                    .font(.headline)
                Text(result.sha256)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Rows: \(result.rowCount)")
                    .font(.subheadline.weight(.medium))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

            Text(result.errors.isEmpty ? "No validation errors" : "\(result.errors.count) validation errors")
                .font(.subheadline.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("Choose file") { showingPicker = true }
                Button("Clear") {
                    display = nil
                    failure = nil
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FinanceImportResultStrings.banner)
                .font(.caption.weight(.bold))
            Text(FinanceImportResultStrings.walletInstructions)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Choose file") { showingPicker = true }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FinanceImportResultStrings.banner)
                .font(.caption.weight(.bold))
            Text(failure == .notThisCSV ? FinanceImportResultStrings.notThisCSV : FinanceImportResultStrings.unreadable)
                .font(.footnote.weight(.medium))
            Button("Choose file") { showingPicker = true }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                display = try FinanceImportResultLoader.load(from: url)
                failure = nil
            } catch let error as FinanceImportParseError {
                display = nil
                failure = error
            } catch {
                display = nil
                failure = .unreadable
            }
        case .failure:
            display = nil
            failure = .unreadable
        }
    }
}
