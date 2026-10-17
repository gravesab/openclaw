import Foundation

/// Exact strings for the Finance DEV import-result view. Single source of truth.
enum FinanceImportResultStrings {
    static let schema = "ranch-finance-import-result/v1"
    static let banner = "DEV · Finance import result · read only"
    static let syntheticMarker = "synthetic sample"
    static let emptySentence = "Synthetic sample only — a real exporter is a later spec"
}

/// Synthetic Apple Card import result. Untrusted input: decode, then gate on schema.
struct FinanceImportResult: Decodable, Sendable {
    struct Artifact: Decodable, Sendable {
        let fileName: String
        let sha256: String
        let rowCount: Int

        private enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case sha256
            case rowCount = "row_count"
        }
    }

    struct ImportError: Decodable, Sendable {
        let row: Int
        let code: String
        let message: String
    }

    let schema: String
    let producedAt: String
    let producedBy: String
    let tenantLabel: String
    let artifact: Artifact
    let errors: [ImportError]

    private enum CodingKeys: String, CodingKey {
        case schema
        case producedAt = "produced_at"
        case producedBy = "produced_by"
        case tenantLabel = "tenant_label"
        case artifact
        case errors
    }
}

enum FinanceImportResultLoadError: Error, Sendable {
    case unreadable
    case invalidJSON
    case unknownSchema(String)
}

enum FinanceImportResultLoader {
    static func load(from url: URL) throws -> FinanceImportResult {
        guard url.startAccessingSecurityScopedResource() else {
            throw FinanceImportResultLoadError.unreadable
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FinanceImportResultLoadError.unreadable
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> FinanceImportResult {
        let decoded: FinanceImportResult
        do {
            decoded = try JSONDecoder().decode(FinanceImportResult.self, from: data)
        } catch {
            throw FinanceImportResultLoadError.invalidJSON
        }
        guard decoded.schema == FinanceImportResultStrings.schema else {
            throw FinanceImportResultLoadError.unknownSchema(decoded.schema)
        }
        guard decoded.artifact.rowCount >= 0,
              !decoded.artifact.fileName.isEmpty,
              !decoded.artifact.sha256.isEmpty
        else {
            throw FinanceImportResultLoadError.invalidJSON
        }
        return decoded
    }
}
