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

    def test_memory_search_env_passes_vetted_ollama_only(self):
        memory = ROOT / "tools" / "memory_context"
        argv = [str(memory / ".venv" / "bin" / "python3"), str(memory / "memory_context_agent.py")]
        keys = (
            "OPENCLAW_OLLAMA_BASE_URL",
            "OPENCLAW_OLLAMA_EMBEDDINGS_URL",
            "OPENCLAW_DB_HOST",
            "OPENCLAW_DB_PASSWORD",
        )
        saved = {key: os.environ.get(key) for key in keys}
        self.addCleanup(
            lambda: [
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
                for k, v in saved.items()
            ]
        )

        def env_for() -> dict:
            with patch("tools.security.shell_guard.subprocess.run") as run:
                run.return_value.stdout = "hit\n"
                run.return_value.stderr = ""
                run.return_value.returncode = 0
                run_checked(argv, cwd=str(memory), service="test", input_text="pump repair")
            return run.call_args.kwargs["env"]

        for key in keys:
            os.environ.pop(key, None)
        env = env_for()
        self.assertEqual(env["OPENCLAW_OLLAMA_BASE_URL"], "http://127.0.0.1:11434")

        os.environ["OPENCLAW_OLLAMA_BASE_URL"] = "http://localhost:11500"
        os.environ["OPENCLAW_DB_HOST"] = "127.0.0.1"
        os.environ["OPENCLAW_DB_PASSWORD"] = "not-a-real-secret"
        env = env_for()
        self.assertEqual(env["OPENCLAW_OLLAMA_BASE_URL"], "http://localhost:11500")
        self.assertEqual(env["OPENCLAW_DB_HOST"], "127.0.0.1")
        self.assertNotIn("OPENCLAW_DB_PASSWORD", env)

        os.environ["OPENCLAW_OLLAMA_BASE_URL"] = "http://192.168.50.117:11434"
        env = env_for()
        self.assertEqual(env["OPENCLAW_OLLAMA_BASE_URL"], "http://127.0.0.1:11434")

        os.environ["OPENCLAW_DB_HOST"] = "192.168.50.20"
        self.assertNotIn("OPENCLAW_DB_HOST", env_for())
        os.environ["OPENCLAW_DB_HOST"] = "/tmp/pg-socket"
        self.assertEqual(env_for()["OPENCLAW_DB_HOST"], "/tmp/pg-socket")
        os.environ["OPENCLAW_DB_HOST"] = "127.0.0.1"

        os.environ["RANCH_HOST_ALLOWLIST"] = "192.168.50.117"
        env = env_for()
        self.assertEqual(env["OPENCLAW_OLLAMA_BASE_URL"], "http://192.168.50.117:11434")

    def test_memory_search_ejects_hostile_stdin(self):
        memory = ROOT / "tools" / "memory_context"
        argv = [str(memory / ".venv" / "bin" / "python3"), str(memory / "memory_context_agent.py")]
        with patch("tools.security.shell_guard.subprocess.run") as run:
            self.assertEqual(run_checked(argv, service="test", input_text=PAYLOAD), "eject")
            self.assertEqual(run_checked(argv, service="test", input_text="a\nb"), "eject")
            run.assert_not_called()

    def test_read_only_memory_query_runs_without_approval(self):
        query = "SELECT json_build_object('a', a)::text FROM long_term_memory ORDER BY 1 LIMIT 5"
        psql = ["postgres", "psql", "-U", "openclaw", "-d", "openclaw", "-v", "ON_ERROR_STOP=1", "-At", "-c", query]
        read_only = ["docker", "exec", "-e", "PGOPTIONS=-c default_transaction_read_only=on", *psql]
        with patch("tools.security.shell_guard.subprocess.run") as run:
            run.return_value.stdout = "{}\n"
            run.return_value.stderr = ""
            run.return_value.returncode = 0
            self.assertEqual(run_checked(read_only, service="test"), "{}")
            run.assert_called_once()
            self.assertEqual(run.call_args.args[0], read_only)
            run.reset_mock()
            # Without the read-only session the same exec stays a dry run.
            self.assertEqual(run_checked(["docker", "exec", *psql], service="test"), "dry-run: approval required")
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
