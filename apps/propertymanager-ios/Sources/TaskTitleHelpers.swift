import Foundation

enum TaskTitle {
    /// Group key: linked asset name when `assetId` is set, else `area`.
    static func displayAssetName(task: MaintenanceTask, assets: [RanchAsset]) -> String {
        if let assetId = task.assetId,
           let name = assets.first(where: { $0.id == assetId })?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let area = task.area.trimmingCharacters(in: .whitespacesAndNewlines)
        return area.isEmpty ? "House" : area
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
    static func displayFullTitle(task: MaintenanceTask, assets: [RanchAsset]) -> String {
        let group = displayAssetName(task: task, assets: assets)
        return canonicalItem(assetName: group, title: task.item)
    }

    static func estimatedTimeLabel(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        return "Estimated time: \(minutes) minutes"
    }

    /// Matches task detail: abbreviated calendar date, no time.
    static func dueDateLabel(date: Date) -> String {
        "Due: \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct TaskGroupSection: Identifiable {
    var id: String { name }
    let name: String
    let tasks: [MaintenanceTask]
}
