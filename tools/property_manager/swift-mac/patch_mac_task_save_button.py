#!/usr/bin/env python3
"""Add an explicit Save button to Mac PropertyManagerApp TaskEditorView.

Save upserts the selected task via the existing upsertTaskToServer path.
Complete stays a separate green action that calls completeSelectedTask.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Development/PropertyManagerApp")
SWIFT = ROOT / "Sources/PropertyManagerApp/PropertyManagerApp.swift"


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        if new in text or ("saveSelectedTask" in text and label.startswith("skip-ok")):
            print(f"skip (already): {label}")
            return text
        raise SystemExit(f"anchor not found: {label}")
    print(f"patched: {label}")
    return text.replace(old, new, 1)


def main() -> None:
    if not SWIFT.is_file():
        raise SystemExit(f"missing {SWIFT}")
    text = SWIFT.read_text(encoding="utf-8")

    if "func saveSelectedTask()" in text and 'Label("Save"' in text:
        print("already patched")
        return

    text = must_replace(
        text,
        """    func scheduleAutosave(_ task: MaintenanceTask) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await upsertTaskToServer(task)
        }
    }
""",
        """    func scheduleAutosave(_ task: MaintenanceTask) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await upsertTaskToServer(task)
        }
    }

    /// Explicit Save: upsert selected task without completing it.
    @MainActor
    func saveSelectedTask() async {
        guard let selectedTaskID,
              let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            statusMessage = "Select a task to save."
            return
        }
        autosaveTask?.cancel()
        await upsertTaskToServer(tasks[index])
    }
""",
        "saveSelectedTask method",
    )

    text = must_replace(
        text,
        """            TaskEditorView(
                task: $store.tasks[index],
                categories: store.categories,
                assets: store.assets,
                autosaveAction: { task in store.scheduleAutosave(task) },
                completeAction: { Task { await store.completeSelectedTask() } },
""",
        """            TaskEditorView(
                task: $store.tasks[index],
                categories: store.categories,
                assets: store.assets,
                autosaveAction: { task in store.scheduleAutosave(task) },
                saveAction: { Task { await store.saveSelectedTask() } },
                completeAction: { Task { await store.completeSelectedTask() } },
""",
        "wire saveAction",
    )

    text = must_replace(
        text,
        """    let autosaveAction: (MaintenanceTask) -> Void
    let completeAction: () -> Void
""",
        """    let autosaveAction: (MaintenanceTask) -> Void
    let saveAction: () -> Void
    let completeAction: () -> Void
""",
        "TaskEditorView saveAction property",
    )

    text = must_replace(
        text,
        """                Text("Changes save automatically to your shared task list.")
                    .foregroundStyle(.secondary)
""",
        """                Text("Edit fields, then Save to Postgres. Complete marks the job done and advances next due.")
                    .foregroundStyle(.secondary)
""",
        "editor header hint",
    )

    text = must_replace(
        text,
        """            HStack(spacing: 12) {
                Spacer(minLength: 0)

                Button {
                    completeAction()
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .fixedSize()
            }
        }
        .padding(16)
    }
""",
        """            HStack(spacing: 12) {
                Spacer(minLength: 0)

                Button {
                    saveAction()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .fixedSize()
                .help("Upsert this task to Postgres without completing it. Result appears in Action Result.")

                Button {
                    completeAction()
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .fixedSize()
                .help("Mark complete on the server (advances next due). Does not replace Save for field edits.")
            }
        }
        .padding(16)
    }
""",
        "bottomActionBar Save button",
    )

    # Also call save path after Recalculate so next due is not left local-only
    # if the operator forgets autosave debounce — Recalculate still only mutates
    # local draft; Save (or autosave onChange) persists. No change needed here.

    SWIFT.write_text(text, encoding="utf-8")
    print(f"wrote {SWIFT}")


if __name__ == "__main__":
    main()
