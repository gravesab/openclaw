#!/usr/bin/env python3
"""Patch Mac PropertyManagerApp Recalculate Next Due to use Frequency.

Root cause: the Schedule editor button set nextDue = lastDone + warningDays.
warningDays / criticalDays are OpenClaw due-soon / critical thresholds, not the
repeat interval. Frequency (Daily…Yearly) is the schedule interval.

Formula (local draft until Save to Postgres):
  nextDue = lastDone + frequency interval
    Daily +1d, Weekly +7d, Every 2 Weeks +14d,
    Monthly +1mo, Quarterly +3mo, Yearly +1y

API note (unchanged by this patch):
  POST /tasks/<id>/complete still advances calendar next_due by warning_days
  (see propertymanager_api.complete_task). Do not change prod API without an
  explicit migration plan; Mac Recalculate is operator-local until Save.

Usage:
  python3 patch_mac_recalculate_next_due.py [~/Development/PropertyManagerApp]
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Development/PropertyManagerApp")
SWIFT = ROOT / "Sources/PropertyManagerApp/PropertyManagerApp.swift"

OLD_ENUM = """enum TaskFrequency: String, CaseIterable, Codable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Every 2 Weeks"
    case monthly = "Monthly"
    case quarterly = "Quarterly"
    case yearly = "Yearly"

    var id: String { rawValue }
}"""

NEW_ENUM = """enum TaskFrequency: String, CaseIterable, Codable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Every 2 Weeks"
    case monthly = "Monthly"
    case quarterly = "Quarterly"
    case yearly = "Yearly"

    var id: String { rawValue }

    /// Next calendar due after `lastDone` for this frequency.
    /// Warning/critical days are separate OpenClaw thresholds, not the interval.
    func nextDue(after lastDone: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: lastDone) ?? lastDone
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: lastDone) ?? lastDone
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14, to: lastDone) ?? lastDone
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: lastDone) ?? lastDone
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3, to: lastDone) ?? lastDone
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: lastDone) ?? lastDone
        }
    }
}"""

OLD_BTN = """                    Button("Recalculate Next Due") {
                        task.nextDue = Calendar.current.date(byAdding: .day, value: task.warningDays, to: task.lastDone) ?? task.lastDone
                    }
                    .fixedSize()
                    .help("Set Next Due to Last Done plus Warning Days")"""

NEW_BTN = """                    Button("Recalculate Next Due") {
                        task.nextDue = task.frequency.nextDue(after: task.lastDone)
                    }
                    .fixedSize()
                    .help("Set Next Due to Last Done plus Frequency interval")"""


def main() -> None:
    if not SWIFT.is_file():
        raise SystemExit(f"missing {SWIFT}")
    text = SWIFT.read_text(encoding="utf-8")
    changed = False

    if "func nextDue(after lastDone" not in text:
        if OLD_ENUM not in text:
            raise SystemExit("TaskFrequency enum block not found")
        text = text.replace(OLD_ENUM, NEW_ENUM, 1)
        changed = True
        print("patched: TaskFrequency.nextDue(after:)")
    else:
        print("skip (already): TaskFrequency.nextDue(after:)")

    if OLD_BTN in text:
        text = text.replace(OLD_BTN, NEW_BTN)
        changed = True
        print("patched: Recalculate Next Due button")
    elif "task.frequency.nextDue(after: task.lastDone)" in text:
        print("skip (already): Recalculate Next Due button")
    else:
        raise SystemExit("Recalculate Next Due button block not found")

    if changed:
        SWIFT.write_text(text, encoding="utf-8")
        print(f"wrote {SWIFT}")
    else:
        print("no changes needed")


if __name__ == "__main__":
    main()
