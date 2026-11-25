"""Tests for llama.cpp endpoint configuration."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from tools.ai_intelligence.llamacpp_config import (
    LlamaCppConfig,
    LlamaCppConfigurationError,
    is_llamacpp_configured,
    is_llamacpp_model_id,
    to_llamacpp_model_name,
)


class LlamaCppConfigTests(unittest.TestCase):
    def test_defaults_to_local_server(self) -> None:
        config = LlamaCppConfig.from_env()
        self.assertEqual(
            config.base_url, "http://127.0.0.1:8088"
        )

    def test_strips_trailing_slash(self) -> None:
        config = LlamaCppConfig(base_url="http://127.0.0.1:8088/")
        self.assertEqual(
            config.base_url, "http://127.0.0.1:8088"
        )

    def test_rejects_bad_scheme_and_host(self) -> None:
        with self.assertRaises(LlamaCppConfigurationError):
            LlamaCppConfig(base_url="ws://127.0.0.1:8088")
        with self.assertRaises(LlamaCppConfigurationError):
            LlamaCppConfig(base_url="http:///no-host")

    def test_rejects_non_numeric_timeout(self) -> None:
        with patch.dict(
            "os.environ", {"OPENCLAW_LLAMACPP_TIMEOUT_SECONDS": "soon"}
        ):
            with self.assertRaises(LlamaCppConfigurationError):
                LlamaCppConfig.from_env()

    def test_dev_blocks_prod_server(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development",
                "OPENCLAW_LLAMACPP_BASE_URL": "http://100.85.36.72:8088",
            },
        ):
            with self.assertRaises(LlamaCppConfigurationError):
                LlamaCppConfig.from_env()

    def test_prod_blocks_dev_server(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "production",
                "OPENCLAW_LLAMACPP_BASE_URL": "http://100.85.188.74:8088",
            },
        ):
            with self.assertRaises(LlamaCppConfigurationError):
                LlamaCppConfig.from_env()

    def test_each_stack_reaches_own_server(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development",
                "OPENCLAW_LLAMACPP_BASE_URL": "http://100.85.188.74:8088",
            },
        ):
            self.assertEqual(
                LlamaCppConfig.from_env().base_url,
                "http://100.85.188.74:8088",
            )
        with patch.dict(
            "os.environ",
            {
                "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "production",
                "OPENCLAW_LLAMACPP_BASE_URL": "http://100.85.36.72:8088",
            },
        ):
            self.assertEqual(
                LlamaCppConfig.from_env().base_url,
                "http://100.85.36.72:8088",
            )


class LlamaCppModelIdTests(unittest.TestCase):
    def test_maps_supported_model(self) -> None:
        self.assertEqual(
            to_llamacpp_model_name("llama-cpp-qwen3.5-9b"),
            "qwen3.5-9b",
        )

    def test_rejects_unknown_model(self) -> None:
        with self.assertRaises(LlamaCppConfigurationError):
            to_llamacpp_model_name("llama-cpp-mystery")
        with self.assertRaises(LlamaCppConfigurationError):
            to_llamacpp_model_name("  ")

    def test_identifies_model_ids(self) -> None:
        self.assertTrue(is_llamacpp_model_id("llama-cpp-qwen3.5-9b"))
        self.assertFalse(is_llamacpp_model_id("ollama-hermes3-8b"))

    def test_configured_flag_follows_base_url(self) -> None:
        with patch.dict("os.environ", {}, clear=False):
            import os

            os.environ.pop("OPENCLAW_LLAMACPP_BASE_URL", None)
            self.assertFalse(is_llamacpp_configured())
        with patch.dict(
            "os.environ",
            {"OPENCLAW_LLAMACPP_BASE_URL": "http://127.0.0.1:8088"},
        ):
            self.assertTrue(is_llamacpp_configured())


if __name__ == "__main__":
    unittest.main()
