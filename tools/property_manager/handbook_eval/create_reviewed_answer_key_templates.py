#!/usr/bin/env python3
"""Create human-review answer-key templates from local handbook checkpoints.

This is a filesystem-only preparation step. It preserves every retained local
model citation and never imports PropertyManager database or API code.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1


def normalized(value: object) -> str:
    """Compare candidate labels without changing the reviewer-visible source."""
    return re.sub(r"\s+", " ", str(value or "").strip().casefold())


def load_checkpoint(path: Path) -> dict[str, Any]:
    checkpoint = json.loads(path.read_text(encoding="utf-8"))
    if not checkpoint.get("complete"):
        raise ValueError(f"Checkpoint is incomplete: {path}")
    if not isinstance(checkpoint.get("source"), dict):
        raise ValueError(f"Checkpoint has no source identity: {path}")
    return checkpoint


def flatten_candidates(checkpoint: dict[str, Any]) -> tuple[list[dict[str, Any]], list[int]]:
    candidates: list[dict[str, Any]] = []
    empty_pages: list[int] = []
    for page_key, result in sorted(checkpoint["pages"].items(), key=lambda item: int(item[0])):
        page = int(page_key)
        records = result.get("records", [])
        if not records:
            empty_pages.append(page)
        for index, record in enumerate(records, start=1):
            item = {
                "candidate_id": f"page-{page}-record-{index}",
                "source_record": record,
                "review_status": "pending_human_review",
                "review_note": None,
                "automated_flags": ["requires_human_relevance_review"],
            }
            if not normalized(record.get("title")):
                item["automated_flags"].append("missing_title")
            if not normalized(record.get("value")):
                item["automated_flags"].append("missing_value")
            candidates.append(item)
    return candidates, empty_pages


def add_conflict_flags(candidates: list[dict[str, Any]]) -> None:
    """Mark candidate relationships; do not auto-merge or choose a winner."""
    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    facts: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for candidate in candidates:
        record = candidate["source_record"]
        fact_key = (normalized(record.get("kind")), normalized(record.get("title")))
        facts[fact_key].append(candidate)
        groups[(*fact_key, normalized(record.get("value")))].append(candidate)
    for duplicates in groups.values():
        if len(duplicates) > 1:
            for candidate in duplicates:
                candidate["automated_flags"].append("duplicate_candidate")
    for variants in facts.values():
        values = {normalized(item["source_record"].get("value")) for item in variants}
        if len(values) > 1:
            for candidate in variants:
                candidate["automated_flags"].append("conflicting_values_for_same_kind_and_title")


def create_template(checkpoint_path: Path) -> dict[str, Any]:
    checkpoint = load_checkpoint(checkpoint_path)
    candidates, empty_pages = flatten_candidates(checkpoint)
    add_conflict_flags(candidates)
    queue = [
        {"candidate_id": item["candidate_id"], "flags": item["automated_flags"]}
        for item in candidates
        if len(item["automated_flags"]) > 1
    ]
    if empty_pages:
        queue.append(
            {
                "candidate_id": None,
                "flags": ["pages_without_retained_candidates", "inspect_visual_or_nonextractable_content"],
                "pages": empty_pages,
            }
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "review_state": "pending_human_review",
        "source": checkpoint["source"],
        "checkpoint_file": checkpoint_path.name,
        "local_model_route": checkpoint.get("routing"),
        "review_instructions": [
            "Review each candidate against its retained source citation before accepting it.",
            "Set candidate review_status to accepted, rejected, or needs_clarification and add a review_note.",
            "Copy only accepted, task-relevant facts into reviewed_expected_facts using candidate_id as the fact id.",
            "Set review_state to reviewed only after every candidate and flagged page has a disposition.",
            "Do not calculate scores until review_state is reviewed.",
        ],
        "candidate_records": candidates,
        "review_queue": queue,
        "reviewed_expected_facts": [],
        "scoring": {
            "status": "blocked_pending_human_review",
            "accuracy": None,
            "hallucination_count": None,
            "reason": "A human reviewer must approve expected facts before scoring.",
        },
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    checkpoints = sorted(path for path in args.checkpoint_dir.glob("*.json") if path.name != "smoke.json")
    if not checkpoints:
        raise ValueError("No non-smoke checkpoints found")
    templates = []
    for checkpoint_path in checkpoints:
        template = create_template(checkpoint_path)
        output = args.output_dir / f"{checkpoint_path.stem}.review-template.json"
        write_json(output, template)
        templates.append({"file": output.name, "source": template["source"], "candidate_count": len(template["candidate_records"])})
    write_json(
        args.output_dir / "manifest.json",
        {
            "schema_version": SCHEMA_VERSION,
            "review_state": "pending_human_review",
            "template_count": len(templates),
            "templates": templates,
            "cross_document_variations": "Review documents independently; shared labels with different values require manual context review.",
        },
    )
    print(json.dumps({"templates": len(templates), "output_dir": str(args.output_dir)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
