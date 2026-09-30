#!/usr/bin/env python3
"""Score work-request draft outputs offline.

This runner does not contact a model, change routing, or submit a request.
Without a results file it reports every case as untested.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def cases(document: dict[str, Any]) -> list[dict[str, Any]]:
    rows = document.get("cases")
    if not isinstance(rows, list) or not rows:
        raise ValueError("cases must be a non-empty list")
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise ValueError("every case needs a string id")
        if row["id"] in seen:
            raise ValueError(f"duplicate case id: {row['id']}")
        seen.add(row["id"])
        if not isinstance(row.get("report"), str) or not row["report"].strip():
            raise ValueError(f"{row['id']} needs a report")
        if not isinstance(row.get("expect"), dict):
            raise ValueError(f"{row['id']} needs an expect object")
    return rows


def score_case(case: dict[str, Any], output: dict[str, Any]) -> dict[str, Any]:
    expect = case["expect"]
    report = case["report"]
    failures: list[str] = []
    populated = 0
    correct = 0

    area = output.get("areaText")
    if isinstance(area, str) and area.strip():
        populated += 1
        excerpt = expect.get("area_excerpt")
        if isinstance(excerpt, str) and excerpt.casefold() in area.casefold() and excerpt.casefold() in report.casefold():
            correct += 1
        elif excerpt is not None or expect.get("area_required") is True:
            failures.append("area is not grounded in the report")

    for name in expect.get("absent_material_names", []):
        for material in output.get("materials", []):
            if isinstance(material, dict) and name.casefold() in str(material.get("name", "")).casefold():
                failures.append(f"invented or excluded material: {name}")

    expected_materials = expect.get("materials", [])
    actual_materials = output.get("materials", [])
    if not isinstance(actual_materials, list):
        failures.append("materials must be a list")
        actual_materials = []
    for expected in expected_materials:
        populated += 1
        match = next(
            (
                material for material in actual_materials
                if isinstance(material, dict)
                and expected["name_contains"].casefold() in str(material.get("name", "")).casefold()
            ),
            None,
        )
        if match is None:
            failures.append(f"missing material containing {expected['name_contains']}")
            continue
        quantity = match.get("quantityText")
        if expected.get("quantity") is None:
            if quantity not in (None, ""):
                failures.append(f"quantity was invented for {expected['name_contains']}")
            else:
                correct += 1
        elif str(quantity) == str(expected["quantity"]):
            correct += 1
        else:
            failures.append(f"quantity mismatch for {expected['name_contains']}")

    for forbidden in expect.get("forbid_quantities", []):
        for material in actual_materials:
            if isinstance(material, dict) and str(material.get("quantityText")) == str(forbidden):
                failures.append(f"forbidden quantity {forbidden}")

    notes = " ".join(str(note) for note in output.get("reviewNotes", []))
    for needle in expect.get("notes_contain", []):
        populated += 1
        if needle.casefold() in notes.casefold():
            correct += 1
        else:
            failures.append(f"review notes omit {needle}")

    encoded = json.dumps(output)
    if expect.get("must_not_include_uuid") and "assetID" in output:
        failures.append("model output included an asset id")
    if "-" in encoded and expect.get("must_not_include_uuid"):
        for value in _strings(output):
            if len(value) == 36 and value.count("-") == 4:
                failures.append("model output included a UUID")

    return {
        "id": case["id"],
        "split": case.get("split", "unspecified"),
        "passed": not failures,
        "populated": populated,
        "correct": correct,
        "failures": failures,
    }


def _strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [item for child in value.values() for item in _strings(child)]
    if isinstance(value, list):
        return [item for child in value for item in _strings(child)]
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cases",
        type=Path,
        default=Path(__file__).with_name("work_request_drafts.json"),
    )
    parser.add_argument("--results", type=Path)
    args = parser.parse_args()
    document = load_json(args.cases)
    rows = cases(document)
    if args.results is None:
        print(f"Cases checked: {len(rows)}")
        print("Model comparison: untested. Pass --results to score a saved output file.")
        return 0

    saved = load_json(args.results)
    outputs = {row["id"]: row for row in saved.get("cases", []) if isinstance(row, dict)}
    scored = []
    for row in rows:
        output = outputs.get(row["id"])
        if output is None:
            scored.append({"id": row["id"], "split": row.get("split"), "passed": False, "failures": ["untested"]})
        else:
            scored.append(score_case(row, output))
    populated = sum(item.get("populated", 0) for item in scored)
    correct = sum(item.get("correct", 0) for item in scored)
    passed = sum(1 for item in scored if item["passed"])
    print(f"Cases: {len(scored)}")
    print(f"Passed: {passed}")
    print(f"Populated fields correct: {correct}/{populated}")
    for item in scored:
        if not item["passed"]:
            print(f"{item['id']}: {', '.join(item['failures'])}")
    return 0 if passed == len(scored) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"Work-request draft evaluation failed: {exc}", file=sys.stderr)
        raise SystemExit(2)
