"""Tests for the oMLX HTTP provider."""

from __future__ import annotations

import io
import json
import socket
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from tools.ai_intelligence.execution_models import ProviderRequest
from tools.ai_intelligence.omlx_config import OMLXConfig
from tools.ai_intelligence.omlx_provider import OMLXProvider
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

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self._payload


class OMLXProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.provider = OMLXProvider(
            OMLXConfig("http://10.0.2.2:8000/v1", "secret", 30)
        )
        self.request = ProviderRequest(
            model_id="omlx-qwen3.5-9b-4bit",
            prompt="Hello",
            system_prompt="Be concise",
            timeout_seconds=15,
            parameters={"temperature": 0},
        )

    def test_implements_contract(self) -> None:
        self.assertIsInstance(self.provider, AIProvider)
        self.assertEqual(self.provider.name, "omlx")

    @patch("tools.ai_intelligence.omlx_provider.urlopen")
    def test_executes_chat_completion(self, mock_urlopen) -> None:
        mock_urlopen.return_value = FakeHTTPResponse(
            json.dumps(
                {
                    "model": "Qwen3.5-9B-4bit",
                    "choices": [
                        {"message": {"role": "assistant", "content": "Hi"}}
                    ],
                    "usage": {"completion_tokens": 1},
                }
            ).encode()
        )
        response = self.provider.execute(self.request)
        self.assertEqual(response.content, "Hi")
        self.assertEqual(response.provider_name, "omlx")
        call = mock_urlopen.call_args
        sent = json.loads(call.args[0].data.decode())
        self.assertEqual(sent["model"], "Qwen3.5-9B-4bit")
        self.assertEqual(sent["messages"][0]["role"], "system")
        self.assertEqual(sent["messages"][1]["content"], "Hello")
        self.assertEqual(sent["temperature"], 0)
        self.assertEqual(call.kwargs["timeout"], 15)
        self.assertEqual(
            call.args[0].headers["Authorization"], "Bearer secret"
        )

    @patch("tools.ai_intelligence.omlx_provider.urlopen")
    def test_timeout_is_normalized(self, mock_urlopen) -> None:
        mock_urlopen.side_effect = socket.timeout()
        with self.assertRaises(ProviderTimeoutError):
            self.provider.execute(self.request)

    @patch("tools.ai_intelligence.omlx_provider.urlopen")
    def test_url_failure_is_normalized(self, mock_urlopen) -> None:
        mock_urlopen.side_effect = URLError("refused")
        with self.assertRaises(ProviderUnavailableError):
            self.provider.execute(self.request)

    @patch("tools.ai_intelligence.omlx_provider.urlopen")
    def test_http_failure_is_normalized(self, mock_urlopen) -> None:
        mock_urlopen.side_effect = HTTPError(
            "http://10.0.2.2:8000/v1/chat/completions",
            401,
            "unauthorized",
            None,
            io.BytesIO(),
        )
        with self.assertRaises(ProviderUnavailableError):
            self.provider.execute(self.request)

    @patch("tools.ai_intelligence.omlx_provider.urlopen")
    def test_rejects_invalid_response(self, mock_urlopen) -> None:
        mock_urlopen.return_value = FakeHTTPResponse(b'{"choices":[]}')
        with self.assertRaises(InvalidProviderResponseError):
            self.provider.execute(self.request)

    def test_rejects_unknown_model_before_network(self) -> None:
        request = ProviderRequest(model_id="omlx-unknown", prompt="Hello")
        with self.assertRaises(ProviderUnavailableError):
            self.provider.execute(request)

    def test_rejects_reserved_parameter_override(self) -> None:
        request = ProviderRequest(
            model_id="omlx-qwen3.5-9b-4bit",
            prompt="Hello",
            parameters={"model": "attacker-selected"},
        )
        with self.assertRaises(InvalidProviderResponseError):
            self.provider.execute(request)


if __name__ == "__main__":
    unittest.main()
