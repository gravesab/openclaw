from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.create_reviewed_answer_key_templates import (  # noqa: E402
    add_conflict_flags,
    create_template,
    flatten_candidates,
)


class ReviewedAnswerKeyTemplateGenerationTests(unittest.TestCase):
    def test_preserves_citation_and_marks_conflict(self) -> None:
        checkpoint = {
            "pages": {
                "1": {"records": [{"kind": "specification", "title": "Voltage", "value": "120", "citations": [{"page": 1, "excerpt": "120 V"}]}]},
                "2": {"records": [{"kind": "specification", "title": "Voltage", "value": "240", "citations": [{"page": 2, "excerpt": "240 V"}]}]},
            }
        }
        candidates, empty_pages = flatten_candidates(checkpoint)
        add_conflict_flags(candidates)
        self.assertEqual(empty_pages, [])
        self.assertEqual(candidates[0]["source_record"]["citations"][0]["excerpt"], "120 V")
        self.assertIn("conflicting_values_for_same_kind_and_title", candidates[0]["automated_flags"])

    def test_create_template_blocks_scoring_and_keeps_citations(self) -> None:
        checkpoint = {
            "complete": True,
            "source": {"file_name": "manual.pdf", "sha256": "abc"},
            "routing": {"selected_model_id": "local-only"},
            "pages": {
                "1": {"records": [{"kind": "specification", "title": "Voltage", "value": "120", "citations": [{"page": 1, "excerpt": "120 V"}]}]},
                "3": {"records": []},
            },
        }
        with TemporaryDirectory() as directory:
            path = Path(directory) / "manual.json"
            path.write_text(json.dumps(checkpoint), encoding="utf-8")
            template = create_template(path)
        self.assertEqual(template["review_state"], "pending_human_review")
        self.assertEqual(template["scoring"]["status"], "blocked_pending_human_review")
        self.assertEqual(template["reviewed_expected_facts"], [])
        self.assertEqual(template["candidate_records"][0]["source_record"]["citations"][0]["excerpt"], "120 V")
        self.assertEqual(template["review_queue"][-1]["pages"], [3])


if __name__ == "__main__":
    unittest.main()
