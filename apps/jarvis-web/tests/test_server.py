"""Tests for the Jarvis visualizer live server (isolation + adapter)."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

APP_DIR = Path(__file__).resolve().parents[1]


def load_server():
    spec = importlib.util.spec_from_file_location(
        "jarvis_web_server", APP_DIR / "server.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = load_server()
OWN = server.OWN_ENV
OTHER = "prod" if OWN == "dev" else "dev"


class LiveServerCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.httpd = ThreadingHTTPServer(
            ("127.0.0.1", 0), server.Handler
        )
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(
            target=cls.httpd.serve_forever, daemon=True
        )
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=5)

    def url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.port}{path}"

    def get(self, path: str):
        with urlopen(self.url(path)) as response:
            return (
                response.status,
                dict(response.headers),
                response.read(),
            )


class SignalApiTests(LiveServerCase):
    def test_missing_file_serves_handbook_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "nope.json")
            with patch.object(server, "SIGNAL_FILE", Path(missing)):
                status, _, body = self.get(
                    f"/api/signal?env={OWN}"
                )
        payload = json.loads(body)
        self.assertEqual(status, 200)
        self.assertTrue(payload["fixture"])
        self.assertEqual(payload["layer"], "mcp")
        self.assertEqual(
            payload["model"], "mcp boundary / property.handbook.ingest"
        )
        self.assertEqual(payload["tool"], "tasks.create")
        self.assertEqual(payload["chunks"], 127)
        self.assertEqual(payload["tasks_created"], 12)
        self.assertEqual(payload["app"], "property.handbook.ingest")
        self.assertEqual(payload["tps"], "-")
        self.assertIn("note", payload)
        self.assertEqual(payload["server_env"], OWN)

    def test_adapter_adds_env_alias(self) -> None:
        canonical = {
            "layer": "ollama",
            "model_id": "ollama-hermes3-8b",
            "tokens_per_sec": None,
            "latency_ms": 100,
            "ok": True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "layer-signal.json"
            path.write_text(json.dumps(canonical))
            with patch.object(server, "SIGNAL_FILE", path):
                _, _, body = self.get(f"/api/signal?env={OWN}")
        payload = json.loads(body)
        self.assertEqual(payload["env"], OWN)
        self.assertEqual(payload["layer"], "llama")
        self.assertEqual(payload["model"], "ollama-hermes3-8b")
        self.assertIsNone(payload["tps"])

    def test_cross_env_refused(self) -> None:
        try:
            self.get(f"/api/signal?env={OTHER}")
        except HTTPError as exc:
            self.assertEqual(exc.code, 403)
            payload = json.loads(exc.read())
            self.assertIn("blocked", payload["error"].lower())
            self.assertEqual(payload["server_env"], OWN)
        else:
            self.fail("cross-env signal request was not refused")

    def test_unknown_env_refused(self) -> None:
        try:
            self.get("/api/signal?env=staging")
        except HTTPError as exc:
            self.assertEqual(exc.code, 403)
        else:
            self.fail("unknown env was not refused")

    def test_refusal_runs_through_gate(self) -> None:
        with patch.object(
            server, "assert_policy", wraps=server.assert_policy
        ) as gate:
            try:
                self.get(f"/api/signal?env={OTHER}")
            except HTTPError as exc:
                self.assertEqual(exc.code, 403)
        gate.assert_called_once()
        args, _ = gate.call_args
        self.assertIn("100.85.", args[0])
        self.assertEqual(args[1], OWN)

    def test_canonical_record_adapted(self) -> None:
        canonical = {
            "layer": "llama.cpp",
            "model_id": "llama-cpp-qwen3.5-9b",
            "provider_name": "llama.cpp",
            "latency_ms": 1200,
            "tokens_per_sec": 40.0,
            "ok": True,
            "request_id": "r1",
            "observed_at": "2026-11-02T00:00:00+00:00",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "layer-signal.json"
            path.write_text(json.dumps(canonical))
            with patch.object(server, "SIGNAL_FILE", path):
                _, _, body = self.get(f"/api/signal?env={OWN}")
        payload = json.loads(body)
        self.assertEqual(payload["layer"], "llamacpp")
        self.assertEqual(payload["model"], "llama-cpp-qwen3.5-9b")
        self.assertEqual(payload["tps"], 40.0)
        self.assertEqual(payload["server_env"], OWN)
        self.assertEqual(payload["isolation"], "DEV→DEV / PROD→PROD")

    def test_page_shaped_record_passes_through(self) -> None:
        page = {
            "layer": "mcp",
            "model": "mcp boundary / finance.categorize",
            "tps": "-",
            "note": "Apple FM on-device finance classifier local only",
            "server_env": "wrong",
            "isolation": "wrong",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "layer-signal.json"
            path.write_text(json.dumps(page))
            with patch.object(server, "SIGNAL_FILE", path):
                _, _, body = self.get("/api/signal")
        payload = json.loads(body)
        self.assertEqual(payload["layer"], "mcp")
        self.assertEqual(payload["tps"], "-")
        # Server stays authoritative for its own env.
        self.assertEqual(payload["server_env"], OWN)
        self.assertEqual(payload["isolation"], "DEV→DEV / PROD→PROD")

    def test_corrupt_file_is_502(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "layer-signal.json"
            path.write_text("{not json")
            with patch.object(server, "SIGNAL_FILE", path):
                try:
                    self.get(f"/api/signal?env={OWN}")
                except HTTPError as exc:
                    self.assertEqual(exc.code, 502)
                else:
                    self.fail("corrupt signal file was not rejected")

    def test_no_cors_header_for_foreign_origin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "nope.json")
            with patch.object(server, "SIGNAL_FILE", Path(missing)):
                request = Request(
                    self.url("/api/signal"),
                    headers={"Origin": "https://evil.example"},
                )
                with urlopen(request) as response:
                    headers = dict(response.headers)
        ctype = {k.lower(): v for k, v in headers.items()}
        self.assertNotIn("access-control-allow-origin", ctype)


class EnvApiTests(LiveServerCase):
    def test_env_reports_own_stack(self) -> None:
        _, _, body = self.get(f"/api/env?env={OWN}")
        payload = json.loads(body)
        self.assertEqual(payload["env"], OWN)
        self.assertIn("DEV", payload["caption"])
        if OWN == "dev":
            self.assertIn("fixture", payload["caption"])
        self.assertEqual(payload["isolation"], "DEV→DEV / PROD→PROD")
        self.assertIn("signal_exists", payload)
        self.assertIn(payload["gate_source"], ("sibling", "repo", "fallback"))

    def test_repo_gate_loads_from_checkout(self) -> None:
        # Regression: parents[1] pointed at apps/ and fell back silently.
        self.assertIn(server.GATE_SOURCE, ("sibling", "repo"))

    def test_default_bind_is_loopback(self) -> None:
        self.assertEqual(server.BIND_HOST, "127.0.0.1")

    def test_env_cross_refused(self) -> None:
        try:
            self.get(f"/api/env?env={OTHER}")
        except HTTPError as exc:
            self.assertEqual(exc.code, 403)
        else:
            self.fail("cross-env env request was not refused")


class TmpStaticTests(LiveServerCase):
    def test_serves_signal_file_under_tmp(self) -> None:
        target = Path("/tmp") / "viz-probe-signal.json"
        target.write_text('{"probe": true}')
        self.addCleanup(lambda: target.unlink(missing_ok=True))
        with patch.object(server, "SIGNAL_FILE", target):
            status, headers, body = self.get(f"/tmp/{target.name}")
        ctype = {k.lower(): v for k, v in headers.items()}
        self.assertEqual(status, 200)
        self.assertEqual(ctype["content-type"], "application/json")
        self.assertEqual(json.loads(body), {"probe": True})

    def test_refuses_other_tmp_files(self) -> None:
        planted = Path("/tmp") / "viz-probe-planted.html"
        other = Path("/tmp") / "viz-probe-other.json"
        planted.write_text("<script>alert(1)</script>")
        other.write_text("{}")
        self.addCleanup(lambda: planted.unlink(missing_ok=True))
        self.addCleanup(lambda: other.unlink(missing_ok=True))
        signal = Path("/tmp") / "viz-probe-signal.json"
        with patch.object(server, "SIGNAL_FILE", signal):
            for path in (
                f"/tmp/{planted.name}",
                f"/tmp/{other.name}",
                f"/tmp/../{signal.name}",
                "/tmp/.hidden.json",
                "/tmp/",
            ):
                try:
                    self.get(path)
                except HTTPError as exc:
                    self.assertEqual(exc.code, 404, path)
                else:
                    self.fail(f"{path} was served")


class RootTests(LiveServerCase):
    def test_root_serves_page(self) -> None:
        status, headers, body = self.get("/")
        ctype = {k.lower(): v for k, v in headers.items()}
        self.assertEqual(status, 200)
        self.assertIn("text/html", ctype["content-type"])
        self.assertTrue(len(body) > 1000)


if __name__ == "__main__":
    unittest.main()
