#!/usr/bin/env python3
"""Remove duplicate anchors left by re-running apply_mac_meter_patch.py and fix makeURL."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Development/PropertyManagerApp")
APP = ROOT / "Sources/PropertyManagerApp"
API = APP / "PropertyAPIClient.swift"
MAIN = APP / "PropertyManagerApp.swift"
MANUAL = APP / "ManualImport.swift"


def main() -> None:
    api_text = API.read_text(encoding="utf-8")
    old_make = (
        '    func makeURL(_ path: String, versioned: Bool = false) throws -> URL {\n'
        '        let prefix = versioned ? "/v1" : ""\n'
        '        let normalized = path.hasPrefix("/") ? path : "/\\(path)"\n'
        "        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)\n"
        '            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))\n'
        "        guard let base = URL(string: trimmed) else {\n"
        "            throw PropertyAPIError.invalidURL\n"
        "        }\n"
        '        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\n'
        "    }"
    )
    new_make = (
        '    func makeURL(_ path: String, versioned: Bool = false) throws -> URL {\n'
        "        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)\n"
        '            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))\n'
        '        let prefix = versioned ? "/v1" : ""\n'
        '        let normalized = path.hasPrefix("/") ? path : "/\\(path)"\n'
        "        guard let url = URL(string: trimmed + prefix + normalized) else {\n"
        "            throw PropertyAPIError.invalidURL\n"
        "        }\n"
        "        return url\n"
        "    }"
    )
    if old_make not in api_text:
        if "trimmed + prefix + normalized" in api_text:
            print("skip: makeURL already string-concat")
        else:
            raise SystemExit("makeURL block not found as expected")
    else:
        api_text = api_text.replace(old_make, new_make, 1)
        print("fixed: makeURL")

    dup_sched = (
        '            "schedule_kind": task.scheduleKind,\n'
        '            "meter_interval_value": task.meterIntervalValue as Any,\n'
        '            "meter_interval_unit": task.meterIntervalUnit as Any,\n'
        '            "asset_id": task.assetId?.uuidString as Any,\n'
        '            "schedule_kind": task.scheduleKind,\n'
        '            "meter_interval_value": task.meterIntervalValue as Any,\n'
        '            "meter_interval_unit": task.meterIntervalUnit as Any,\n'
        '            "asset_id": task.assetId?.uuidString as Any,\n'
    )
    single_sched = (
        '            "schedule_kind": task.scheduleKind,\n'
        '            "meter_interval_value": task.meterIntervalValue as Any,\n'
        '            "meter_interval_unit": task.meterIntervalUnit as Any,\n'
        '            "asset_id": task.assetId?.uuidString as Any,\n'
    )
    if dup_sched in api_text:
        api_text = api_text.replace(dup_sched, single_sched, 1)
        print("deduped: schedule_kind payload")
    else:
        print("skip: schedule_kind already unique")
    API.write_text(api_text, encoding="utf-8")

    main_text = MAIN.read_text(encoding="utf-8")
    # Prefer curly apostrophe (what the app uses); also try ASCII.
    for apo in ("\u2019", "'"):
        dup_refresh = (
            "    @MainActor\n"
            "    func refreshAssets() async {\n"
            "        do {\n"
            "            assets = try await apiClient.fetchAssets()\n"
            "        } catch {\n"
            f'            statusMessage = "Couldn{apo}t load assets: \\(error.localizedDescription)"\n'
            "        }\n"
            "    }\n"
            "\n"
            "    func refreshAssets() async {\n"
            "        do {\n"
            "            assets = try await apiClient.fetchAssets()\n"
            "        } catch {\n"
            f'            statusMessage = "Couldn{apo}t load assets: \\(error.localizedDescription)"\n'
            "        }\n"
            "    }\n"
        )
        single_refresh = (
            "    @MainActor\n"
            "    func refreshAssets() async {\n"
            "        do {\n"
            "            assets = try await apiClient.fetchAssets()\n"
            "        } catch {\n"
            f'            statusMessage = "Couldn{apo}t load assets: \\(error.localizedDescription)"\n'
            "        }\n"
            "    }\n"
        )
        if dup_refresh in main_text:
            main_text = main_text.replace(dup_refresh, single_refresh, 1)
            print(f"deduped: refreshAssets (apo={apo!r})")
            break
    else:
        count = main_text.count("func refreshAssets")
        print(f"skip/warn: refreshAssets count={count}")

    dup_panel = (
        "            Group {\n"
        "            if store.showAssetsPanel {\n"
        "                MacAssetsPanel(store: store)\n"
        "            } else {\n"
        "            Group {\n"
        "            if store.showAssetsPanel {\n"
        "                MacAssetsPanel(store: store)\n"
        "            } else {\n"
        "            VStack(spacing: 0) {\n"
    )
    single_panel = (
        "            Group {\n"
        "            if store.showAssetsPanel {\n"
        "                MacAssetsPanel(store: store)\n"
        "            } else {\n"
        "            VStack(spacing: 0) {\n"
    )
    if dup_panel in main_text:
        main_text = main_text.replace(dup_panel, single_panel, 1)
        print("deduped: showAssetsPanel branch")
    else:
        print(f"skip/warn: showAssetsPanel count={main_text.count('if store.showAssetsPanel')}")
    MAIN.write_text(main_text, encoding="utf-8")

    man_text = MANUAL.read_text(encoding="utf-8")
    dup_sk = (
        '        let scheduleKind = parsedValue != nil ? "meter" : "calendar"\n'
        '        let scheduleKind = meterIntervalValue != nil ? "meter" : "calendar"\n'
    )
    single_sk = '        let scheduleKind = parsedValue != nil ? "meter" : "calendar"\n'
    if dup_sk in man_text:
        man_text = man_text.replace(dup_sk, single_sk, 1)
        print("deduped: scheduleKind")
    else:
        print("skip: scheduleKind already unique")

    dup_schema = (
        '                "meterIntervalValue": ["type": "number"],\n'
        '                "meterIntervalUnit": ["type": "string"],\n'
        '                "meterIntervalValue": ["type": "number"],\n'
        '                "meterIntervalUnit": ["type": "string"],\n'
    )
    single_schema = (
        '                "meterIntervalValue": ["type": "number"],\n'
        '                "meterIntervalUnit": ["type": "string"],\n'
    )
    if dup_schema in man_text:
        man_text = man_text.replace(dup_schema, single_schema, 1)
        print("deduped: LLM schema meter fields")
    else:
        print("skip: schema already unique")
    MANUAL.write_text(man_text, encoding="utf-8")
    print("cleanup done")


if __name__ == "__main__":
    main()
