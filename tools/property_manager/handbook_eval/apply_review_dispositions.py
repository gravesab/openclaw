#!/usr/bin/env python3
"""Apply explicit human dispositions to pending handbook review templates."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


ALLOWED_DISPOSITIONS = {"accepted", "rejected", "needs_clarification"}


def expected_fact(candidate: dict[str, Any]) -> dict[str, Any]:
    record = candidate["source_record"]
    pages = sorted({citation["page"] for citation in record.get("citations", []) if isinstance(citation, dict) and isinstance(citation.get("page"), int)})
    return {"id": candidate["candidate_id"], "value": record.get("value"), "pages": pages}


def write_template(path: Path, template: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(template, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def apply_dispositions(template_dir: Path, dispositions: list[dict[str, Any]], batch: str) -> dict[str, int]:
    """Validate the complete batch before atomically replacing any template."""
    templates: dict[str, tuple[Path, dict[str, Any]]] = {}
    candidates: dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]]] = {}
    for path in template_dir.glob("*.review-template.json"):
        template = json.loads(path.read_text(encoding="utf-8"))
        source_name = template.get("source", {}).get("file_name")
        if not isinstance(source_name, str):
            raise ValueError(f"Template has no source file name: {path}")
        templates[source_name] = (path, template)
        for candidate in template.get("candidate_records", []):
            key = (source_name, candidate.get("candidate_id"))
            if not isinstance(key[1], str):
                raise ValueError(f"Template has a candidate without an id: {path}")
            candidates[key] = (template, candidate)
    seen: set[tuple[str, str]] = set()
    for item in dispositions:
        source = item.get("source_file_name")
        candidate_id = item.get("candidate_id")
        disposition = item.get("disposition")
        if not isinstance(source, str) or not isinstance(candidate_id, str) or disposition not in ALLOWED_DISPOSITIONS:
            raise ValueError("Every disposition needs source_file_name, candidate_id, and an allowed disposition")
        key = (source, candidate_id)
        if key in seen:
            raise ValueError(f"Duplicate disposition: {source} {candidate_id}")
        seen.add(key)
        if key not in candidates:
            raise ValueError(f"Unknown candidate: {source} {candidate_id}")
        if candidates[key][1].get("review_status") != "pending_human_review":
            raise ValueError(f"Candidate is not pending human review: {source} {candidate_id}")
    changed: dict[str, int] = Counter()
    touched: set[str] = set()
    for item in dispositions:
        source = item["source_file_name"]
        template, candidate = candidates[(source, item["candidate_id"])]
        candidate["review_status"] = item["disposition"]
        candidate["review_note"] = item.get("note") or None
        if item["disposition"] == "accepted":
            facts = template.setdefault("reviewed_expected_facts", [])
            if not any(fact.get("id") == candidate["candidate_id"] for fact in facts):
                facts.append(expected_fact(candidate))
        changed[item["disposition"]] += 1
        touched.add(source)
    for source in touched:
        path, template = templates[source]
        template.setdefault("review_history", []).append({"batch": batch, "disposition_count": sum(1 for item in dispositions if item["source_file_name"] == source)})
        template["review_state"] = "pending_human_review"
        template["scoring"] = {
            "status": "blocked_pending_human_review",
            "accuracy": None,
            "hallucination_count": None,
            "reason": "Remaining candidate records still need a human disposition.",
        }
        write_template(path, template)
    return dict(changed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template-dir", type=Path, required=True)
    parser.add_argument("--batch", required=True)
    parser.add_argument("--dispositions-json", required=True, help="JSON array of human disposition objects")
    args = parser.parse_args()
    dispositions = json.loads(args.dispositions_json)
    if not isinstance(dispositions, list):
        raise ValueError("dispositions-json must be an array")
    print(json.dumps(apply_dispositions(args.template_dir, dispositions, args.batch)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
