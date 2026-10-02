#!/usr/bin/env python3
"""Operator PIN unlock contracts for the Dashboard QR asset page."""

from __future__ import annotations

import unittest
from unittest import mock

from flask import Flask

from tools.dashboard import pm_asset_page

ASSET = {"id": "asset-1", "name": "Generator", "meter": {}, "proposed_meter": {}, "tasks": []}


class PmAssetPagePinTests(unittest.TestCase):
    def _client(self, *, pin: str, secret: str):
        patches = [
            mock.patch.object(pm_asset_page, "OPERATOR_PIN", pin),
            mock.patch.object(pm_asset_page, "DASHBOARD_SECRET", secret),
            mock.patch.object(pm_asset_page, "API_KEY", ""),
            mock.patch.object(pm_asset_page, "_api_get", return_value=dict(ASSET)),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        app = Flask(__name__)
        pm_asset_page.register_pm_asset_routes(app)
        return app.test_client()

    def _unlock(self, client, pin: str) -> str:
        response = client.post("/pm/asset/qr-1", data={"action": "auth", "operator_pin": pin})
        self.assertEqual(response.status_code, 200)
        return response.get_data(as_text=True)

    def test_unconfigured_pin_rejects_former_default(self):
        client = self._client(pin="", secret="session-secret")
        body = self._unlock(client, "dev-pin")
        self.assertIn("not configured", body)
        self.assertNotIn("Authenticated", body)

    def test_missing_session_secret_disables_unlock(self):
        client = self._client(pin="configured-pin", secret="")
        body = self._unlock(client, "configured-pin")
        self.assertIn("not configured", body)
        self.assertNotIn("Authenticated", body)

    def test_configured_pin_unlocks_and_wrong_pin_does_not(self):
        client = self._client(pin="configured-pin", secret="session-secret")
        self.assertIn("Invalid operator PIN", self._unlock(client, "dev-pin"))
        self.assertIn("Authenticated", self._unlock(client, "configured-pin"))


if __name__ == "__main__":
    unittest.main()
