"""Tests for oMLX provider configuration."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from tools.ai_intelligence.omlx_config import (
    OMLXConfig,
    OMLXConfigurationError,
    is_omlx_configured,
    is_omlx_model_id,
    to_omlx_model_name,
)


class OMLXConfigTests(unittest.TestCase):
    def test_normalizes_base_url(self) -> None:
        config = OMLXConfig("http://10.0.2.2:8000/v1/", "secret")
        self.assertEqual(config.base_url, "http://10.0.2.2:8000/v1")

    def test_requires_api_key(self) -> None:
        with self.assertRaises(OMLXConfigurationError):
            OMLXConfig("http://10.0.2.2:8000/v1", " ")

    def test_rejects_invalid_scheme(self) -> None:
        with self.assertRaises(OMLXConfigurationError):
            OMLXConfig("file:///tmp/omlx", "secret")

    @patch.dict(
        "os.environ",
        {
            "OPENCLAW_OMLX_BASE_URL": "http://10.0.2.2:8000/v1",
            "OPENCLAW_OMLX_API_KEY": "secret",
            "OPENCLAW_OMLX_TIMEOUT_SECONDS": "45",
        },
        clear=True,
    )
    def test_loads_environment(self) -> None:
        config = OMLXConfig.from_env()
        self.assertEqual(config.api_key, "secret")
        self.assertEqual(config.default_timeout_seconds, 45)

    @patch.dict("os.environ", {}, clear=True)
    def test_defaults_to_loopback(self) -> None:
        with self.assertRaises(OMLXConfigurationError):
            OMLXConfig.from_env()

        with patch.dict(
            "os.environ",
            {"OPENCLAW_OMLX_API_KEY": "secret"},
            clear=True,
        ):
            self.assertEqual(
                OMLXConfig.from_env().base_url,
                "http://127.0.0.1:8000/v1",
            )

    @patch.dict("os.environ", {}, clear=True)
    def test_reports_unconfigured_without_key(self) -> None:
        self.assertFalse(is_omlx_configured())
        with patch.dict(
            "os.environ",
            {"OPENCLAW_OMLX_API_KEY": " secret "},
            clear=True,
        ):
            self.assertTrue(is_omlx_configured())

    def test_translates_model(self) -> None:
        self.assertEqual(
            to_omlx_model_name("omlx-qwen3.5-9b-4bit"),
            "Qwen3.5-9B-4bit",
        )
        self.assertTrue(is_omlx_model_id("omlx-qwen3.5-9b-4bit"))

    def test_rejects_unknown_model(self) -> None:
        with self.assertRaises(OMLXConfigurationError):
            to_omlx_model_name("omlx-unknown")


if __name__ == "__main__":
    unittest.main()
