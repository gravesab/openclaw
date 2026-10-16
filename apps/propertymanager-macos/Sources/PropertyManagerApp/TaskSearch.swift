import Foundation

/// Task list search: every typed word must appear somewhere in the task, in any field and any order.
enum TaskSearch {
    static func words(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func matches(fields: [String], words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = fields.joined(separator: " ")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    /// Task text searched by the list, matching the iPhone app's fields.
    static func taskFields(for task: MaintenanceTask, assets: [MacRanchAsset]) -> [String] {
        let group = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: assets)
        var fields = [
            task.area,
            task.item,
            group,
            TaskTitle.displayItemTitle(item: task.item, group: group),
            task.category,
            task.priority.rawValue,
            task.notes,
            task.taskDescription,
            task.suppliesNeeded,
            task.origin.label,
            task.manufacturer,
            task.sourceManualName,
        ]
        for part in task.parts {
            fields += [part.name, part.partNumber, part.oemPartNumber, part.vendor]
        }
        return fields
    }

    static func assetFields(_ asset: MacRanchAsset) -> [String] {
        [asset.name, asset.externalId, asset.category ?? ""]
    }

    /// An asset matches when every word appears in the asset itself, or in the
    /// asset together with one of its tasks, so "chipper knife" finds the
    /// chipper's knife task.
    static func assetMatches(
        assets: [MacRanchAsset],
        tasks: [MaintenanceTask],
        words: [String]
    ) -> [MacAssetSearchMatch] {
        guard !words.isEmpty else {
            return assets.map { MacAssetSearchMatch(asset: $0, matchingTaskTitles: []) }
        }
        var tasksByAsset: [UUID: [MaintenanceTask]] = [:]
        for task in tasks {
            if let assetID = task.assetId { tasksByAsset[assetID, default: []].append(task) }
        }
        return assets.compactMap { asset in
            let own = assetFields(asset)
            let titles = (tasksByAsset[asset.id] ?? [])
                .filter { matches(fields: own + taskFields(for: $0, assets: assets), words: words) }
                .map { task in
                    let group = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: assets)
                    return TaskTitle.displayItemTitle(item: task.item, group: group)
                }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if titles.isEmpty && !matches(fields: own, words: words) { return nil }
            return MacAssetSearchMatch(asset: asset, matchingTaskTitles: titles)
        }
    }
}

struct MacAssetSearchMatch: Identifiable {
    let asset: MacRanchAsset
    let matchingTaskTitles: [String]
    var id: UUID { asset.id }
}
