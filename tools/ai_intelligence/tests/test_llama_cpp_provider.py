"""Tests for the optional llama.cpp provider."""

from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from tools.ai_intelligence.execution_models import ProviderRequest
from tools.ai_intelligence.llama_cpp_config import (
    LlamaCppConfig,
    LlamaCppConfigurationError,
    is_llama_cpp_configured,
    parse_model_map,
)
from tools.ai_intelligence.llama_cpp_provider import LlamaCppProvider
from tools.ai_intelligence.provider import ProviderUnavailableError


class LlamaCppConfigTests(unittest.TestCase):
    def test_model_map_parses_id_pairs(self) -> None:
        self.assertEqual(
            parse_model_map("llama-cpp-qwen3.5-9b=Qwen3.5-9B.gguf"),
            {"llama-cpp-qwen3.5-9b": "Qwen3.5-9B.gguf"},
        )

    def test_blank_url_is_not_configured(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            self.assertFalse(is_llama_cpp_configured())

    def test_malformed_map_is_rejected(self) -> None:
        with self.assertRaises(LlamaCppConfigurationError):
            parse_model_map("llama-cpp-qwen3.5-9b")


class LlamaCppProviderTests(unittest.TestCase):
    def test_unknown_model_is_unavailable(self) -> None:
        provider = LlamaCppProvider(
            LlamaCppConfig(
                "http://127.0.0.1:8080/v1",
                {"llama-cpp-qwen3.5-9b": "Qwen3.5-9B.gguf"},
            )
        )

        with self.assertRaises(ProviderUnavailableError):
            provider.execute(
                ProviderRequest(
                    model_id="llama-cpp-other",
                    prompt="Hello",
                )
            )

    def test_execute_posts_the_served_model_name(self) -> None:
        provider = LlamaCppProvider(
            LlamaCppConfig(
                "http://127.0.0.1:8080/v1",
                {"llama-cpp-qwen3.5-9b": "Qwen3.5-9B.gguf"},
            )
        )

        class Response:
            def __enter__(self) -> "Response":
                return self

            def __exit__(self, *args: object) -> None:
                return None

            def read(self) -> bytes:
                return json.dumps(
                    {"choices": [{"message": {"content": "Local answer"}}]}
                ).encode("utf-8")

        with patch(
            "tools.ai_intelligence.llama_cpp_provider.urlopen",
            return_value=Response(),
        ) as urlopen:
            result = provider.execute(
                ProviderRequest(
                    model_id="llama-cpp-qwen3.5-9b",
                    prompt="Summarize the trough leak.",
                    system_prompt="Be concise.",
                )
            )

        sent = json.loads(urlopen.call_args.args[0].data.decode("utf-8"))
        self.assertEqual(sent["model"], "Qwen3.5-9B.gguf")
        self.assertEqual(sent["messages"][0]["role"], "system")
        self.assertEqual(result.content, "Local answer")
        self.assertEqual(result.provider_name, "llama.cpp")
