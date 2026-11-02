"""Tests for local runtime status probes."""

from __future__ import annotations

import json
import unittest
from unittest.mock import patch
from urllib.error import URLError

from tools.ai_intelligence.runtime_status import (
    llamacpp_runtime_status,
    ollama_runtime_status,
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


class OllamaStatusTests(unittest.TestCase):
    def test_reports_first_model(self) -> None:
        body = json.dumps(
            {"models": [{"name": "qwen3.5:9b"}, {"name": "x"}]}
        ).encode("utf-8")
        with patch(
            "tools.ai_intelligence.runtime_status.urlopen",
            return_value=FakeHTTPResponse(body),
        ):
            status = ollama_runtime_status("http://127.0.0.1:11434")

        self.assertTrue(status.ok)
        self.assertEqual(status.provider, "ollama")
        self.assertEqual(status.model, "qwen3.5:9b")
        self.assertIsNotNone(status.latency_ms)

    def test_down_server_is_not_ok(self) -> None:
        with patch(
            "tools.ai_intelligence.runtime_status.urlopen",
            side_effect=URLError("refused"),
        ):
            status = ollama_runtime_status("http://127.0.0.1:11434")

        self.assertFalse(status.ok)
        self.assertIsNone(status.model)
        self.assertIn("unreachable", status.detail)

    def test_empty_list_stays_ok_without_model(self) -> None:
        body = json.dumps({"models": []}).encode("utf-8")
        with patch(
            "tools.ai_intelligence.runtime_status.urlopen",
            return_value=FakeHTTPResponse(body),
        ):
            status = ollama_runtime_status("http://127.0.0.1:11434")

        self.assertTrue(status.ok)
        self.assertIsNone(status.model)


class LlamaCppStatusTests(unittest.TestCase):
    def test_reports_loaded_model(self) -> None:
        def fake_urlopen(url: object, timeout: object = None):
            if str(url).endswith("/health"):
                return FakeHTTPResponse(b'{"status":"ok"}')
            return FakeHTTPResponse(
                json.dumps(
                    {"data": [{"id": "qwen3.5-9b"}]}
                ).encode("utf-8")
            )

        with patch(
            "tools.ai_intelligence.runtime_status.urlopen",
            side_effect=fake_urlopen,
        ):
            status = llamacpp_runtime_status(
                "http://127.0.0.1:8088"
            )

        self.assertTrue(status.ok)
        self.assertEqual(status.provider, "llama.cpp")
        self.assertEqual(status.model, "qwen3.5-9b")

    def test_failed_health_is_not_ok(self) -> None:
        with patch(
            "tools.ai_intelligence.runtime_status.urlopen",
            side_effect=URLError("refused"),
        ):
            status = llamacpp_runtime_status(
                "http://127.0.0.1:8088"
            )

        self.assertFalse(status.ok)
        self.assertIsNone(status.model)


if __name__ == "__main__":
    unittest.main()
