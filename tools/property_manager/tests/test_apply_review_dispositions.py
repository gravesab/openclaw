from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.apply_review_dispositions import apply_dispositions  # noqa: E402


class ApplyReviewDispositionsTests(unittest.TestCase):
    def test_records_accepted_and_rejected_human_decisions(self) -> None:
        template = {
            "source": {"file_name": "manual.pdf"},
            "review_state": "pending_human_review",
            "candidate_records": [
                {"candidate_id": "one", "review_status": "pending_human_review", "source_record": {"value": "keep", "citations": [{"page": 1}]}},
                {"candidate_id": "two", "review_status": "pending_human_review", "source_record": {"value": "drop", "citations": [{"page": 2}]}},
            ],
            "reviewed_expected_facts": [],
        }
        with TemporaryDirectory() as directory:
            path = Path(directory) / "manual.review-template.json"
            path.write_text(json.dumps(template), encoding="utf-8")
            result = apply_dispositions(
                Path(directory),
                [
                    {"source_file_name": "manual.pdf", "candidate_id": "one", "disposition": "accepted"},
                    {"source_file_name": "manual.pdf", "candidate_id": "two", "disposition": "rejected", "note": "not relevant"},
                ],
                "batch-01",
            )
            saved = json.loads(path.read_text())
        self.assertEqual(result, {"accepted": 1, "rejected": 1})
        self.assertEqual(saved["candidate_records"][1]["review_note"], "not relevant")
        self.assertEqual(saved["reviewed_expected_facts"], [{"id": "one", "value": "keep", "pages": [1]}])
        self.assertEqual(saved["scoring"]["status"], "blocked_pending_human_review")


if __name__ == "__main__":
    unittest.main()
