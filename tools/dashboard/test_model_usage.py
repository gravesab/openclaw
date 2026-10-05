"""Tests for the dashboard's process-by-process model view."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.dashboard.model_usage import build_model_usage, model_usage_panel_html

ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENT = json.loads(
    (ROOT / "config/ai_intelligence/deployment_map.json").read_text(encoding="utf-8")
)
REGISTRY = json.loads(
    (ROOT / "config/ai_intelligence/model_registry.json").read_text(encoding="utf-8")
)


class ModelUsageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.snapshot = build_model_usage(DEPLOYMENT, REGISTRY)
        self.processes = {
            process["id"]: process for process in self.snapshot["processes"]
        }

    def test_lightweight_dev_process_keeps_apple_first(self) -> None:
        process = self.processes["apple_foundation_models_dev"]
        self.assertEqual(
            process["selected_model_ids"][0],
            "apple-foundation-models",
        )
        self.assertEqual(
            process["selected_model_ids"][1],
            "llama-cpp-qwen3.5-9b",
        )
        self.assertIn("omlx-qwen3.5-9b-4bit", process["selected_model_ids"])

    def test_property_data_selects_llama_cpp_first(self) -> None:
        process = self.processes["property_manager"]
        self.assertEqual(process["selected_model_ids"][0], "llama-cpp-qwen3.5-9b")
        self.assertIn("omlx-qwen3.5-9b-4bit", process["selected_model_ids"])
        self.assertNotIn("openai-frontier", process["selected_model_ids"])

    def test_local_large_problem_does_not_select_cloud(self) -> None:
        process = self.processes["knowledge_ingestion"]
        self.assertEqual(process["privacy_tier"], "local")
        self.assertEqual(process["selected_model_ids"][0], "llama-cpp-qwen3.5-9b")
        self.assertNotIn("openai-frontier", process["selected_model_ids"])

    def test_large_problem_moves_cloud_behind_the_local_model(self) -> None:
        process = self.processes["openclaw_engineering"]
        self.assertEqual(process["configured_model_ids"][0], "llama-cpp-qwen3.5-9b")
        self.assertEqual(process["selected_model_ids"][0], "llama-cpp-qwen3.5-9b")
        self.assertEqual(process["selected_model_ids"][-1], "openai-frontier")

    def test_home_assistant_leaves_cloud_unused(self) -> None:
        process = self.processes["home_assistant"]
        self.assertNotIn("openai-frontier", process["selected_model_ids"])
        self.assertIn("openai-frontier", process["unused_model_ids"])

    def test_dashboard_process_calls_no_model(self) -> None:
        process = self.processes["ranchbrain_dashboard"]
        self.assertEqual(process["selected_model_ids"], [])
        self.assertIn("does not call a model", process["notes"][0])

    def test_embedding_stays_on_its_configured_model(self) -> None:
        process = self.processes["embedding_service"]
        self.assertEqual(process["selected_model_ids"], ["nomic-embed-text"])

    def test_used_and_unused_models_are_separated(self) -> None:
        in_use = {model["model_id"] for model in self.snapshot["in_use"]}
        unused = {model["model_id"] for model in self.snapshot["not_in_use"]}
        self.assertIn("omlx-qwen3.5-9b-4bit", in_use)
        self.assertIn("apple-foundation-models", in_use)
        self.assertIn("openai-frontier", in_use)
        self.assertIn("claude", unused)
        self.assertIn("gemini", unused)
        self.assertIn("grok", unused)
        self.assertIn("kimi-k3", unused)
        self.assertIn("llama-cpp-qwen3.5-9b", in_use)
        self.assertNotIn("llama.cpp", unused)
        self.assertTrue(unused.isdisjoint(in_use))

        frontier = next(
            model for model in self.snapshot["in_use"]
            if model["model_id"] == "openai-frontier"
        )
        processes = {use["process_name"] for use in frontier["uses"]}
        self.assertIn("OpenClaw Engineering", processes)
        self.assertIn("Swift PropertyManager App", processes)
        self.assertFalse(frontier["cloud_client_attached"])

    def test_panel_names_processes_and_both_model_groups(self) -> None:
        rendered = model_usage_panel_html(self.snapshot)
        self.assertIn("Models by process", rendered)
        self.assertIn("PropertyManager", rendered)
        self.assertIn("Models in use", rendered)
        self.assertIn("Models not in use", rendered)
        self.assertIn("llama-cpp-qwen3.5-9b", rendered)
        self.assertIn("A llama.cpp model is on at least one selected chain.", rendered)
        self.assertIn("apple-foundation-models", rendered)
        self.assertIn("claude", rendered)


if __name__ == "__main__":
    unittest.main()
