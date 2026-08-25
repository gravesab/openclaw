from __future__ import annotations

import subprocess
import unittest
from unittest import mock

from tools.dashboard.test_scorecard_approval import dashboard


class M4SshMetricsTests(unittest.TestCase):
    def test_default_key_path_is_dedicated_to_metrics(self):
        self.assertTrue(
            dashboard.M4_SSH_KEY.endswith("/.ssh/openclaw_m4_metrics_ed25519")
        )

    def test_missing_key_is_reported_as_credentials_not_configured(self):
        result = dashboard.classify_m4_ssh_metrics_error(
            FileNotFoundError("/missing/key"),
            "/missing/key",
        )
        self.assertEqual(result["status"], "Credentials not configured")
        self.assertIn("key is missing", result["summary"])

    def test_permission_denied_is_reported_as_rejected_credentials(self):
        error = subprocess.CalledProcessError(
            255,
            ["ssh"],
            output="user@host: Permission denied (publickey).",
        )
        with mock.patch.object(dashboard.Path, "is_file", return_value=True):
            result = dashboard.classify_m4_ssh_metrics_error(error, "/configured/key")
        self.assertEqual(result["status"], "Credentials rejected")
        self.assertEqual(result["technical"], "SSH authentication failed.")

    def test_network_and_service_failures_are_distinct(self):
        with mock.patch.object(dashboard.Path, "is_file", return_value=True):
            unreachable = dashboard.classify_m4_ssh_metrics_error(
                OSError("No route to host"),
                "/configured/key",
            )
            refused = dashboard.classify_m4_ssh_metrics_error(
                OSError("Connection refused"),
                "/configured/key",
            )
        self.assertEqual(unreachable["status"], "Host unreachable")
        self.assertEqual(refused["status"], "SSH service unavailable")

    def test_panel_does_not_call_ssh_when_key_is_missing(self):
        ollama = {
            "connected": True,
            "response_ms": 3,
            "model_count": 1,
            "detected_models": "test-model",
        }
        omlx = {
            "connected": True,
            "status": "Online",
            "response_ms": 4,
            "model_count": 1,
            "detected_models": "Qwen3.5-9B-4bit",
        }
        with (
            mock.patch.object(dashboard, "M4_SSH_KEY", "/missing/key"),
            mock.patch.object(dashboard.Path, "is_file", return_value=False),
            mock.patch.object(dashboard.subprocess, "check_output") as check_output,
        ):
            html = dashboard.m4_ai_health_panel_html(ollama, omlx)
        check_output.assert_not_called()
        self.assertIn("Credentials not configured", html)
        self.assertIn("metrics key is missing", html)
        self.assertNotIn("Host unreachable", html)
        self.assertIn("oMLX API", html)
        self.assertIn("Qwen3.5-9B-4bit", html)

    def test_omlx_inventory_uses_authenticated_model_endpoint(self):
        config = dashboard.OMLXConfig("http://m4.example:8000/v1", "secret", 45)
        response = mock.Mock()
        response.json.return_value = {
            "data": [{"id": "Qwen3.5-9B-4bit"}]
        }
        dashboard.requests.get.return_value = response

        with mock.patch.object(dashboard.OMLXConfig, "from_env", return_value=config):
            result = dashboard.get_omlx_status()

        self.assertTrue(result["connected"])
        self.assertEqual(result["status"], "Online")
        self.assertEqual(result["model_count"], 1)
        dashboard.requests.get.assert_called_once_with(
            "http://m4.example:8000/v1/models",
            headers={"Authorization": "Bearer secret"},
            timeout=5,
        )
        response.raise_for_status.assert_called_once_with()

    def test_omlx_missing_credentials_does_not_probe_network(self):
        with (
            mock.patch.object(
                dashboard.OMLXConfig,
                "from_env",
                side_effect=dashboard.OMLXConfigurationError("missing key"),
            ),
            mock.patch.object(dashboard.requests, "get") as get,
        ):
            result = dashboard.get_omlx_status()

        self.assertFalse(result["connected"])
        self.assertEqual(result["status"], "Credentials not configured")
        get.assert_not_called()

    def test_omlx_request_failure_is_offline_without_exposing_details(self):
        config = dashboard.OMLXConfig("http://m4.example:8000/v1", "secret", 45)
        with (
            mock.patch.object(dashboard.OMLXConfig, "from_env", return_value=config),
            mock.patch.object(
                dashboard.requests,
                "get",
                side_effect=dashboard.requests.RequestException("connection refused"),
            ),
        ):
            result = dashboard.get_omlx_status()

        self.assertFalse(result["connected"])
        self.assertEqual(result["status"], "Offline")
        self.assertNotIn("connection refused", result["error"])

    def test_omlx_rejects_a_malformed_model_catalog(self):
        config = dashboard.OMLXConfig("http://m4.example:8000/v1", "secret", 45)
        response = mock.Mock()
        response.json.return_value = {"data": "not-a-list"}
        dashboard.requests.get.return_value = response

        with mock.patch.object(dashboard.OMLXConfig, "from_env", return_value=config):
            result = dashboard.get_omlx_status()

        self.assertFalse(result["connected"])
        self.assertEqual(result["status"], "Offline")


if __name__ == "__main__":
    unittest.main()
