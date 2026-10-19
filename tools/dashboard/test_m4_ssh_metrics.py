from __future__ import annotations

import csv
import subprocess
import tempfile
import unittest
from pathlib import Path
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
        llama_cpp = {
            "connected": True,
            "status": "Online",
            "response_ms": 6,
            "model_count": 1,
            "detected_models": "qwen3.5-9b",
        }
        with (
            mock.patch.object(dashboard, "M4_SSH_KEY", "/missing/key"),
            mock.patch.object(dashboard.Path, "is_file", return_value=False),
            mock.patch.object(dashboard.subprocess, "check_output") as check_output,
        ):
            html = dashboard.m4_ai_health_panel_html(ollama, omlx, llama_cpp)
        check_output.assert_not_called()
        self.assertIn("Credentials not configured", html)
        self.assertIn("metrics key is missing", html)
        self.assertNotIn("Host unreachable", html)
        self.assertIn("oMLX API", html)
        self.assertIn("Qwen3.5-9B-4bit", html)
        self.assertIn("llama.cpp", html)
        self.assertIn("qwen3.5-9b", html)
        self.assertIn("Intel Mini AI Server Health", html)
        self.assertNotIn("M4 AI Server Health", html)

    def test_trend_charts_follow_intel_mini_metrics_after_the_m4_move(self):
        header = (
            "timestamp,ollama_latency_ms,mem_used_gib,mem_total_gib,"
            "disk_used_pct,external_disk_used_pct,m4_mem_used_gib,"
            "m4_cpu_used_pct,m4_disk_used_pct,m4_ollama_response_ms"
        )
        row = "2026-10-05 16:01:00,,16,62,51,3,,,,"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trend = root / "trends.csv"
            graphs = root / "graphs"
            trend.write_text(f"{header}\n{row}\n", encoding="utf-8")

            class _Frame:
                def set_facecolor(self, *_args, **_kwargs):
                    return None

                def set_edgecolor(self, *_args, **_kwargs):
                    return None

            class _Legend:
                def get_texts(self):
                    return []

                def get_frame(self):
                    return _Frame()

            class _Spine:
                def set_color(self, *_args, **_kwargs):
                    return None

            class _Axis:
                spines = {"left": _Spine()}

                def set_facecolor(self, *_args, **_kwargs):
                    return None

                def plot(self, *_args, **_kwargs):
                    return None

                def set_title(self, *_args, **_kwargs):
                    return None

                def set_xlabel(self, *_args, **_kwargs):
                    return None

                def set_ylabel(self, *_args, **_kwargs):
                    return None

                def set_ylim(self, *_args, **_kwargs):
                    return None

                def grid(self, *_args, **_kwargs):
                    return None

                def tick_params(self, *_args, **_kwargs):
                    return None

                def legend(self, *_args, **_kwargs):
                    return _Legend()

            class _Plot:
                def figure(self, *_args, **_kwargs):
                    return None

                def gca(self):
                    return _Axis()

                def tight_layout(self):
                    return None

                def savefig(self, *_args, **_kwargs):
                    return None

                def close(self):
                    return None

            with (
                mock.patch.object(dashboard, "TREND_FILE", trend),
                mock.patch.object(dashboard, "GRAPH_DIR", graphs),
                mock.patch.object(dashboard, "plt", _Plot()),
                mock.patch.object(
                    dashboard, "load_intelmini_host_trend_rows", return_value=None
                ),
            ):
                files = dashboard.generate_trend_charts()
        self.assertEqual(
            files,
            [
                "memory_usage.png",
                "intelmini_disk_usage.png",
            ],
        )

    def test_guest_samples_chart_the_intel_mini_host_and_the_m4(self):
        header = (
            "timestamp,ollama_latency_ms,mem_used_gib,mem_total_gib,"
            "disk_used_pct,external_disk_used_pct,m4_mem_used_gib,"
            "m4_cpu_used_pct,m4_disk_used_pct,m4_ollama_response_ms"
        )
        guest = "2026-10-05 23:37:09,,2,7,26,3,,,,"
        host = "2026-10-05 19:00:59,30,16,62,51,3,23.7,24.1,51,26"
        plotted = []

        class _Frame:
            def set_facecolor(self, *_args, **_kwargs):
                return None

            def set_edgecolor(self, *_args, **_kwargs):
                return None

        class _Legend:
            def get_texts(self):
                return []

            def get_frame(self):
                return _Frame()

        class _Spine:
            def set_color(self, *_args, **_kwargs):
                return None

        class _Axis:
            spines = {"left": _Spine()}

            def set_facecolor(self, *_args, **_kwargs):
                return None

            def plot(self, _labels, _values, *_args, **kwargs):
                plotted.append(kwargs.get("label"))

            def set_title(self, *_args, **_kwargs):
                return None

            def set_xlabel(self, *_args, **_kwargs):
                return None

            def set_ylabel(self, *_args, **_kwargs):
                return None

            def set_ylim(self, *_args, **_kwargs):
                return None

            def grid(self, *_args, **_kwargs):
                return None

            def tick_params(self, *_args, **_kwargs):
                return None

            def legend(self, *_args, **_kwargs):
                return _Legend()

        class _Plot:
            def figure(self, *_args, **_kwargs):
                return None

            def gca(self):
                return _Axis()

            def tight_layout(self):
                return None

            def savefig(self, *_args, **_kwargs):
                return None

            def close(self):
                return None

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trend = root / "trends.csv"
            trend.write_text(f"{header}\n{guest}\n", encoding="utf-8")
            host_rows = list(csv.DictReader([header, host]))
            with (
                mock.patch.object(dashboard, "TREND_FILE", trend),
                mock.patch.object(dashboard, "GRAPH_DIR", root / "graphs"),
                mock.patch.object(dashboard, "plt", _Plot()),
                mock.patch.object(
                    dashboard,
                    "load_intelmini_host_trend_rows",
                    return_value=host_rows,
                ),
            ):
                files = dashboard.generate_trend_charts()

        self.assertEqual(
            files,
            [
                "ollama_latency.png",
                "memory_usage.png",
                "intelmini_disk_usage.png",
                "m4_cpu_usage.png",
            ],
        )
        self.assertEqual(
            plotted,
            [
                "Intel Mini",
                "M4",
                "Intel Mini",
                "M4",
                "Intel Mini internal",
                "Intel Mini external",
                "M4",
                "M4",
            ],
        )

    def test_omlx_inventory_uses_authenticated_model_endpoint(self):
        config = dashboard.OMLXConfig("http://m4.example:8000/v1", "secret", 45)
        response = mock.Mock()
        response.json.return_value = {
            "data": [{"id": "Qwen3.5-9B-4bit"}]
        }
        dashboard.requests.get.reset_mock()
        dashboard.requests.get.side_effect = None
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

    def test_llama_cpp_inventory_uses_configured_model_endpoint(self):
        response = mock.Mock()
        response.json.return_value = {"data": [{"id": "qwen3.5-9b"}]}
        dashboard.requests.get.reset_mock()
        dashboard.requests.get.side_effect = None
        dashboard.requests.get.return_value = response

        with mock.patch.dict(
            dashboard.os.environ,
            {"OPENCLAW_LLAMA_CPP_BASE_URL": "http://127.0.0.1:18088/v1"},
            clear=False,
        ):
            result = dashboard.get_llama_cpp_status()

        self.assertTrue(result["connected"])
        self.assertEqual(result["status"], "Online")
        self.assertEqual(result["model_count"], 1)
        self.assertEqual(result["detected_models"], "qwen3.5-9b")
        dashboard.requests.get.assert_called_once_with(
            "http://127.0.0.1:18088/v1/models",
            timeout=5,
        )
        response.raise_for_status.assert_called_once_with()

    def test_llama_cpp_request_failure_is_offline_without_exposing_details(self):
        with (
            mock.patch.dict(
                dashboard.os.environ,
                {"OPENCLAW_LLAMA_CPP_BASE_URL": "http://127.0.0.1:18088/v1"},
                clear=False,
            ),
            mock.patch.object(
                dashboard.requests,
                "get",
                side_effect=dashboard.requests.RequestException("connection refused"),
            ),
        ):
            result = dashboard.get_llama_cpp_status()

        self.assertFalse(result["connected"])
        self.assertEqual(result["status"], "Offline")
        self.assertNotIn("connection refused", result["error"])

    def test_llama_cpp_rejects_a_malformed_model_catalog(self):
        response = mock.Mock()
        response.json.return_value = {"data": "not-a-list"}
        dashboard.requests.get.reset_mock()
        dashboard.requests.get.side_effect = None
        dashboard.requests.get.return_value = response

        with mock.patch.dict(
            dashboard.os.environ,
            {"OPENCLAW_LLAMA_CPP_BASE_URL": "http://llama.example:18088/v1/"},
            clear=False,
        ):
            result = dashboard.get_llama_cpp_status()

        self.assertFalse(result["connected"])
        self.assertEqual(result["status"], "Offline")
        dashboard.requests.get.assert_called_once_with(
            "http://llama.example:18088/v1/models",
            timeout=5,
        )


if __name__ == "__main__":
    unittest.main()
