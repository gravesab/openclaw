#!/usr/bin/env python3
"""Patch Mac PropertyManagerApp for sectioned task list + title canonicalize."""
from __future__ import annotations

from pathlib import Path

APP = Path.home() / "Development/PropertyManagerApp/Sources/PropertyManagerApp"
MAIN = APP / "PropertyManagerApp.swift"
MANUAL = APP / "ManualImport.swift"
HELPERS = APP / "TaskTitleHelpers.swift"

HELPER_SRC = r'''import Foundation

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

    static func canonicalItem(assetName: String, title: String) -> String {
        let group = assetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = group.isEmpty ? "House" : group
        var bare = displayItemTitle(item: title, group: groupName)
        if bare.isEmpty {
            bare = "Maintenance item"
        }
        return "\(groupName): \(bare)"
    }
}

struct TaskGroupSection: Identifiable {
    var id: String { name }
    let name: String
    let tasks: [MaintenanceTask]
}
'''


def main() -> None:
    HELPERS.write_text(HELPER_SRC)
    print("wrote", HELPERS)

    text = MAIN.read_text()

    # ContentView.filteredTasks -> keep filter, add groupedTasks
    old_filter = """    var filteredTasks: [MaintenanceTask] {
        var result = store.tasks

        if let selectedOriginFilter {
            result = result.filter { $0.origin == selectedOriginFilter }
        }

        if let selectedCategoryFilter {
            result = result.filter { $0.category == selectedCategoryFilter }
        }

        let cleanSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanSearch.isEmpty {
            result = result.filter {
                $0.area.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.item.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.taskDescription.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.manufacturer.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.sourceManualName.localizedCaseInsensitiveContains(cleanSearch)
            }
        }

        return result.sorted {
            if $0.area.localizedCaseInsensitiveCompare($1.area) != .orderedSame {
                return $0.area.localizedCaseInsensitiveCompare($1.area) == .orderedAscending
            }
            return $0.item.localizedCaseInsensitiveCompare($1.item) == .orderedAscending
        }
    }"""

    new_filter = """    var filteredTasks: [MaintenanceTask] {
        var result = store.tasks

        if let selectedOriginFilter {
            result = result.filter { $0.origin == selectedOriginFilter }
        }

        if let selectedCategoryFilter {
            result = result.filter { $0.category == selectedCategoryFilter }
        }

        let cleanSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanSearch.isEmpty {
            result = result.filter {
                let group = TaskTitle.displayAssetName(area: $0.area, assetId: $0.assetId, assets: store.assets)
                let display = TaskTitle.displayItemTitle(item: $0.item, group: group)
                return $0.area.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.item.localizedCaseInsensitiveContains(cleanSearch) ||
                group.localizedCaseInsensitiveContains(cleanSearch) ||
                display.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.taskDescription.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.manufacturer.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.sourceManualName.localizedCaseInsensitiveContains(cleanSearch)
            }
        }

        return result
    }

    var groupedTasks: [TaskGroupSection] {
        var buckets: [String: [MaintenanceTask]] = [:]
        for task in filteredTasks {
            let key = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: store.assets)
            buckets[key, default: []].append(task)
        }
        return buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                let tasks = (buckets[name] ?? []).sorted {
                    let l = TaskTitle.displayItemTitle(item: $0.item, group: name)
                    let r = TaskTitle.displayItemTitle(item: $1.item, group: name)
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }
                return TaskGroupSection(name: name, tasks: tasks)
            }
    }"""

    if old_filter not in text:
        raise SystemExit("filteredTasks block not found")
    text = text.replace(old_filter, new_filter, 1)
    print("patched filteredTasks/groupedTasks")

    old_list = """                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredTasks) { task in
                            TaskRowView(
                                task: task,
                                isSelected: task.id == store.selectedTaskID
                            )
                            .onTapGesture {
                                store.selectedTaskID = task.id
                            }
                        }
                    }
                    .padding()
                }"""

    new_list = """                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groupedTasks) { section in
                            Text(section.name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(section.tasks) { task in
                                TaskRowView(
                                    task: task,
                                    groupName: section.name,
                                    isSelected: task.id == store.selectedTaskID
                                )
                                .onTapGesture {
                                    store.selectedTaskID = task.id
                                }
                            }
                        }
                    }
                    .padding()
                }"""

    if old_list not in text:
        raise SystemExit("task list ForEach block not found")
    text = text.replace(old_list, new_list, 1)
    print("patched sectioned list")

    old_row = """struct TaskRowView: View {
    let task: MaintenanceTask
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: CategoryStyle.icon(for: task.category))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(CategoryStyle.color(for: task.category).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.area)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(CategoryStyle.color(for: task.category))

                HStack(spacing: 6) {
                    if task.kind == .workRequest {
                        Text("Work Request")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }

                    if !task.photoFileNames.isEmpty {
                        Image(systemName: "camera.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(task.item)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                }"""

    new_row = """struct TaskRowView: View {
    let task: MaintenanceTask
    let groupName: String
    let isSelected: Bool

    var body: some View {
        let displayTitle = TaskTitle.displayItemTitle(item: task.item, group: groupName)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: CategoryStyle.icon(for: task.category))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(CategoryStyle.color(for: task.category).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if task.kind == .workRequest {
                        Text("Work Request")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }

                    if !task.photoFileNames.isEmpty {
                        Image(systemName: "camera.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                }"""

    if old_row not in text:
        raise SystemExit("TaskRowView block not found")
    text = text.replace(old_row, new_row, 1)
    print("patched TaskRowView")

    # Canonicalize on upsert
    old_upsert = """    func upsertTaskToServer(_ task: MaintenanceTask) async {
        statusMessage = "Saving…"
        do {
            let updated = try await apiClient.upsertTask(task)"""
    new_upsert = """    func upsertTaskToServer(_ task: MaintenanceTask) async {
        statusMessage = "Saving…"
        do {
            var normalized = task
            let group = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: assets)
            normalized.area = group
            normalized.item = TaskTitle.canonicalItem(assetName: group, title: task.item)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].area = normalized.area
                tasks[index].item = normalized.item
            }
            let updated = try await apiClient.upsertTask(normalized)"""
    if old_upsert not in text:
        raise SystemExit("upsertTaskToServer anchor not found")
    text = text.replace(old_upsert, new_upsert, 1)
    print("patched upsert canonicalize")

    # addTask default titles
    old_add = """        let item = isWorkRequest ? "Describe the repair needed" : "Describe the work"
        let warning = isWorkRequest ? 1 : 30
        let critical = isWorkRequest ? 3 : 45
        let task = MaintenanceTask(
            area: area,
            item: item,"""
    new_add = """        let bareItem = isWorkRequest ? "Describe the repair needed" : "Describe the work"
        let item = TaskTitle.canonicalItem(assetName: area, title: bareItem)
        let warning = isWorkRequest ? 1 : 30
        let critical = isWorkRequest ? 3 : 45
        let task = MaintenanceTask(
            area: area,
            item: item,"""
    if old_add not in text:
        raise SystemExit("addTask item anchor not found")
    text = text.replace(old_add, new_add, 1)
    print("patched addTask")

    MAIN.write_text(text)

    # ManualImport: use canonicalItem after subsystem prefix logic
    m = MANUAL.read_text()
    old_mi = """            if let subsystem, subsystem.caseInsensitiveCompare(equipmentName) != .orderedSame,
               !item.localizedCaseInsensitiveContains(subsystem) {
                item = "\\(subsystem): \\(item)"
            }"""
    new_mi = """            if let subsystem, subsystem.caseInsensitiveCompare(equipmentName) != .orderedSame,
               !item.localizedCaseInsensitiveContains(subsystem) {
                item = "\\(subsystem): \\(item)"
            }
            item = TaskTitle.canonicalItem(assetName: area, title: item)"""
    count = m.count(old_mi)
    if count == 0:
        raise SystemExit("ManualImport prefix block not found")
    m = m.replace(old_mi, new_mi)
    MANUAL.write_text(m)
    print(f"patched ManualImport x{count}")
    print("done")


if __name__ == "__main__":
    main()
