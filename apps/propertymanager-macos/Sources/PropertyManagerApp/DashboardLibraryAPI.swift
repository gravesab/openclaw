import Foundation

/// A PDF uploaded to the Dashboard Assets library. Only its locator is
/// shared, never its bytes.
struct DashboardLibraryPDF: Decodable, Identifiable, Hashable {
    let relativePath: String
    let title: String

    var id: String { relativePath }
    var filename: String { (relativePath as NSString).lastPathComponent }

    /// Subfolder under Assets/, such as "Landscape/Chainsaws", or empty.
    var folder: String {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return "" }
        return parts.dropFirst().dropLast().joined(separator: "/")
    }

    /// True when a word of the asset name (3+ characters) appears in the PDF
    /// path, so "DR Chipper" suggests Assets/DR_Chipper_Manual.pdf.
    func isSuggested(forAssetName name: String) -> Bool {
        let path = relativePath
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
            .contains { path.localizedCaseInsensitiveContains($0) }
    }

    /// Suggested PDFs first, then alphabetical by path.
    static func ordered(_ pdfs: [DashboardLibraryPDF], forAssetName name: String?) -> [DashboardLibraryPDF] {
        pdfs.sorted { lhs, rhs in
            if let name {
                let lhsSuggested = lhs.isSuggested(forAssetName: name)
                let rhsSuggested = rhs.isSuggested(forAssetName: name)
                if lhsSuggested != rhsSuggested { return lhsSuggested }
            }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case title
    }
}

extension PropertyAPIClient {
    func fetchDashboardLibraryPDFs(manualLibraryBaseURL: String) async throws -> [DashboardLibraryPDF] {
        struct LibraryReply: Decodable { let documents: [DashboardLibraryPDF] }
        let url = try Self.manualLibraryURL(manualLibraryBaseURL, path: "/pm/manual-library/api/library")
        var request = URLRequest(url: url)
        applyAuth(&request)
        do {
            let (data, response) = try await Self.manualUploadSession.data(for: request)
            try validate(response, data: data)
            return try JSONDecoder().decode(LibraryReply.self, from: data).documents
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    /// Connects a stored library PDF to the asset without copying it.
    /// - Returns: The manual version to extract, when the server reports one.
    func connectDashboardLibraryPDF(
        _ pdf: DashboardLibraryPDF,
        assetID: UUID,
        manualLibraryBaseURL: String
    ) async throws -> UUID? {
        struct ConnectReply: Decodable {
            let versionID: String?
            enum CodingKeys: String, CodingKey { case versionID = "version_id" }
        }
        let url = try Self.manualLibraryURL(
            manualLibraryBaseURL,
            path: "/pm/manual-library/api/assets/\(assetID.uuidString.lowercased())/manuals/link"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["relative_path": pdf.relativePath])
        do {
            let (data, response) = try await Self.manualUploadSession.data(for: request)
            try validate(response, data: data)
            return try JSONDecoder().decode(ConnectReply.self, from: data).versionID.flatMap(UUID.init(uuidString:))
        } catch let error as PropertyAPIError {
            throw error
        } catch let error as DecodingError {
            throw PropertyAPIError.decoding(error)
        } catch {
            throw PropertyAPIError.transport(error)
        }
    }

    static func manualLibraryURL(_ base: String, path: String) throws -> URL {
        let trimmed = base
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw PropertyAPIError.serverMessage("Set the Dashboard Manual Library URL in the connection panel first.")
        }
        guard let url = URL(string: trimmed + path) else { throw PropertyAPIError.invalidURL }
        return url
    }
}
