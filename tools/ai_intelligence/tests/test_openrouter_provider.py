"""Tests for the OpenRouter cloud fallback provider."""

from __future__ import annotations

import json
import socket
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from tools.ai_intelligence.execution_models import ProviderRequest
from tools.ai_intelligence.openrouter_config import OpenRouterConfig
from tools.ai_intelligence.openrouter_provider import (
    OpenRouterProvider,
    build_openrouter_provider,
)
from tools.ai_intelligence.provider import (
    AIProvider,
    InvalidProviderResponseError,
    ProviderTimeoutError,
    ProviderUnavailableError,
)


class FakeHTTPResponse:
    def __init__(self, payload: bytes) -> None:
        self._payload = payload

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


def completion_body(content: str = "Hello from cloud") -> bytes:
    return json.dumps(
        {
            "choices": [
                {"message": {"role": "assistant", "content": content}}
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 30,
                "total_tokens": 40,
            },
        }
    ).encode("utf-8")


class OpenRouterProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.provider = OpenRouterProvider(
            OpenRouterConfig(
                base_url="https://openrouter.ai/api/v1",
                api_key="test-key",
                default_timeout_seconds=30,
            )
        )
        self.request = ProviderRequest(
            model_id="openrouter-moonshotai-kimi-k2",
            prompt="Hello",
            timeout_seconds=15,
        )

    def test_implements_provider_contract(self) -> None:
        self.assertIsInstance(self.provider, AIProvider)
        self.assertEqual(self.provider.name, "openrouter")

    def test_supports_model_ids(self) -> None:
        self.assertTrue(
            self.provider.supports_model(
                "openrouter-moonshotai-kimi-k2"
            )
        )
        self.assertFalse(
            self.provider.supports_model("ollama-hermes3-8b")
        )
        self.assertFalse(
            self.provider.supports_model("openrouter-nondash")
        )

    def test_execute_sends_bearer_auth(self) -> None:
        seen: dict[str, object] = {}

        def fake_urlopen(http_request: object, timeout: object = None):
            seen["request"] = http_request
            return FakeHTTPResponse(completion_body())

        with patch(
            "tools.ai_intelligence.openrouter_provider.urlopen",
            side_effect=fake_urlopen,
        ):
            response = self.provider.execute(self.request)

        sent = seen["request"]
        self.assertIn("openrouter.ai", sent.full_url)
        self.assertEqual(
            sent.headers.get("Authorization"), "Bearer test-key"
        )
        body = json.loads(seen["request"].data.decode("utf-8"))
        self.assertEqual(body["model"], "moonshotai/kimi-k2")
        self.assertEqual(response.content, "Hello from cloud")
        self.assertEqual(
            response.raw_response["usage"]["completion_tokens"], 30
        )

    def test_execute_rejects_bad_key(self) -> None:
        error = HTTPError(
            "https://openrouter.ai/api/v1/chat/completions",
            401,
            "unauthorized",
            {},
            None,
        )
        with patch(
            "tools.ai_intelligence.openrouter_provider.urlopen",
            side_effect=error,
        ):
            with self.assertRaises(ProviderUnavailableError):
                self.provider.execute(self.request)

    def test_execute_maps_timeout(self) -> None:
        with patch(
            "tools.ai_intelligence.openrouter_provider.urlopen",
            side_effect=socket.timeout("slow"),
        ):
            with self.assertRaises(ProviderTimeoutError):
                self.provider.execute(self.request)

    def test_execute_rejects_blank_content(self) -> None:
        with patch(
            "tools.ai_intelligence.openrouter_provider.urlopen",
            return_value=FakeHTTPResponse(completion_body("  ")),
        ):
            with self.assertRaises(InvalidProviderResponseError):
                self.provider.execute(self.request)

    def test_is_available_with_key(self) -> None:
        self.assertTrue(self.provider.is_available())

    def test_builds_from_environment(self) -> None:
        with patch.dict(
            "os.environ", {"OPENROUTER_API_KEY": "k"}
        ):
            provider = build_openrouter_provider()
        self.assertIsInstance(provider, OpenRouterProvider)


if __name__ == "__main__":
    unittest.main()
