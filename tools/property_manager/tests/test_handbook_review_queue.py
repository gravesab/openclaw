from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.create_handbook_review_queue import build_queue  # noqa: E402
from tools.property_manager.handbook_eval.create_handbook_review_queue import write_high_priority_batches  # noqa: E402


class HandbookReviewQueueTests(unittest.TestCase):
    def test_prioritizes_warnings_and_keeps_citation(self) -> None:
        queue = build_queue(
            [{
                "review_state": "pending_human_review",
                "template_file": "sample.json",
                "source": {"file_name": "manual.pdf", "sha256": "abc"},
                "candidate_records": [{
                    "candidate_id": "page-1-record-1",
                    "automated_flags": ["requires_human_relevance_review"],
                    "source_record": {"kind": "warning", "title": "Danger", "value": "Stop", "citations": [{"page": 1, "excerpt": "Danger"}]},
                }],
                "review_queue": [],
            }]
        )
        self.assertEqual(queue["summary"]["by_priority"], {"high": 1})
        self.assertEqual(queue["entries"][0]["citations"][0]["excerpt"], "Danger")
        self.assertFalse(queue["scoring_allowed"])

    def test_writes_pending_high_priority_batches(self) -> None:
        queue = {
            "entries": [{"priority": "high", "candidate_id": "one"}, {"priority": "high", "candidate_id": "two"}],
        }
        with self.subTest("batches are review-only"):
            from tempfile import TemporaryDirectory

            with TemporaryDirectory() as directory:
                self.assertEqual(write_high_priority_batches(queue, Path(directory), 1), 2)
                payload = __import__("json").loads((Path(directory) / "high-priority-01.json").read_text())
                self.assertEqual(payload["review_state"], "pending_human_review")
                self.assertFalse(payload["scoring_allowed"])


if __name__ == "__main__":
    unittest.main()
