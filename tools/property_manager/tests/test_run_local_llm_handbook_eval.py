from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.run_local_llm_handbook_eval import (  # noqa: E402
    EvaluationError,
    is_private_ollama_url,
    resolve_dev_local_route,
)


class LocalLlmHandbookEvalRunnerTests(unittest.TestCase):
    def test_rejects_public_ollama_endpoint(self) -> None:
        with self.assertRaisesRegex(EvaluationError, "non-private"):
            is_private_ollama_url("http://8.8.8.8:11434")

    def test_handbook_evaluation_route_is_local_and_ordered(self) -> None:
        route = resolve_dev_local_route("property_manager_handbook_evaluation")

        self.assertEqual(route["privacy_tier"], "local")
        self.assertEqual(
            [candidate["model_id"] for candidate in route["candidates"]],
            [
                "omlx-qwen3.5-9b-4bit",
                "ollama-gemma4-12b-mlx",
                "ollama-hermes3-8b",
            ],
        )


if __name__ == "__main__":
    unittest.main()
