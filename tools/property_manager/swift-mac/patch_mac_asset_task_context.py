#!/usr/bin/env python3
"""Add persistent asset-scoped task filtering to the macOS PropertyManager app."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Development/PropertyManagerApp")
SOURCES = ROOT / "Sources/PropertyManagerApp"
TESTS = ROOT / "Tests/PropertyManagerAppTests"
MAIN = SOURCES / "PropertyManagerApp.swift"
ASSETS = SOURCES / "AssetViews.swift"
HELPER = SOURCES / "TaskAssetContext.swift"
HELPER_TEST = TESTS / "TaskAssetContextTests.swift"

HELPER_SOURCE = """import Foundation

enum TaskAssetContext {
    static func includes(taskAssetId: UUID?, selectedAssetId: UUID?) -> Bool {
        guard let selectedAssetId else { return true }
        return taskAssetId == selectedAssetId
    }
}
"""

TEST_SOURCE = """import XCTest
@testable import PropertyManagerApp

final class TaskAssetContextTests: XCTestCase {
    func testNoSelectionIncludesEveryTask() {
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: UUID(), selectedAssetId: nil))
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: nil, selectedAssetId: nil))
    }

    func testSelectionIncludesOnlyMatchingAssetTasks() {
        let selected = UUID()
        XCTAssertTrue(TaskAssetContext.includes(taskAssetId: selected, selectedAssetId: selected))
        XCTAssertFalse(TaskAssetContext.includes(taskAssetId: UUID(), selectedAssetId: selected))
        XCTAssertFalse(TaskAssetContext.includes(taskAssetId: nil, selectedAssetId: selected))
    }
}
"""


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        print(f"already patched: {label}")
        return text
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    print(f"patched: {label}")
    return text.replace(old, new, 1)


def main() -> None:
    if not MAIN.is_file() or not ASSETS.is_file():
        raise SystemExit(f"missing macOS PropertyManager source under {SOURCES}")

    main_text = MAIN.read_text(encoding="utf-8")
    main_text = replace_once(
        main_text,
        "    @Published var assetLoadError: String?\n",
        "    @Published var assetLoadError: String?\n    @Published var selectedTaskAssetId: UUID?\n",
        "shared selected asset state",
    )
    main_text = replace_once(
        main_text,
        """    var filteredTasks: [MaintenanceTask] {
        var result = store.tasks
""",
        """    var filteredTasks: [MaintenanceTask] {
        var result = store.tasks

        if let selectedTaskAssetId = store.selectedTaskAssetId {
            result = result.filter {
                TaskAssetContext.includes(
                    taskAssetId: $0.assetId,
                    selectedAssetId: selectedTaskAssetId
                )
            }
        }
""",
        "task asset filter",
    )
    main_text = replace_once(
        main_text,
        """                VStack(spacing: 0) {
                    TaskListHeaderView(
""",
        """                VStack(spacing: 0) {
                    if let selectedAssetId = store.selectedTaskAssetId,
                       let asset = store.assets.first(where: { $0.id == selectedAssetId }) {
                        HStack {
                            Label("Tasks for \\(asset.name)", systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(.headline)
                            Spacer()
                            Button("All Assets") {
                                store.selectedTaskAssetId = nil
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.12))

                        Divider()
                    }
                    TaskListHeaderView(
""",
        "task context banner",
    )
    MAIN.write_text(main_text, encoding="utf-8")

    asset_text = ASSETS.read_text(encoding="utf-8")
    asset_text = asset_text.replace("    @State private var selectedAssetId: UUID?\n", "")
    asset_text = asset_text.replace("List(selection: $selectedAssetId)", "List(selection: $store.selectedTaskAssetId)")
    asset_text = asset_text.replace("$0.id == selectedAssetId", "$0.id == store.selectedTaskAssetId")
    asset_text = asset_text.replace("selectedAssetId = nil", "store.selectedTaskAssetId = nil")
    asset_text = asset_text.replace("selectedAssetId = created.id", "store.selectedTaskAssetId = created.id")
    ASSETS.write_text(asset_text, encoding="utf-8")

    TESTS.mkdir(parents=True, exist_ok=True)
    HELPER.write_text(HELPER_SOURCE, encoding="utf-8")
    HELPER_TEST.write_text(TEST_SOURCE, encoding="utf-8")
    print(f"wrote {MAIN}, {ASSETS}, {HELPER}, and {HELPER_TEST}")


if __name__ == "__main__":
    main()
