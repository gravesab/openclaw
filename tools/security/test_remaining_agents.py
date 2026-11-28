"""shell_guard coverage for the five agents after the watchdog."""

import os
import subprocess
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = " ; rm -rf / # "
AGENTS = (
    "tools/command_agent/command_agent.py",
    "tools/remediation/remediation_agent.py",
    "tools/recovery/recovery_agent.py",
    "tools/home_manager/home_manager.py",
    "tools/ai_summary/ai_summary_agent.py",
)


class RemainingAgentShellTests(unittest.TestCase):
    def setUp(self):
        self._saved = {
            key: os.environ.get(key)
            for key in (
                "RANCH_ENV",
                "RANCH_ALLOW_PRIVATE_LAN",
                "RANCH_SHELL_APPROVAL",
                "RANCH_SENTINEL_ENABLED",
                "RANCH_HOST_ALLOWLIST",
            )
        }
        os.environ["RANCH_ENV"] = "DEV"
        os.environ["RANCH_SENTINEL_ENABLED"] = "0"
        os.environ.pop("RANCH_ALLOW_PRIVATE_LAN", None)
        os.environ.pop("RANCH_SHELL_APPROVAL", None)
        os.environ.pop("RANCH_HOST_ALLOWLIST", None)
        from tools.ai_summary import ai_summary_agent
        from tools.command_agent import command_agent
        from tools.home_manager import home_manager
        from tools.recovery import recovery_agent
        from tools.remediation import remediation_agent

        self.command = command_agent
        self.remediation = remediation_agent
        self.recovery = recovery_agent
        self.home = home_manager
        self.summary = ai_summary_agent
        from tools.security.shell_guard import enforce_dev

        enforce_dev()
        self._hosts = (
            self.command.REDIS_HOST,
            self.remediation.REDIS_HOST,
            self.recovery.REDIS_HOST,
            self.recovery.POSTGRES_DB["host"],
            self.home.REDIS_HOST,
            self.summary.REDIS_HOST,
            self.summary.OLLAMA_URL,
        )

    def tearDown(self):
        (
            self.command.REDIS_HOST,
            self.remediation.REDIS_HOST,
            self.recovery.REDIS_HOST,
            self.recovery.POSTGRES_DB["host"],
            self.home.REDIS_HOST,
            self.summary.REDIS_HOST,
            self.summary.OLLAMA_URL,
        ) = self._hosts
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_source_has_no_direct_shell(self):
        for relative in AGENTS:
            text = (ROOT / relative).read_text()
            self.assertIn("enforce_dev()", text, relative)
            self.assertIn("_is_allowed_host", text, relative)
            self.assertIn("run_checked", text, relative)
            self.assertNotIn("shell=True", text, relative)
            self.assertNotIn("os.system", text, relative)
            self.assertNotIn("os.popen", text, relative)
            self.assertNotIn("subprocess", text, relative)

    def test_shell_string_is_refused(self):
        with patch("tools.security.shell_guard.subprocess.run") as run:
            self.assertEqual(self.command.cmd("docker ps"), "command refused")
            self.assertEqual(self.remediation.cmd("docker ps"), "command refused")
            self.assertEqual(self.recovery.run_cmd("docker ps"), "command refused")
            self.assertEqual(self.home.cmd("docker ps"), "command refused")
            self.assertEqual(self.summary.cmd("docker ps"), "command refused")
            run.assert_not_called()

    def test_injection_is_ejected(self):
        with patch("tools.security.shell_guard.subprocess.run") as run:
            for agent_cmd in (
                self.command.cmd,
                self.remediation.cmd,
                self.recovery.run_cmd,
                self.home.cmd,
                self.summary.cmd,
            ):
                self.assertEqual(agent_cmd(PAYLOAD), "eject")
                self.assertEqual(agent_cmd([PAYLOAD]), "eject")
            with patch.object(self.command, "_redis_client", return_value=None):
                self.command.handle_command(PAYLOAD)
            run.assert_not_called()

    def test_state_change_refused_without_approval(self):
        self.assertNotEqual(os.environ.get("RANCH_SHELL_APPROVAL"), "1")
        started = time.perf_counter()
        with patch("tools.security.shell_guard.subprocess.run") as run:
            with patch.object(self.command, "_redis_client", return_value=None):
                self.command.restart_container("homeassistant")
            with patch.object(self.remediation, "_redis_client", return_value=None):
                self.remediation.restart_container("scrypted")
            self.assertEqual(
                self.recovery.run_cmd(["docker", "restart", "homeassistant"]),
                "dry-run: approval required",
            )
            self.assertEqual(
                self.home.cmd(["docker", "restart", "homeassistant"]),
                "dry-run: approval required",
            )
            run.assert_not_called()
            run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
            self.assertEqual(self.summary.recent_memories(), "")
            argv = run.call_args.args[0]
            self.assertEqual(argv[2], "-e")
            self.assertEqual(argv[3], "PGOPTIONS=-c default_transaction_read_only=on")
        self.assertLess(time.perf_counter() - started, 0.1)

    def test_non_loopback_host_is_blocked(self):
        blocked = ("attacker.com", "10.0.0.1", "0.0.0.0")
        for host in blocked:
            for agent in (self.command, self.remediation, self.home, self.summary):
                agent.REDIS_HOST = host
                with patch.object(agent.redis, "Redis") as client:
                    self.assertIsNone(agent._redis_client(), host)
                client.assert_not_called()
            self.recovery.REDIS_HOST = host
            self.recovery.POSTGRES_DB["host"] = host
            with patch.object(self.recovery.redis, "Redis") as client, patch.object(
                self.recovery.psycopg2, "connect"
            ) as connect, patch.object(self.recovery.requests, "get") as get:
                ok, _message = self.recovery.check_redis()
                self.assertFalse(ok, host)
                db_ok, _db_message = self.recovery.check_postgres()
                self.assertFalse(db_ok, host)
                http_ok, _http_message = self.recovery.check_http("Dashboard", f"http://{host}")
                self.assertFalse(http_ok, host)
                self.recovery.publish("recovery_incomplete", "proof")
            client.assert_not_called()
            connect.assert_not_called()
            get.assert_not_called()
        self.recovery.REDIS_HOST = "localhost"
        with patch.object(self.recovery.redis, "Redis") as client:
            ok, _message = self.recovery.check_redis()
            self.assertFalse(ok)
            self.recovery.publish("recovery_incomplete", "proof")
        client.assert_not_called()

        os.environ["RANCH_ALLOW_PRIVATE_LAN"] = "1"
        self.command.REDIS_HOST = "10.0.0.1"
        with patch.object(self.command.redis, "Redis") as client:
            self.assertIsNone(self.command._redis_client())
        client.assert_not_called()
        self.recovery.REDIS_HOST = "0.0.0.0"
        with patch.object(self.recovery.redis, "Redis") as client, patch.object(
            self.recovery.requests, "get"
        ) as get:
            ok, _message = self.recovery.check_redis()
            self.assertFalse(ok)
            http_ok, _http_message = self.recovery.check_http("Dashboard", "http://0.0.0.0")
            self.assertFalse(http_ok)
            lane_ok, _lane_message = self.recovery.check_http("Dashboard", "http://10.0.0.1")
            self.assertFalse(lane_ok)
        client.assert_not_called()
        get.assert_not_called()

        self.summary.OLLAMA_URL = "http://attacker.com/api/generate"
        with patch.object(self.summary, "infrastructure_status", return_value="up"), patch.object(
            self.summary, "recent_events", return_value=""
        ), patch.object(self.summary, "recent_memories", return_value=""), patch.object(
            self.summary.requests, "post"
        ) as post:
            self.assertEqual(
                self.summary.generate_summary(),
                "summary refused: model URL is not allowlisted",
            )
        post.assert_not_called()
        self.summary.OLLAMA_URL = "http://0.0.0.0:11434/api/generate"
        with patch.object(self.summary, "infrastructure_status", return_value="up"), patch.object(
            self.summary, "recent_events", return_value=""
        ), patch.object(self.summary, "recent_memories", return_value=""), patch.object(
            self.summary.requests, "post"
        ) as post:
            self.assertEqual(
                self.summary.generate_summary(),
                "summary refused: model URL is not allowlisted",
            )
        post.assert_not_called()
        self.summary.OLLAMA_URL = "http://10.0.0.1:11434/api/generate"
        with patch("tools.security.allowlist._note_private_lan"), patch.object(
            self.summary, "infrastructure_status", return_value="up"
        ), patch.object(self.summary, "recent_events", return_value=""), patch.object(
            self.summary, "recent_memories", return_value=""
        ), patch.object(self.summary.requests, "post") as post:
            post.return_value.raise_for_status.return_value = None
            post.return_value.json.return_value = {"response": "summarized"}
            self.assertEqual(self.summary.generate_summary(), "summarized")
        post.assert_called_once()


if __name__ == "__main__":
    unittest.main()
