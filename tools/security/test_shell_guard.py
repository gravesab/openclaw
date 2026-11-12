import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.security.shell_guard import allowed_url, run_checked, vet_text

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = " ; rm -rf / # "
AGENTS = [
    ROOT / "tools/watchdog/watchdog.py",
    ROOT / "tools/command_agent/command_agent.py",
    ROOT / "tools/remediation/remediation_agent.py",
    ROOT / "tools/recovery/recovery_agent.py",
    ROOT / "tools/home_manager/home_manager.py",
    ROOT / "tools/ai_summary/ai_summary_agent.py",
    ROOT / "tools/security/shell_guard.py",
]


class ShellGuardTests(unittest.TestCase):
    def setUp(self):
        self._saved = {
            key: os.environ.get(key)
            for key in (
                "RANCH_ENV",
                "RANCH_ALLOW_PRIVATE_LAN",
                "RANCH_SHELL_APPROVAL",
                "RANCH_SHELL_MODEL_DETECTOR",
                "RANCH_SENTINEL_ENABLED",
                "RANCH_HOST_ALLOWLIST",
            )
        }
        os.environ["RANCH_ENV"] = "DEV"
        os.environ["RANCH_SENTINEL_ENABLED"] = "0"
        os.environ.pop("RANCH_ALLOW_PRIVATE_LAN", None)
        os.environ.pop("RANCH_SHELL_APPROVAL", None)
        os.environ.pop("RANCH_SHELL_MODEL_DETECTOR", None)
        os.environ.pop("RANCH_HOST_ALLOWLIST", None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_loopback_hosts_and_blocks(self):
        self.assertTrue(allowed_url("http://127.0.0.1:11434", service="test"))
        self.assertTrue(allowed_url("http://[::1]:11434", service="test"))
        self.assertTrue(allowed_url("http://localhost:11434", service="test"))
        self.assertFalse(allowed_url("http://attacker.com", service="test"))
        self.assertFalse(allowed_url("http://10.0.0.1", service="test"))
        self.assertFalse(allowed_url("http://0.0.0.0", service="test"))
        os.environ["RANCH_ALLOW_PRIVATE_LAN"] = "1"
        with patch("tools.security.allowlist._note_private_lan"):
            self.assertTrue(allowed_url("http://10.0.0.1", service="test"))
            self.assertFalse(allowed_url("http://0.0.0.0", service="test"))
            self.assertFalse(allowed_url("http://attacker.com", service="test"))

    def test_injection_payload_is_not_executed(self):
        with patch("tools.security.shell_guard.subprocess.run") as run:
            self.assertEqual(run_checked(PAYLOAD, service="test"), "eject")
            self.assertEqual(run_checked([PAYLOAD], service="test"), "eject")
            self.assertEqual(vet_text(PAYLOAD, service="test"), "eject")
            run.assert_not_called()

    def test_dry_run_is_fast_and_skips_exec(self):
        run_checked(["rm", "-rf", "/"], service="warmup")
        start = time.perf_counter()
        with patch("tools.security.shell_guard.subprocess.run") as run:
            result = run_checked(
                ["docker", "restart", "homeassistant"],
                state_changing=True,
                service="timing",
            )
        elapsed = time.perf_counter() - start
        self.assertEqual(result, "dry-run: approval required")
        self.assertLess(elapsed, 0.1)
        run.assert_not_called()

    def test_timeout_env_scrub_and_cwd(self):
        os.environ["EXAMPLE_TOKEN"] = "not-a-real-secret"
        with patch("tools.security.shell_guard.subprocess.run") as run:
            run.return_value.stdout = "ok\n"
            run.return_value.stderr = ""
            run.return_value.returncode = 0
            result = run_checked(["df", "-h", "/"], timeout=90, cwd=tempfile.gettempdir(), service="test")
        self.assertEqual(result, "ok")
        kwargs = run.call_args.kwargs
        self.assertEqual(kwargs["timeout"], 30)
        self.assertFalse(kwargs["shell"])
        self.assertNotIn("EXAMPLE_TOKEN", kwargs["env"])
        self.assertEqual(kwargs["cwd"], str(Path(tempfile.gettempdir()).resolve()))
        os.environ.pop("EXAMPLE_TOKEN", None)

    def test_memory_search_sends_the_term_on_stdin(self):
        memory = ROOT / "tools" / "memory_context"
        argv = [str(memory / ".venv" / "bin" / "python3"), str(memory / "memory_context_agent.py")]
        with patch("tools.security.shell_guard.subprocess.run") as run:
            run.return_value.stdout = "hit\n"
            run.return_value.stderr = ""
            run.return_value.returncode = 0
            result = run_checked(argv, cwd=str(memory), service="test", input_text="pump repair")
        self.assertEqual(result, "hit")
        self.assertEqual(run.call_args.kwargs["input"], "pump repair\n")
        self.assertFalse(run.call_args.kwargs["shell"])

    def test_memory_search_ejects_hostile_stdin(self):
        memory = ROOT / "tools" / "memory_context"
        argv = [str(memory / ".venv" / "bin" / "python3"), str(memory / "memory_context_agent.py")]
        with patch("tools.security.shell_guard.subprocess.run") as run:
            self.assertEqual(run_checked(argv, service="test", input_text=PAYLOAD), "eject")
            self.assertEqual(run_checked(argv, service="test", input_text="a\nb"), "eject")
            run.assert_not_called()

    def test_agents_delegate_and_keep_the_shell_off(self):
        for path in AGENTS:
            text = path.read_text()
            self.assertNotIn("shell=True", text)
            if path.name == "shell_guard.py":
                self.assertIn("shell=False", text)
                self.assertIn("_is_allowed_host", text)
            else:
                self.assertIn("from tools.security.shell_guard import", text)
        watchdog = (ROOT / "tools/watchdog/watchdog.py").read_text()
        self.assertNotIn("restart", watchdog)
        recovery = (ROOT / "tools/recovery/recovery_agent.py").read_text()
        self.assertIn("_is_loopback_only", recovery)
        self.assertIn("allowed_url", recovery)


if __name__ == "__main__":
    unittest.main()
