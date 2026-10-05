#!/usr/bin/env python3
"""Build a citation-preserving human review queue from answer-key templates.

The queue is review-only. It does not calculate quality scores or communicate
with a database, API, model provider, or Production environment.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


HIGH_KINDS = {"warning", "procedure"}


def priority_for(candidate: dict[str, Any]) -> str:
    flags = set(candidate.get("automated_flags", []))
    kind = candidate.get("source_record", {}).get("kind")
    if "conflicting_values_for_same_kind_and_title" in flags or kind in HIGH_KINDS:
        return "high"
    if kind == "tool" or "duplicate_candidate" in flags:
        return "medium"
    return "low"


def build_queue(templates: list[dict[str, Any]]) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    blockers: list[dict[str, Any]] = []
    for template in templates:
        if template.get("review_state") != "pending_human_review":
            raise ValueError("Review queue accepts only pending templates")
        source = template["source"]
        for candidate in template.get("candidate_records", []):
            record = candidate["source_record"]
            entries.append(
                {
                    "priority": priority_for(candidate),
                    "source": source,
                    "template_file": template["template_file"],
                    "candidate_id": candidate["candidate_id"],
                    "kind": record.get("kind"),
                    "title": record.get("title"),
                    "value": record.get("value"),
                    "citations": record.get("citations", []),
                    "automated_flags": candidate.get("automated_flags", []),
                    "required_human_action": "verify citation, then accept, reject, or request clarification",
                }
            )
        for item in template.get("review_queue", []):
            if item.get("candidate_id") is None:
                blockers.append({"source": source, **item})
    order = {"high": 0, "medium": 1, "low": 2}
    entries.sort(key=lambda item: (order[item["priority"]], item["source"]["file_name"], item["candidate_id"]))
    return {
        "schema_version": 1,
        "review_state": "pending_human_review",
        "scoring_allowed": False,
        "review_instructions": [
            "Complete high-priority safety, procedure, and conflict items first.",
            "Use the retained citation before accepting any candidate.",
            "Resolve page-level blockers before marking the corresponding template reviewed.",
            "Do not calculate accuracy or hallucinations until every candidate and blocker has a disposition.",
        ],
        "summary": {
            "documents": len(templates),
            "candidates": len(entries),
            "by_priority": dict(Counter(item["priority"] for item in entries)),
            "by_kind": dict(Counter(item["kind"] for item in entries)),
            "page_level_blockers": len(blockers),
        },
        "page_level_blockers": blockers,
        "entries": entries,
    }


def write_high_priority_batches(queue: dict[str, Any], output_dir: Path, batch_size: int) -> int:
    """Write bounded, citation-preserving batches without changing review state."""
    if batch_size < 1:
        raise ValueError("batch_size must be positive")
    high = [entry for entry in queue["entries"] if entry["priority"] == "high"]
    output_dir.mkdir(parents=True, exist_ok=True)
    batches = [high[index:index + batch_size] for index in range(0, len(high), batch_size)]
    manifest = []
    for number, entries in enumerate(batches, start=1):
        payload = {
            "schema_version": 1,
            "review_state": "pending_human_review",
            "scoring_allowed": False,
            "batch": number,
            "candidate_count": len(entries),
            "instructions": "Verify each citation, then record the disposition in its source review template.",
            "entries": entries,
        }
        path = output_dir / f"high-priority-{number:02d}.json"
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        manifest.append({"file": path.name, "candidate_count": len(entries)})
    (output_dir / "manifest.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "review_state": "pending_human_review",
                "scoring_allowed": False,
                "batch_size": batch_size,
                "high_priority_candidates": len(high),
                "batches": manifest,
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    return len(batches)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--high-priority-batch-dir", type=Path)
    parser.add_argument("--batch-size", type=int, default=25)
    args = parser.parse_args()
    templates = []
    for path in sorted(args.template_dir.glob("*.review-template.json")):
        template = json.loads(path.read_text(encoding="utf-8"))
        template["template_file"] = path.name
        templates.append(template)
    if not templates:
        raise ValueError("No review templates found")
    payload = build_queue(templates)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    batches = None
    if args.high_priority_batch_dir:
        batches = write_high_priority_batches(payload, args.high_priority_batch_dir, args.batch_size)
    print(json.dumps({**payload["summary"], "high_priority_batches": batches}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
