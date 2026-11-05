#!/usr/bin/env python3
"""Standalone PropertyManager API client scripts use /v1 paths and credentials.

These scripts called unprefixed /assets routes (404) without credentials; reads
now require the API key or operator PIN (GAP_ANALYSIS.md P0-3). urlopen is
stubbed: no request leaves the test process.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
METER_SCRIPT = REPO_ROOT / "tools" / "property_manager" / "propertymanager-meter.py"
QR_SCRIPT = REPO_ROOT / "tools" / "property_manager" / "generate_asset_qr.py"
SHOW_ASSET = REPO_ROOT / "ranchbrain" / "src" / "ranchbrain" / "show_asset.py"
ASSET = {"id": "a-1", "name": "DR Mower", "external_id": "EQ-1", "meter": {"unit": "hours"}, "qr_token": "tok"}


class _Resp:
    def __init__(self, body, status=200):
        self._body = json.dumps(body).encode()
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self._body


def _load(path: Path, name: str, env: dict[str, str], argv: list[str] | None = None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(sys, "argv", argv or [str(path)]):
        try:
            spec.loader.exec_module(module)
        except SystemExit:
            # show_asset.py runs as a script at import and exits without a query;
            # the functions defined before that point remain usable.
            pass
    return module


def _no_creds_env() -> dict[str, str]:
    return {"PROPERTYMANAGER_API_KEY": "", "PROPERTYMANAGER_OPERATOR_PIN": "", "PROPERTYMANAGER_API_BASE": "http://pm.invalid:5062"}


class MeterScriptTests(unittest.TestCase):
    def test_reads_and_posts_v1_with_key_and_idempotency(self):
        meter = _load(METER_SCRIPT, "pm_meter", {**_no_creds_env(), "PROPERTYMANAGER_API_KEY": "k"})
        seen = []

        def fake_urlopen(req, timeout=None):
            seen.append(req)
            return _Resp([ASSET]) if req.get_method() == "GET" else _Resp({"ok": True}, 201)

        with mock.patch.object(meter.urllib.request, "urlopen", side_effect=fake_urlopen), \
             mock.patch.object(sys, "argv", ["meter", "dr mower 127.4 hours"]), redirect_stdout(io.StringIO()):
            self.assertEqual(meter.main(), 0)
        get, post = seen
        self.assertEqual(get.full_url, "http://pm.invalid:5062/v1/assets")
        self.assertEqual(post.full_url, "http://pm.invalid:5062/v1/assets/a-1/meter-readings")
        for req in seen:
            self.assertEqual(req.get_header("Authorization"), "Bearer k")
        self.assertTrue(post.get_header("Idempotency-key"))

    def test_missing_credentials_exit_2_without_request(self):
        meter = _load(METER_SCRIPT, "pm_meter_nocreds", _no_creds_env())
        with mock.patch.object(meter.urllib.request, "urlopen") as urlopen, \
             mock.patch.object(sys, "argv", ["meter", "dr mower 127.4 hours"]), redirect_stdout(io.StringIO()) as out:
            self.assertEqual(meter.main(), 2)
        urlopen.assert_not_called()
        self.assertIn("credentials are not configured", out.getvalue())

    def test_pin_is_accepted(self):
        meter = _load(METER_SCRIPT, "pm_meter_pin", {**_no_creds_env(), "PROPERTYMANAGER_OPERATOR_PIN": "1234"})
        self.assertEqual(meter.auth_headers().get("X-Operator-PIN"), "1234")


class QrScriptTests(unittest.TestCase):
    def test_fetch_assets_uses_v1_and_key(self):
        qr = _load(QR_SCRIPT, "pm_qr", {**_no_creds_env(), "PROPERTYMANAGER_API_KEY": "k"})
        with mock.patch.dict(os.environ, {"PROPERTYMANAGER_API_KEY": "k"}), \
             mock.patch.object(qr.urllib.request, "urlopen", return_value=_Resp([ASSET])) as urlopen:
            self.assertEqual(qr.fetch_assets("http://pm.invalid:5062"), [ASSET])
        req = urlopen.call_args.args[0]
        self.assertEqual(req.full_url, "http://pm.invalid:5062/v1/assets")
        self.assertEqual(req.get_header("Authorization"), "Bearer k")

    def test_missing_credentials_stop_before_request(self):
        qr = _load(QR_SCRIPT, "pm_qr_nocreds", _no_creds_env())
        with mock.patch.dict(os.environ, _no_creds_env()), \
             mock.patch.object(qr.urllib.request, "urlopen") as urlopen, self.assertRaises(SystemExit):
            qr.fetch_assets("http://pm.invalid:5062")
        urlopen.assert_not_called()


class ShowAssetTests(unittest.TestCase):
    def test_fetch_uses_v1_quoted_path_and_key(self):
        show = _load(SHOW_ASSET, "rb_show_asset", {**_no_creds_env(), "PROPERTYMANAGER_API_KEY": "k"}, ["show_asset.py"])
        with mock.patch.dict(os.environ, {"PROPERTYMANAGER_API_KEY": "k"}), \
             mock.patch.object(show.urllib.request, "urlopen", return_value=_Resp(ASSET)) as urlopen:
            self.assertEqual(show.fetch_pm_asset("EQ 1/x"), ASSET)
        req = urlopen.call_args.args[0]
        self.assertEqual(req.full_url, "http://pm.invalid:5062/v1/assets/by-external-id/EQ%201%2Fx")
        self.assertEqual(req.get_header("Authorization"), "Bearer k")

    def test_without_credentials_skips_request(self):
        show = _load(SHOW_ASSET, "rb_show_asset_nocreds", _no_creds_env(), ["show_asset.py"])
        with mock.patch.dict(os.environ, _no_creds_env()), \
             mock.patch.object(show.urllib.request, "urlopen") as urlopen:
            self.assertIsNone(show.fetch_pm_asset("EQ-1"))
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
