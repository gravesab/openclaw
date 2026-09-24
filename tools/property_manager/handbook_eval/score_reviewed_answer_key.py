#!/usr/bin/env python3
"""Score one reviewed handbook answer key; refuse unreviewed templates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from tools.property_manager.handbook_eval.score_handbook_facts import score_response


def score_template(template: dict[str, Any]) -> dict[str, Any]:
    if template.get("review_state") != "reviewed":
        raise ValueError("Refusing to score: review_state must be 'reviewed'")
    expected = template.get("reviewed_expected_facts")
    if not isinstance(expected, list) or not expected:
        raise ValueError("Refusing to score: reviewed_expected_facts must be non-empty")
    candidate_facts = [
        {
            "id": item["source_record"].get("id", item["candidate_id"]),
            "value": item["source_record"].get("value"),
            "citations": item["source_record"].get("citations", []),
        }
        for item in template.get("candidate_records", [])
        if item.get("review_status") == "accepted"
    ]
    return score_response({"facts": candidate_facts}, {"expected_facts": expected})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    args = parser.parse_args()
    template: dict[str, Any] = json.loads(args.template.read_text(encoding="utf-8"))
    print(json.dumps(score_template(template), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
