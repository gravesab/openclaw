"""Tests for Ollama configuration and model translation."""

from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from tools.ai_intelligence.ollama_config import (
    OllamaConfig,
    OllamaConfigurationError,
    _is_allowed_host,
    is_ollama_model_id,
    to_ollama_model_name,
)


class OllamaModelTranslationTests(unittest.TestCase):
    def test_translates_known_model_ids(self) -> None:
        expected = {
            "ollama-hermes3-8b": "hermes3:8b",
            "ollama-gemma3-12b": "gemma3:12b",
            "ollama-gemma4-12b-mlx": "gemma4:12b-mlx",
            "ollama-llama3.2-3b": "llama3.2:3b",
        }

        for model_id, ollama_name in expected.items():
            with self.subTest(model_id=model_id):
                self.assertEqual(
                    to_ollama_model_name(model_id),
                    ollama_name,
                )

    def test_unknown_model_id_is_rejected(self) -> None:
        with self.assertRaises(OllamaConfigurationError):
            to_ollama_model_name("ollama-unknown-model")

    def test_blank_model_id_is_rejected(self) -> None:
        with self.assertRaises(OllamaConfigurationError):
            to_ollama_model_name(" ")

    def test_identifies_ollama_model_ids(self) -> None:
        self.assertTrue(
            is_ollama_model_id("ollama-hermes3-8b")
        )
        self.assertFalse(
            is_ollama_model_id("openai-gpt")
        )


class OllamaConfigTests(unittest.TestCase):
    def test_normalizes_base_url(self) -> None:
        config = OllamaConfig(
            base_url="http://127.0.0.1:11434/",
            default_timeout_seconds=30,
        )

        self.assertEqual(
            config.base_url,
            "http://127.0.0.1:11434",
        )

    def test_rejects_invalid_url_scheme(self) -> None:
        with self.assertRaises(OllamaConfigurationError):
            OllamaConfig(
                base_url="ftp://127.0.0.1:11434"
            )

    def test_rejects_invalid_timeout(self) -> None:
        with self.assertRaises(OllamaConfigurationError):
            OllamaConfig(
                base_url="http://127.0.0.1:11434",
                default_timeout_seconds=0,
            )

    def test_builds_from_environment(self) -> None:
        environment = {
            "OPENCLAW_OLLAMA_BASE_URL":
                "http://127.0.0.1:11434",
            "OPENCLAW_OLLAMA_TIMEOUT_SECONDS":
                "45",
        }

        with patch.dict(
            os.environ,
            environment,
            clear=False,
        ):
            config = OllamaConfig.from_env()

        self.assertEqual(
            config.base_url,
            "http://127.0.0.1:11434",
        )
        self.assertEqual(
            config.default_timeout_seconds,
            45.0,
        )

    def test_rejects_non_numeric_environment_timeout(
        self,
    ) -> None:
        with patch.dict(
            os.environ,
            {
                "OPENCLAW_OLLAMA_TIMEOUT_SECONDS":
                    "not-a-number"
            },
            clear=False,
        ):
            with self.assertRaises(
                OllamaConfigurationError
            ):
                OllamaConfig.from_env()


class OllamaHostAllowlistTests(unittest.TestCase):
    def _closed(self):
        return patch.dict(
            os.environ,
            {
                "RANCH_ALLOW_PRIVATE_LAN": "0",
                "OLLAMA_HOST_ALLOWLIST": "",
                "ENVIRONMENT": "",
            },
            clear=False,
        )

    def test_loopback_passes_and_public_private_and_unspecified_are_blocked(self) -> None:
        with self._closed(), patch(
            "tools.security.allowlist._note_private_lan"
        ) as note:
            self.assertTrue(_is_allowed_host("127.0.0.1"))
            self.assertTrue(_is_allowed_host("::1"))
            self.assertTrue(_is_allowed_host("localhost"))
            self.assertFalse(_is_allowed_host("attacker.com"))
            self.assertFalse(_is_allowed_host("10.0.0.1"))
            self.assertFalse(_is_allowed_host("0.0.0.0"))
            note.assert_not_called()

    def test_private_passes_only_with_opt_in(self) -> None:
        with self._closed(), patch.dict(
            os.environ, {"RANCH_ALLOW_PRIVATE_LAN": "1"}, clear=False
        ), patch(
            "tools.security.allowlist._note_private_lan"
        ) as note:
            self.assertTrue(_is_allowed_host("10.0.0.1"))
            self.assertFalse(_is_allowed_host("0.0.0.0"))
            self.assertFalse(_is_allowed_host("attacker.com"))
            note.assert_called()

    def test_explicit_allowlist_rejects_wildcard_and_unspecified(self) -> None:
        with self._closed(), patch.dict(
            os.environ,
            {"OLLAMA_HOST_ALLOWLIST": "192.168.50.117,*,0.0.0.0,10.0.0.0/8"},
            clear=False,
        ), patch(
            "tools.security.allowlist._note_private_lan"
        ):
            self.assertTrue(_is_allowed_host("192.168.50.117"))
            self.assertFalse(_is_allowed_host("10.0.0.1"))
            self.assertFalse(_is_allowed_host("0.0.0.0"))
            self.assertFalse(_is_allowed_host("attacker.com"))


if __name__ == "__main__":
    unittest.main()
