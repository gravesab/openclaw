from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.property_manager.handbook_eval.run_local_llm_handbook_eval import (  # noqa: E402
    EvaluationError,
    is_private_ollama_url,
    resolve_dev_local_route,
    select_routed_model,
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

    def test_omlx_primary_does_not_require_ollama_inventory(self) -> None:
        route = resolve_dev_local_route("property_manager_handbook_evaluation")
        with (
            mock.patch(
                "tools.ai_intelligence.omlx_config.is_omlx_configured",
                return_value=True,
            ),
            mock.patch(
                "tools.property_manager.handbook_eval.run_local_llm_handbook_eval.available_ollama_models"
            ) as inventory,
        ):
            selected, unavailable = select_routed_model(
                route,
                ollama_url="http://127.0.0.1:11434",
                timeout_seconds=1,
            )

        self.assertEqual(selected["model_id"], "omlx-qwen3.5-9b-4bit")
        self.assertEqual(unavailable, [])
        inventory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
