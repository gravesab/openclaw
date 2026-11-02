"""Tests for OpenRouter fallback configuration."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from tools.ai_intelligence.openrouter_config import (
    OpenRouterConfig,
    OpenRouterConfigurationError,
    is_openrouter_configured,
    is_openrouter_model_id,
    to_openrouter_model_name,
)


class OpenRouterConfigTests(unittest.TestCase):
    def test_defaults_to_public_api(self) -> None:
        config = OpenRouterConfig(
            base_url="https://openrouter.ai/api/v1", api_key="k"
        )
        self.assertEqual(
            config.base_url, "https://openrouter.ai/api/v1"
        )

    def test_requires_api_key(self) -> None:
        with self.assertRaises(OpenRouterConfigurationError):
            OpenRouterConfig(
                base_url="https://openrouter.ai/api/v1", api_key="  "
            )

    def test_allows_cloud_host_both_stacks(self) -> None:
        for env in ("development", "production"):
            with patch.dict(
                "os.environ",
                {
                    "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": env,
                    "OPENROUTER_API_KEY": "k",
                },
            ):
                config = OpenRouterConfig.from_env()
                self.assertEqual(
                    config.base_url, "https://openrouter.ai/api/v1"
                )

    def test_rejects_stack_infra_override(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development",
                "OPENROUTER_API_KEY": "k",
                "OPENCLAW_OPENROUTER_BASE_URL": "http://100.85.36.72:8080",
            },
        ):
            with self.assertRaises(OpenRouterConfigurationError):
                OpenRouterConfig.from_env()

    def test_rejects_non_numeric_timeout(self) -> None:
        with patch.dict(
            "os.environ",
            {"OPENCLAW_OPENROUTER_TIMEOUT_SECONDS": "soon"},
        ):
            with self.assertRaises(OpenRouterConfigurationError):
                OpenRouterConfig.from_env()


class OpenRouterModelIdTests(unittest.TestCase):
    def test_translates_vendor_slug(self) -> None:
        self.assertEqual(
            to_openrouter_model_name("openrouter-moonshotai-kimi-k2"),
            "moonshotai/kimi-k2",
        )

    def test_rejects_missing_vendor(self) -> None:
        with self.assertRaises(OpenRouterConfigurationError):
            to_openrouter_model_name("openrouter-nondash")
        with self.assertRaises(OpenRouterConfigurationError):
            to_openrouter_model_name("ollama-hermes3-8b")

    def test_identifies_model_ids(self) -> None:
        self.assertTrue(
            is_openrouter_model_id("openrouter-moonshotai-kimi-k2")
        )
        self.assertFalse(is_openrouter_model_id("ollama-hermes3-8b"))

    def test_configured_flag_follows_key(self) -> None:
        with patch.dict("os.environ", {}, clear=False):
            import os

            os.environ.pop("OPENROUTER_API_KEY", None)
            self.assertFalse(is_openrouter_configured())
        with patch.dict(
            "os.environ", {"OPENROUTER_API_KEY": "k"}
        ):
            self.assertTrue(is_openrouter_configured())


if __name__ == "__main__":
    unittest.main()
