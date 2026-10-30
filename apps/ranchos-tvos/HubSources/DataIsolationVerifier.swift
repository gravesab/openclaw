import Foundation

/// One row of the Ranch save-check card: a label plus whether that
/// domain's data verified as this ranch's own. Identifiable by label so
/// the card can list rows directly.
struct IsolationCheck: Identifiable, Sendable, Equatable {
    let label: String
    var passed: Bool

    var id: String { label }
}

/// Verifies multi-tenancy data isolation right after a Ranch save.
///
/// Storage is JSON on disk: `people.json` next to a `ranches/` directory
/// holding one `<ranch-uuid>.json` file per ranch. Each ranch file carries
/// the four canonical application data names (`people-<uuid>`,
/// `livestock-<uuid>`, `finance-<uuid>`, `property-manager-<uuid>`).
///
/// A row passes when the ranch file exists with matching id and name, the
/// expected data name is present, and no OTHER ranch file contains that
/// data name (no cross-ranch bleed). Nothing here touches the network.
enum DataIsolationVerifier {
    static let applicationNames = ["People", "Livestock", "Finance", "Property Manager"]

    private struct RanchFileProbe: Decodable {
        struct Application: Decodable {
            let name: String
            let dataName: String
        }

        let id: UUID
        let name: String
        let applications: [Application]
    }

    static func verifyIsolation(ranchID: UUID, ranchName: String, peopleFileURL: URL) -> [IsolationCheck] {
        let ranchesURL = peopleFileURL.deletingLastPathComponent()
            .appendingPathComponent("ranches", isDirectory: true)
        let ranchURL = ranchesURL.appendingPathComponent(ranchID.uuidString + ".json")

        func failAll() -> [IsolationCheck] {
            [IsolationCheck(label: "This ranch has its own data.", passed: false)]
                + applicationNames.map { IsolationCheck(label: "\($0) has its own data.", passed: false) }
        }

        guard let data = try? Data(contentsOf: ranchURL),
              let file = try? JSONDecoder().decode(RanchFileProbe.self, from: data),
              file.id == ranchID,
              file.name == ranchName
        else { return failAll() }

        let key = ranchID.uuidString.lowercased()
        let expected = [
            "People": "people-\(key)",
            "Livestock": "livestock-\(key)",
            "Finance": "finance-\(key)",
            "Property Manager": "property-manager-\(key)",
        ]
        let present = Set(file.applications.map(\.dataName))

        // Bleed check: data names appearing in any OTHER ranch file.
        // Compare file names, not full URLs: directory listings can
        // resolve symlinks differently than a constructed URL, which would
        // mistake this ranch's own file for a foreign one.
        var foreign = Set<String>()
        let ownFileName = ranchID.uuidString + ".json"
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: ranchesURL, includingPropertiesForKeys: nil)
        {
            for entry in entries
                where entry.lastPathComponent != ownFileName && entry.pathExtension == "json"
            {
                guard let otherData = try? Data(contentsOf: entry),
                      let other = try? JSONDecoder().decode(RanchFileProbe.self, from: otherData)
                else { continue }
                foreign.formUnion(other.applications.map(\.dataName))
            }
        }

        var checks = [IsolationCheck(label: "This ranch has its own data.", passed: true)]
        for app in applicationNames {
            guard let dataName = expected[app] else { continue }
            let passed = present.contains(dataName) && !foreign.contains(dataName)
            checks.append(IsolationCheck(label: "\(app) has its own data.", passed: passed))
        }
        return checks
    }
}
