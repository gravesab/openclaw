#!/usr/bin/env python3
"""Patch M4 iOS TaskDetailView + NavigationLink wiring after sync."""
from pathlib import Path

ios = Path.home() / "ai/projects/openclaw/apps/propertymanager-ios/Sources"
assert (ios / "TaskTitleHelpers.swift").exists(), "missing TaskTitleHelpers"
print("helpers ok")

detail = ios / "TaskDetailView.swift"
d = detail.read_text()
orig = d
if "TaskTitle.estimatedTimeLabel" not in d:
    d = d.replace(
        """                        if let minutes = task.estimatedMinutes {
                            LabeledContent("Estimate", value: "\\(minutes) min")
                        }""",
        """                        if let eta = TaskTitle.estimatedTimeLabel(minutes: task.estimatedMinutes) {
                            Text(eta)
                        }""",
    )
if 'LabeledContent("Item", value: task.item)' in d:
    d = d.replace(
        'LabeledContent("Item", value: task.item)',
        """LabeledContent("Item", value: {
                            let group = TaskTitle.displayAssetName(task: task, assets: store.assets)
                            return TaskTitle.displayItemTitle(item: task.item, group: group)
                        }())""",
    )
if ".navigationTitle(task.item)" in d:
    d = d.replace(
        ".navigationTitle(task.item)",
        """.navigationTitle({
                    let group = TaskTitle.displayAssetName(task: task, assets: store.assets)
                    return TaskTitle.displayItemTitle(item: task.item, group: group)
                }())""",
    )
if d != orig:
    detail.write_text(d)
    print("patched TaskDetailView")
else:
    print("TaskDetailView unchanged")

tl_path = ios / "TaskListView.swift"
t = tl_path.read_text()
if "navigationDestination" not in t and detail.exists():
    t = t.replace(
        """.navigationTitle("Tasks")""",
        """.navigationDestination(for: UUID.self) { taskID in
            TaskDetailView(taskID: taskID)
        }
        .navigationTitle("Tasks")""",
    )
    old = """                    ForEach(section.tasks) { task in
                        TaskRowView(
                            task: task,
                            groupName: section.name
                        ) {
                            completingTask = task"""
    new = """                    ForEach(section.tasks) { task in
                        NavigationLink(value: task.id) {
                            TaskRowView(
                                task: task,
                                groupName: section.name
                            ) {
                                completingTask = task"""
    if old in t:
        t = t.replace(old, new, 1)
        marker = """                            if task.requiresMeterOnComplete, let assetId = task.assetId {
                                Task { await loadAssetForCompletion(assetId) }
                            }
                        }
                    }
                }
            }
        }"""
        repl = """                            if task.requiresMeterOnComplete, let assetId = task.assetId {
                                Task { await loadAssetForCompletion(assetId) }
                            }
                        }
                        }
                    }
                }
            }
        }"""
        if marker in t:
            t = t.replace(marker, repl, 1)
            print("wired NavigationLink")
        else:
            print("WARN: NavigationLink close marker missing")
    tl_path.write_text(t)

print("nav", "navigationDestination" in tl_path.read_text())
print("title helpers in list", "TaskTitle" in tl_path.read_text())
