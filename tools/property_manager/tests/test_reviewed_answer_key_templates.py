from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.create_reviewed_answer_key_templates import (  # noqa: E402
    add_conflict_flags,
    flatten_candidates,
)
from tools.property_manager.handbook_eval.score_reviewed_answer_key import score_template  # noqa: E402


class ReviewedAnswerKeyTemplateTests(unittest.TestCase):
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

    def test_refuses_to_score_pending_template(self) -> None:
        with self.assertRaisesRegex(ValueError, "review_state"):
            score_template({"review_state": "pending_human_review"})

    def test_scores_only_a_reviewed_template(self) -> None:
        score = score_template(
            {
                "review_state": "reviewed",
                "reviewed_expected_facts": [
                    {"id": "page-1-record-1", "value": "120", "pages": [1]},
                ],
                "candidate_records": [
                    {
                        "candidate_id": "page-1-record-1",
                        "review_status": "accepted",
                        "source_record": {
                            "value": "120",
                            "citations": [{"page": 1, "excerpt": "120 V"}],
                        },
                    },
                ],
            }
        )
        self.assertTrue(score["passed"])


if __name__ == "__main__":
    unittest.main()
