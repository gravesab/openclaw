import Foundation

/// Every typed word must appear somewhere in the task, in any order.
enum TaskSearch {
    static func words(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func matches(fields: [String], words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = fields.joined(separator: " ")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    static func assetFields(_ asset: RanchAsset) -> [String] {
        [asset.name, asset.externalId, asset.manufacturer ?? "", asset.model ?? "", asset.category ?? "",
         asset.location ?? ""] + (asset.aliases ?? [])
    }

    /// An asset matches when every word appears in the asset itself, or in the asset
    /// together with one of its tasks, so "chipper knife" finds the DR Chipper knife task.
    static func assetMatches(
        assets: [RanchAsset],
        tasks: [MaintenanceTask],
        words: [String],
        taskFields: (MaintenanceTask) -> [String],
        taskTitle: (MaintenanceTask) -> String
    ) -> [AssetSearchMatch] {
        let sorted = assets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !words.isEmpty else {
            return sorted.map { AssetSearchMatch(asset: $0, matchingTaskTitles: []) }
        }
        var tasksByAsset: [UUID: [MaintenanceTask]] = [:]
        for task in tasks {
            if let assetID = task.assetId { tasksByAsset[assetID, default: []].append(task) }
        }
        return sorted.compactMap { asset in
            let own = assetFields(asset)
            let titles = (tasksByAsset[asset.id] ?? [])
                .filter { matches(fields: own + taskFields($0), words: words) }
                .map(taskTitle)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if titles.isEmpty && !matches(fields: own, words: words) { return nil }
            return AssetSearchMatch(asset: asset, matchingTaskTitles: titles)
        }
    }
}

struct AssetSearchMatch: Identifiable {
    let asset: RanchAsset
    let matchingTaskTitles: [String]
    var id: UUID { asset.id }
}
