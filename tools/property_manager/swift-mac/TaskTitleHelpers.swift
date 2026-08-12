import Foundation

enum TaskTitle {
    static func displayAssetName(area: String, assetId: UUID?, assets: [MacRanchAsset]) -> String {
        if let assetId,
           let name = assets.first(where: { $0.id == assetId })?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let trimmed = area.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "House" : trimmed
    }

    /// Strip leading `{group}:` prefixes (case-insensitive), collapsing repeats.
    static func displayItemTitle(item: String, group: String) -> String {
        var title = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupName.isEmpty, !title.isEmpty else { return title }
        let prefix = "\(groupName):"
        while title.lowercased().hasPrefix(prefix.lowercased()) {
            title = String(title.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
        }
        return title
    }

    /// Build `Group: Title` without duplicating an existing `{group}:` / `{area}:` prefix.
    static func canonicalItem(assetName: String, title: String) -> String {
        let group = assetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = group.isEmpty ? "House" : group
        var bare = displayItemTitle(item: title, group: groupName)
        if bare.isEmpty {
            bare = "Maintenance item"
        }
        return "\(groupName): \(bare)"
    }

    /// Full display title using linked asset name when available.
    static func displayFullTitle(area: String, item: String, assetId: UUID?, assets: [MacRanchAsset]) -> String {
        let group = displayAssetName(area: area, assetId: assetId, assets: assets)
        return canonicalItem(assetName: group, title: item)
    }
}

struct TaskGroupSection: Identifiable {
    var id: String { name }
    let name: String
    let tasks: [MaintenanceTask]
}
