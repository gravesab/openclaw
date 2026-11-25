"""POST /sense requires a bearer token, and enabled quarantine lookups fail closed."""

from __future__ import annotations

import json
import os
import sys
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

from fastapi import HTTPException

_API_ROOT = Path(__file__).resolve().parents[2] / "tools" / "property_manager" / "api"
if str(_API_ROOT) not in sys.path:
    sys.path.insert(0, str(_API_ROOT))

from tools.ai_intelligence.mcp_boundary import _notify_sentinel as notify_mcp
from tools.ai_intelligence.mcp_boundary import _service_quarantined
from tools.ai_intelligence.ollama_provider import _notify_sentinel as notify_ollama
from tools.dashboard.pm_asset_page import _notify_sentinel as notify_dashboard
from tools.property_manager.api.auth import _notify_sentinel as notify_auth
from tools.security.allowlist import _notify_sentinel as notify_allowlist
from tools.security.sentinel import SecurityEvent, sense

_ENV_KEYS = (
    "ENVIRONMENT",
    "RANCH_SENTINEL_ENABLED",
    "RANCH_SENTINEL_TOKEN",
    "RANCH_SENTINEL_URL",
)
_SENSE_BODY = {"type": "chat.injection", "service": "telegram", "score": 1.0}


class _Response:
    def __init__(self, payload: bytes):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self._payload


class SentinelAuthTests(unittest.TestCase):
    def setUp(self):
        self._saved = {key: os.environ.get(key) for key in _ENV_KEYS}
        os.environ.pop("RANCH_SENTINEL_TOKEN", None)
        os.environ["RANCH_SENTINEL_ENABLED"] = "0"
        os.environ.pop("RANCH_SENTINEL_URL", None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _post(self, authorization: str | None = None):
        try:
            return 200, sense(SecurityEvent(**_SENSE_BODY), authorization=authorization)
        except HTTPException as exc:
            return exc.status_code, None

    def test_unconfigured_token_is_503(self):
        os.environ.pop("RANCH_SENTINEL_TOKEN", None)
        self.assertEqual(self._post()[0], 503)
        self.assertEqual(self._post("Bearer anything")[0], 503)

    def test_missing_or_invalid_token_is_401(self):
        os.environ["RANCH_SENTINEL_TOKEN"] = "sense-token"
        self.assertEqual(self._post()[0], 401)
        self.assertEqual(self._post("Bearer no")[0], 401)
        self.assertEqual(self._post("Token sense-token")[0], 401)

    def test_valid_token_is_accepted_without_writing_when_refused(self):
        os.environ["RANCH_SENTINEL_TOKEN"] = "sense-token"
        os.environ.pop("ENVIRONMENT", None)
        with patch("tools.security.sentinel._append_chain") as append:
            status, body = self._post("Bearer sense-token")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "refused")
        append.assert_not_called()

    def test_valid_token_observes_in_development(self):
        os.environ["RANCH_SENTINEL_TOKEN"] = "sense-token"
        os.environ["ENVIRONMENT"] = "development"
        with (
            patch("tools.security.sentinel._append_chain", return_value={"hash": "abc"}) as append,
            patch("tools.security.sentinel._should_isolate", return_value=False),
        ):
            status, body = self._post("Bearer sense-token")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "observed")
        self.assertEqual(body["incident_id"], "abc")
        append.assert_called_once()


class QuarantineLookupTests(unittest.TestCase):
    def setUp(self):
        self._saved = {key: os.environ.get(key) for key in _ENV_KEYS}
        os.environ["RANCH_SENTINEL_ENABLED"] = "1"
        os.environ["RANCH_SENTINEL_URL"] = "http://127.0.0.1:8001/sense"

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_disabled_lookup_stays_open(self):
        os.environ["RANCH_SENTINEL_ENABLED"] = "0"
        with patch("tools.ai_intelligence.mcp_boundary.urlopen") as opened:
            self.assertFalse(_service_quarantined("ai_intelligence_mcp"))
        opened.assert_not_called()

    def test_non_loopback_fails_closed_when_enabled(self):
        os.environ["RANCH_SENTINEL_URL"] = "http://10.0.0.8:8001/sense"
        with patch("tools.ai_intelligence.mcp_boundary.urlopen") as opened:
            self.assertTrue(_service_quarantined("ai_intelligence_mcp"))
        opened.assert_not_called()

    def test_timeout_non_200_and_invalid_json_fail_closed(self):
        with patch("tools.ai_intelligence.mcp_boundary.urlopen", side_effect=TimeoutError):
            self.assertTrue(_service_quarantined("ai_intelligence_mcp"))
        error = HTTPError(
            "http://127.0.0.1:8001/quarantine/ai_intelligence_mcp",
            503,
            "unavailable",
            hdrs=None,
            fp=BytesIO(b""),
        )
        try:
            with patch("tools.ai_intelligence.mcp_boundary.urlopen", side_effect=error):
                self.assertTrue(_service_quarantined("ai_intelligence_mcp"))
        finally:
            error.close()
        with patch(
            "tools.ai_intelligence.mcp_boundary.urlopen",
            return_value=_Response(b"not-json"),
        ):
            self.assertTrue(_service_quarantined("ai_intelligence_mcp"))

    def test_clear_quarantine_flag_is_not_quarantined(self):
        payload = json.dumps({"quarantined": False}).encode()
        with patch("tools.ai_intelligence.mcp_boundary.urlopen", return_value=_Response(payload)):
            self.assertFalse(_service_quarantined("ai_intelligence_mcp"))


class SentinelCallerHeaderTests(unittest.TestCase):
    def setUp(self):
        self._saved = {key: os.environ.get(key) for key in _ENV_KEYS}
        os.environ["RANCH_SENTINEL_ENABLED"] = "1"
        os.environ["RANCH_SENTINEL_URL"] = "http://127.0.0.1:8001/sense"
        os.environ["RANCH_SENTINEL_TOKEN"] = "sense-token"

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _assert_bearer(self, notify, target: str):
        captured: dict = {}

        def capture(request, timeout=0.5):
            captured["request"] = request
            captured["timeout"] = timeout
            raise TimeoutError

        with patch(target, side_effect=capture):
            notify({"type": "mcp.dev_bypass_attempt", "service": "test", "score": 1.0})
        request = captured["request"]
        self.assertEqual(request.get_header("Authorization"), "Bearer sense-token")
        self.assertEqual(request.get_method(), "POST")

    def test_callers_send_the_bearer_token_when_set(self):
        self._assert_bearer(notify_allowlist, "tools.security.allowlist.urlopen")
        self._assert_bearer(notify_mcp, "tools.ai_intelligence.mcp_boundary.urlopen")
        self._assert_bearer(notify_ollama, "tools.ai_intelligence.ollama_provider.urlopen")
        self._assert_bearer(notify_auth, "tools.property_manager.api.auth.urlopen")
        self._assert_bearer(notify_dashboard, "tools.dashboard.pm_asset_page.urllib.request.urlopen")


if __name__ == "__main__":
    unittest.main()
