#!/usr/bin/env python3
"""Apply origin badge/filter patches to M4 iOS PropertyManager sources."""
from __future__ import annotations

from pathlib import Path

ROOT = Path.home() / "ai/projects/openclaw/apps/propertymanager-ios"


def patch_models() -> None:
    path = ROOT / "Sources/Models.swift"
    text = path.read_text()
    if "enum OriginFilter" in text:
        print("Models.swift: OriginFilter already present")
        return
    needle = """enum TaskOrigin: String, Codable, Hashable, CaseIterable, Identifiable {
    case manufacturer
    case owner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manufacturer:
            return "Manufacturer"
        case .owner:
            return "Owner-added"
        }
    }
}"""
    insert = (
        needle
        + """

enum OriginFilter: String, CaseIterable, Identifiable {
    case all = "All Origins"
    case manufacturer = "Manufacturer"
    case owner = "Owner-added"

    var id: String { rawValue }

    var matches: TaskOrigin? {
        switch self {
        case .all: return nil
        case .manufacturer: return .manufacturer
        case .owner: return .owner
        }
    }
}"""
    )
    if needle not in text:
        raise SystemExit("TaskOrigin block not found in Models.swift")
    path.write_text(text.replace(needle, insert, 1))
    print("Models.swift: added OriginFilter")


def patch_store() -> None:
    path = ROOT / "Sources/PropertyStore.swift"
    st = path.read_text()
    if "originFilter" not in st:
        st = st.replace(
            '@Published var filter: TaskFilter = .all\n    @Published var selectedCategory: String = "All"',
            '@Published var filter: TaskFilter = .all\n    @Published var originFilter: OriginFilter = .all\n    @Published var selectedCategory: String = "All"',
            1,
        )
        old = """                if selectedCategory != "All", task.categoryName != selectedCategory {
                    return false
                }
                switch filter {"""
        new = """                if selectedCategory != "All", task.categoryName != selectedCategory {
                    return false
                }
                if let wanted = originFilter.matches, task.origin != wanted {
                    return false
                }
                switch filter {"""
        if old not in st:
            raise SystemExit("filteredTasks origin insert point missing")
        st = st.replace(old, new, 1)
    if "task.origin.label" not in st:
        for old, new in (
            (
                """                        task.suppliesNeeded ?? "",
                        task.primaryPartNumber ?? "",
                    ].joined(separator: " ").lowercased()""",
                """                        task.suppliesNeeded ?? "",
                        task.primaryPartNumber ?? "",
                        task.origin.label,
                        task.manufacturer ?? "",
                        task.sourceManualName ?? "",
                    ].joined(separator: " ").lowercased()""",
            ),
            (
                """                        task.suppliesNeeded ?? "",
                    ].joined(separator: " ").lowercased()""",
                """                        task.suppliesNeeded ?? "",
                        task.origin.label,
                        task.manufacturer ?? "",
                        task.sourceManualName ?? "",
                    ].joined(separator: " ").lowercased()""",
            ),
        ):
            if old in st:
                st = st.replace(old, new, 1)
                break
    path.write_text(st)
    print("PropertyStore.swift patched")


def patch_detail() -> None:
    path = ROOT / "Sources/TaskDetailView.swift"
    dt = path.read_text()
    old_origin = 'LabeledContent("Origin", value: task.origin.label)'
    new_origin = """HStack {
                            Text("Origin")
                            Spacer()
                            TaskOriginBadge(origin: task.origin)
                        }"""
    if old_origin in dt:
        path.write_text(dt.replace(old_origin, new_origin, 1))
        print("TaskDetailView.swift: badge")
    else:
        print("TaskDetailView.swift: origin line already changed or missing")


def patch_edit() -> None:
    path = ROOT / "Sources/TaskEditView.swift"
    et = path.read_text()
    if 'Section("Origin")' in et:
        print("TaskEditView.swift: Origin section present")
        return
    insert = """            Form {
                Section("Origin") {
                    TaskOriginBadge(origin: task.origin)
                    if let manufacturer = task.manufacturer, !manufacturer.isEmpty {
                        LabeledContent("Manufacturer", value: manufacturer)
                    }
                    if let manual = task.sourceManualName, !manual.isEmpty {
                        LabeledContent("Source manual", value: manual)
                    }
                }

                Section {"""
    anchor = "            Form {\n                Section {"
    if anchor not in et:
        raise SystemExit("TaskEditView Form anchor missing")
    path.write_text(et.replace(anchor, insert, 1))
    print("TaskEditView.swift: origin section")


def bump_version() -> None:
    path = ROOT / "project.yml"
    yt = path.read_text()
    yt2 = yt.replace('MARKETING_VERSION: "0.2.0"', 'MARKETING_VERSION: "0.2.1"').replace(
        'CURRENT_PROJECT_VERSION: "2"', 'CURRENT_PROJECT_VERSION: "3"'
    )
    if yt2 != yt:
        path.write_text(yt2)
        print("project.yml bumped to 0.2.1/3")
    else:
        print("project.yml version already bumped or different")


def verify_list() -> None:
    tl = (ROOT / "Sources/TaskListView.swift").read_text()
    print("TaskListView has TaskOriginBadge:", "TaskOriginBadge" in tl)
    print("TaskListView has originFilter picker:", "originFilter" in tl)


def main() -> None:
    patch_models()
    patch_store()
    patch_detail()
    patch_edit()
    bump_version()
    verify_list()


if __name__ == "__main__":
    main()
