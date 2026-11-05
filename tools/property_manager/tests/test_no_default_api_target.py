#!/usr/bin/env python3
"""DEV tools must not silently target a default (formerly PROD) API host.

Each tool is run as a subprocess with a stub ``curl`` on PATH and a temporary
HOME, so no network request leaves the test process.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PM_DIR = REPO_ROOT / "tools" / "property_manager"
SAVE_SCRIPT = PM_DIR / "db" / "save_mac_cache_to_api.sh"
REFRESH_SCRIPT = PM_DIR / "db" / "refresh_mac_cache_from_api.sh"
QR_SCRIPT = PM_DIR / "generate_asset_qr.py"

# Records every invocation and returns an empty JSON list for any URL.
STUB_CURL = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "${CURL_CALLS_FILE}"
printf '[]'
"""


class _ScriptHarness(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.home = self.root / "home"
        self.app_support = self.home / "Library" / "Application Support" / "PropertyManagerApp"
        self.app_support.mkdir(parents=True)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text(STUB_CURL, encoding="utf-8")
        curl.chmod(0o755)
        self.calls = self.root / "curl_calls.txt"
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(self.home),
            "CURL_CALLS_FILE": str(self.calls),
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_script(self, script: Path, **extra_env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(script)],
            env={**self.env, **extra_env},
            capture_output=True,
            text=True,
            timeout=60,
        )

    def curl_calls(self) -> list[str]:
        if not self.calls.exists():
            return []
        return self.calls.read_text(encoding="utf-8").splitlines()


class CacheScriptTargetTests(_ScriptHarness):
    def test_save_refuses_without_explicit_target(self) -> None:
        (self.app_support / "maintenance_tasks.json").write_text("[]", encoding="utf-8")
        result = self.run_script(SAVE_SCRIPT)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("PROPERTYMANAGER_API_BASE is not set", result.stderr)
        self.assertEqual(self.curl_calls(), [])

    def test_refresh_refuses_without_explicit_target(self) -> None:
        result = self.run_script(REFRESH_SCRIPT)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("PROPERTYMANAGER_API_BASE is not set", result.stderr)
        self.assertEqual(self.curl_calls(), [])
        self.assertFalse((self.app_support / "maintenance_tasks.json").exists())

    def test_empty_target_is_treated_as_unset(self) -> None:
        result = self.run_script(REFRESH_SCRIPT, PROPERTYMANAGER_API_BASE="")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.curl_calls(), [])

    def test_save_uses_only_the_named_target(self) -> None:
        (self.app_support / "maintenance_tasks.json").write_text("[]", encoding="utf-8")
        base = "http://dev-api.invalid:5062"
        result = self.run_script(SAVE_SCRIPT, PROPERTYMANAGER_API_BASE=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.curl_calls()
        self.assertEqual(calls, [f"-fsS {base}/health"])

    def test_refresh_uses_only_the_named_target(self) -> None:
        base = "http://dev-api.invalid:5062"
        result = self.run_script(REFRESH_SCRIPT, PROPERTYMANAGER_API_BASE=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.curl_calls()
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(f" {base}/" in f" {call}" for call in calls), calls)
        written = json.loads((self.app_support / "maintenance_tasks.json").read_text(encoding="utf-8"))
        self.assertEqual(written, [])


class AssetQrTargetTests(unittest.TestCase):
    def test_dashboard_base_is_required(self) -> None:
        # --api points at a closed local port; argparse must fail before any fetch.
        result = subprocess.run(
            [sys.executable, str(QR_SCRIPT), "--api", "http://127.0.0.1:9"],
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--dashboard-base", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
