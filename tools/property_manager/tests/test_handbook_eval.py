from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.score_handbook_facts import (  # noqa: E402
    excerpt_is_supported,
    parse_model_json,
    score_response,
)


KEY = {
    "expected_facts": [
        {"id": "manufacturer", "value": "DR Power Equipment", "pages": [1]},
        {"id": "model_number", "value": None, "pages": [1]},
    ]
}


class HandbookEvaluationTests(unittest.TestCase):
    def test_scores_fully_cited_correct_response(self) -> None:
        candidate = {"facts": [
            {"id": "manufacturer", "value": "DR Power Equipment", "citations": [{"page": 1, "excerpt": "DR Power Equipment"}]},
            {"id": "model_number", "value": None, "citations": [{"page": 1, "excerpt": "Serial No."}]},
        ]}
        score = score_response(candidate, KEY)
        self.assertTrue(score["passed"])
        self.assertEqual(score["accuracy"], 1.0)
        self.assertEqual(score["hallucination_count"], 0)

    def test_flags_wrong_page_and_unsupported_fact_as_hallucinations(self) -> None:
        candidate = {"facts": [
            {"id": "manufacturer", "value": "DR Power Equipment", "citations": [{"page": 7, "excerpt": "Specifications"}]},
            {"id": "engine_type", "value": "gas", "citations": [{"page": 1, "excerpt": "DR"}]},
        ]}
        score = score_response(candidate, KEY)
        self.assertFalse(score["passed"])
        self.assertEqual(score["hallucination_count"], 2)
        self.assertTrue(any(item["type"] == "missing_fact" for item in score["findings"]))

    def test_flags_excerpt_not_found_on_cited_source_page(self) -> None:
        candidate = {"facts": [
            {"id": "manufacturer", "value": "DR Power Equipment", "citations": [{"page": 1, "excerpt": "invented excerpt"}]},
            {"id": "model_number", "value": None, "citations": [{"page": 1, "excerpt": "Serial No."}]},
        ]}
        score = score_response(candidate, KEY, source_pages={1: "DR Power Equipment Serial No."})
        self.assertEqual(score["hallucination_count"], 1)
        self.assertTrue(any(item["type"] == "unsupported_excerpt" for item in score["findings"]))

    def test_accepts_declared_equivalent_value(self) -> None:
        key = {"expected_facts": [{"id": "gap", "value": "1/16 inch", "acceptable_values": ["1/16\""], "pages": [19]}]}
        candidate = {"facts": [{"id": "gap", "value": "1/16\"", "citations": [{"page": 19, "excerpt": "gap"}]}]}
        self.assertTrue(score_response(candidate, key)["passed"])

    def test_accepts_reviewed_required_terms(self) -> None:
        key = {
            "expected_facts": [
                {
                    "id": "safety",
                    "value": "canonical wording",
                    "required_terms": ["PTO", "spark plug wire", "5 minutes"],
                    "pages": [15],
                }
            ]
        }
        candidate = {
            "facts": [
                {
                    "id": "safety",
                    "value": "Disengage the PTO, remove spark plug wire, then wait 5 minutes.",
                    "citations": [{"page": 15, "excerpt": "safety"}],
                }
            ]
        }
        self.assertTrue(score_response(candidate, key)["passed"])

    def test_repairs_one_markdown_json_fence(self) -> None:
        parsed, repair = parse_model_json('```json\n{"facts": []}\n```')

        self.assertEqual(parsed, {"facts": []})
        self.assertEqual(repair, "markdown_json_fence")

    def test_accepts_truthful_ellipsis_source_excerpt(self) -> None:
        self.assertTrue(
            excerpt_is_supported(
                "shut down the engine...wait 5 minutes",
                "Shut down the engine, wait for all moving parts to stop, then wait 5 minutes.",
            )
        )

    def test_requires_fact_specific_citation_terms_when_declared(self) -> None:
        key = {
            "expected_facts": [
                {
                    "id": "gap",
                    "value": "1/16 inch",
                    "citation_terms": ["1/16"],
                    "pages": [19],
                }
            ]
        }
        candidate = {
            "facts": [
                {
                    "id": "gap",
                    "value": "1/16 inch",
                    "citations": [{"page": 19, "excerpt": "safety warning"}],
                }
            ]
        }
        score = score_response(
            candidate,
            key,
            source_pages={19: "safety warning 1/16 inch"},
        )
        self.assertEqual(score["hallucination_count"], 1)
        self.assertTrue(
            any(item["type"] == "unsupported_fact_excerpt" for item in score["findings"])
        )


if __name__ == "__main__":
    unittest.main()
