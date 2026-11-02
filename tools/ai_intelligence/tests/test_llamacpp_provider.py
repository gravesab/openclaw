"""Tests for the llama.cpp HTTP provider."""

from __future__ import annotations

import json
import socket
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from tools.ai_intelligence.execution_models import ProviderRequest
from tools.ai_intelligence.llamacpp_config import LlamaCppConfig
from tools.ai_intelligence.llamacpp_provider import (
    LlamaCppProvider,
    build_llamacpp_provider,
)
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)


class FakeHTTPResponse:
    def __init__(self, payload: bytes, status: int = 200) -> None:
        self._payload = payload
        self.status = status

    def __enter__(self) -> "FakeHTTPResponse":
        return self

    def __exit__(
        self,
        exc_type: object,
        exc: object,
        traceback: object,
    ) -> None:
        return None

    def read(self) -> bytes:
        return self._payload


def completion_body(content: str = "Hello from llama") -> bytes:
    return json.dumps(
        {
            "choices": [
                {"message": {"role": "assistant", "content": content}}
            ],
            "usage": {
                "prompt_tokens": 8,
                "completion_tokens": 20,
                "total_tokens": 28,
            },
            "timings": {"predicted_n": 20, "predicted_ms": 500},
        }
    ).encode("utf-8")


class LlamaCppProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.provider = LlamaCppProvider(
            LlamaCppConfig(
                base_url="http://127.0.0.1:8088",
                default_timeout_seconds=30,
            )
        )
        self.request = ProviderRequest(
            model_id="llama-cpp-qwen3.5-9b",
            prompt="Hello",
            timeout_seconds=15,
            parameters={"temperature": 0.2},
        )

    def test_implements_provider_contract(self) -> None:
        self.assertIsInstance(self.provider, AIProvider)
        self.assertEqual(self.provider.name, "llama.cpp")

    def test_supports_model_ids(self) -> None:
        self.assertTrue(
            self.provider.supports_model("llama-cpp-qwen3.5-9b")
        )
        self.assertFalse(
            self.provider.supports_model("ollama-hermes3-8b")
        )
        self.assertFalse(
            self.provider.supports_model("llama-cpp-mystery")
        )

    def test_execute_success_keeps_raw_timings(self) -> None:
        with patch(
            "tools.ai_intelligence.llamacpp_provider.urlopen",
            return_value=FakeHTTPResponse(completion_body()),
        ):
            response = self.provider.execute(self.request)

        self.assertEqual(response.provider_name, "llama.cpp")
        self.assertEqual(response.model_id, "llama-cpp-qwen3.5-9b")
        self.assertEqual(response.content, "Hello from llama")
        self.assertGreaterEqual(response.duration_ms, 0)
        self.assertEqual(
            response.raw_response["timings"]["predicted_n"], 20
        )

    def test_execute_rejects_unsupported_model(self) -> None:
        bad = ProviderRequest(
            model_id="ollama-hermes3-8b", prompt="Hello"
        )
        with self.assertRaises(ProviderUnavailableError):
            self.provider.execute(bad)

    def test_execute_rejects_blank_content(self) -> None:
        with patch(
            "tools.ai_intelligence.llamacpp_provider.urlopen",
            return_value=FakeHTTPResponse(completion_body("   ")),
        ):
            with self.assertRaises(InvalidProviderResponseError):
                self.provider.execute(self.request)

    def test_execute_maps_http_error(self) -> None:
        error = HTTPError(
            "http://127.0.0.1:8088/v1/chat/completions",
            500,
            "boom",
            {},
            None,
        )
        with patch(
            "tools.ai_intelligence.llamacpp_provider.urlopen",
            side_effect=error,
        ):
            with self.assertRaises(ProviderUnavailableError):
                self.provider.execute(self.request)

    def test_execute_maps_timeout(self) -> None:
        with patch(
            "tools.ai_intelligence.llamacpp_provider.urlopen",
            side_effect=socket.timeout("slow"),
        ):
            with self.assertRaises(ProviderTimeoutError):
                self.provider.execute(self.request)

    def test_is_available_probes_health(self) -> None:
        with patch(
            "tools.ai_intelligence.llamacpp_provider.urlopen",
            return_value=FakeHTTPResponse(b'{"status":"ok"}'),
        ) as opened:
            self.assertTrue(self.provider.is_available())
            opened.assert_called_once()
            called_url = opened.call_args[0][0]
            self.assertTrue(called_url.endswith("/health"))

    def test_is_available_false_on_error(self) -> None:
        with patch(
            "tools.ai_intelligence.llamacpp_provider.urlopen",
            side_effect=URLError("down"),
        ):
            self.assertFalse(self.provider.is_available())

    def test_builds_from_environment(self) -> None:
        with patch.dict(
            "os.environ",
            {"OPENCLAW_LLAMACPP_BASE_URL": "http://127.0.0.1:8088"},
            clear=False,
        ):
            provider = build_llamacpp_provider()
        self.assertIsInstance(provider, LlamaCppProvider)


if __name__ == "__main__":
    unittest.main()
