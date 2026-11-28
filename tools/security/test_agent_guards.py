"""Behavior tests: the five remaining agents go through shell_guard like the watchdog.

Each agent is driven through its real functions with subprocess, Redis, and HTTP
mocked. Audit events go to a temp chain file, never redteam_logs/security_chain.jsonl.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = " ; rm -rf / # "
_ENV_KEYS = (
    "RANCH_ENV",
    "RANCH_ALLOW_PRIVATE_LAN",
    "RANCH_SHELL_APPROVAL",
    "RANCH_SHELL_MODEL_DETECTOR",
    "RANCH_SENTINEL_ENABLED",
    "RANCH_HOST_ALLOWLIST",
)


def load(rel: str, name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AgentGuardCase(unittest.TestCase):
    def setUp(self):
        self._saved = {key: os.environ.get(key) for key in _ENV_KEYS}
        os.environ["RANCH_ENV"] = "DEV"
        os.environ["RANCH_SENTINEL_ENABLED"] = "0"
        for key in ("RANCH_ALLOW_PRIVATE_LAN", "RANCH_SHELL_APPROVAL", "RANCH_SHELL_MODEL_DETECTOR", "RANCH_HOST_ALLOWLIST"):
            os.environ.pop(key, None)
        self._tmp = tempfile.TemporaryDirectory()
        chain = patch("tools.security.allowlist._CHAIN_FILE", Path(self._tmp.name) / "chain.jsonl")
        chain.start()
        self.addCleanup(chain.stop)
        self.run_mock = patch("tools.security.shell_guard.subprocess.run").start()
        self.run_mock.return_value = subprocess.CompletedProcess([], 0, stdout="ok\n", stderr="")
        self.addCleanup(patch.stopall)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self._tmp.cleanup()

    def assert_list_argv_no_shell(self, argv):
        self.run_mock.assert_called_once()
        args, kwargs = self.run_mock.call_args
        self.assertEqual(args[0], argv)
        self.assertIs(kwargs["shell"], False)


class CommandAgentTests(AgentGuardCase):
    def setUp(self):
        super().setUp()
        self.agent = load("tools/command_agent/command_agent.py", "command_agent_under_test")
        self.agent.r = MagicMock()
        self.published = []
        self.agent.publish = lambda kind, message: self.published.append((kind, message))

    def test_injected_command_is_ejected_before_any_exec(self):
        self.agent.handle_command("restart homeassistant" + PAYLOAD)
        self.assertEqual(self.published, [("command_eject", "eject")])
        self.run_mock.assert_not_called()

    def test_restart_is_dry_run_without_approval(self):
        self.agent.handle_command("restart homeassistant")
        self.assertEqual(self.published, [("container_restart", "homeassistant: dry-run: approval required")])
        self.run_mock.assert_not_called()

    def test_sense_path_runs_list_argv(self):
        self.agent.handle_command("show docker status")
        self.assert_list_argv_no_shell(["docker", "ps", "--format", "{{.Names}} - {{.Status}}"])

    def test_shell_string_is_refused(self):
        self.assertEqual(self.agent.cmd("docker ps"), "command refused")
        self.assertEqual(self.agent.cmd("docker ps" + PAYLOAD), "eject")
        self.run_mock.assert_not_called()


class RemediationAgentTests(AgentGuardCase):
    def setUp(self):
        super().setUp()
        self.agent = load("tools/remediation/remediation_agent.py", "remediation_agent_under_test")
        self.agent.r = MagicMock()
        self.published = []
        self.agent.publish = lambda kind, message: self.published.append((kind, message))

    def test_restart_is_dry_run_without_approval(self):
        self.agent.restart_container("homeassistant")
        self.assertIn("dry-run: approval required", self.published[-1][1])
        self.run_mock.assert_not_called()

    def test_unlisted_container_is_refused_without_exec(self):
        self.agent.restart_container("postgres")
        self.assertIn("command refused", self.published[-1][1])
        self.run_mock.assert_not_called()

    def test_approved_restart_uses_list_argv(self):
        os.environ["RANCH_SHELL_APPROVAL"] = "1"
        self.agent.restart_container("scrypted")
        self.assert_list_argv_no_shell(["docker", "restart", "scrypted"])


class RecoveryAgentTests(AgentGuardCase):
    def setUp(self):
        super().setUp()
        self.agent = load("tools/recovery/recovery_agent.py", "recovery_agent_under_test")

    def test_publish_refuses_non_loopback_redis(self):
        with patch.object(self.agent, "REDIS_HOST", "10.0.0.5"), patch.object(self.agent.redis, "Redis") as client:
            self.agent.publish("recovery_incomplete", "summary")
        client.assert_not_called()

    def test_publish_uses_loopback_redis(self):
        with patch.object(self.agent.redis, "Redis") as client:
            self.agent.publish("recovery_success", "summary")
        client.assert_called_once()
        self.assertEqual(client.call_args.kwargs["host"], "127.0.0.1")

    def test_http_checks_block_other_hosts_and_redirects(self):
        with patch.object(self.agent.requests, "get") as get:
            ok, message = self.agent.check_http("Dashboard", "http://attacker.com/")
            self.assertFalse(ok)
            self.assertIn("not loopback", message)
            get.assert_not_called()
            get.return_value = MagicMock(status_code=200)
            ok, _ = self.agent.check_http("Dashboard", "http://127.0.0.1:5050")
        self.assertTrue(ok)
        self.assertIs(get.call_args.kwargs["allow_redirects"], False)

    def test_systemd_name_injection_is_refused_without_exec(self):
        ok, message = self.agent.check_systemd_service("openclaw-dashboard" + PAYLOAD)
        self.assertFalse(ok)
        self.assertIn("command refused", message)
        self.run_mock.assert_not_called()

    def test_sense_path_runs_list_argv(self):
        self.run_mock.return_value = subprocess.CompletedProcess([], 0, stdout="active\n", stderr="")
        ok, _ = self.agent.check_systemd_service("openclaw-dashboard")
        self.assertTrue(ok)
        self.assert_list_argv_no_shell(["systemctl", "is-active", "openclaw-dashboard"])


class HomeManagerTests(AgentGuardCase):
    def setUp(self):
        super().setUp()
        self.agent = load("tools/home_manager/home_manager.py", "home_manager_under_test")
        self.agent.r = MagicMock()
        self.published = []
        self.agent.publish = lambda kind, message: self.published.append((kind, message))

    def test_sense_path_runs_without_approval(self):
        self.run_mock.return_value = subprocess.CompletedProcess([], 0, stdout="Powered: yes\n", stderr="")
        self.agent.check_bluetooth()
        self.assert_list_argv_no_shell(["bluetoothctl", "show"])
        self.assertEqual(self.published[-1][0], "bluetooth_ok")

    def test_injection_and_unlisted_argv_never_run(self):
        self.assertEqual(self.agent.cmd(["docker", "ps", "--filter", "name=homeassistant" + PAYLOAD]), "eject")
        self.assertEqual(self.agent.cmd(["docker", "rm", "homeassistant"]), "command refused")
        self.run_mock.assert_not_called()

    def test_docker_error_text_is_offline(self):
        self.run_mock.return_value = subprocess.CompletedProcess(
            [], 1, stdout="", stderr="failed to connect to the docker API\n"
        )
        self.agent.check_homeassistant()
        self.agent.check_scrypted()
        self.assertEqual(
            [item[0] for item in self.published],
            ["homeassistant_offline", "scrypted_offline"],
        )

    def test_up_status_is_running_and_exited_is_offline(self):
        self.run_mock.return_value = subprocess.CompletedProcess([], 0, stdout="Up 2 hours\n", stderr="")
        self.agent.check_homeassistant()
        self.assertEqual(self.published[-1][0], "homeassistant_ok")
        self.run_mock.return_value = subprocess.CompletedProcess(
            [], 0, stdout="Exited (0) 2 days ago\n", stderr=""
        )
        self.agent.check_scrypted()
        self.assertEqual(self.published[-1][0], "scrypted_offline")
        self.run_mock.side_effect = FileNotFoundError
        self.agent.check_homeassistant()
        self.assertEqual(self.published[-1][0], "homeassistant_offline")


class AiSummaryAgentTests(AgentGuardCase):
    def setUp(self):
        super().setUp()
        self.agent = load("tools/ai_summary/ai_summary_agent.py", "ai_summary_agent_under_test")
        self.agent.r = MagicMock()
        self.agent.r.lrange.return_value = []

    def test_memory_read_is_read_only_without_approval(self):
        self.assertNotEqual(os.environ.get("RANCH_SHELL_APPROVAL"), "1")
        self.run_mock.return_value = subprocess.CompletedProcess(
            [],
            0,
            stdout='{"agent_name":"watchdog","category":"ops","content":"pump ok"}\n',
            stderr="",
        )
        self.assertEqual(self.agent.recent_memories(), "[watchdog:ops] pump ok")
        argv = self.run_mock.call_args.args[0]
        self.assertEqual(
            argv[:4],
            ["docker", "exec", "-e", "PGOPTIONS=-c default_transaction_read_only=on"],
        )
        self.assertIn("SELECT json_build_object(", argv[-1])
        self.assertNotIn("INSERT", argv[-1])

    def test_model_url_must_be_loopback(self):
        self.run_mock.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(self.agent, "OLLAMA_URL", "http://attacker.com/api/generate"), patch.object(self.agent.requests, "post") as post:
            self.assertIn("not allowlisted", self.agent.generate_summary())
        post.assert_not_called()

    def test_model_call_does_not_follow_redirects(self):
        self.run_mock.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(self.agent.requests, "post") as post:
            post.return_value.json.return_value = {"response": "all green"}
            self.assertEqual(self.agent.generate_summary(), "all green")
        self.assertIs(post.call_args.kwargs["allow_redirects"], False)


class EntryPointTests(unittest.TestCase):
    """Each agent refuses to start outside DEV, before Redis, Docker, or HTTP."""

    AGENTS = (
        "tools/command_agent/command_agent.py",
        "tools/remediation/remediation_agent.py",
        "tools/recovery/recovery_agent.py",
        "tools/home_manager/home_manager.py",
        "tools/ai_summary/ai_summary_agent.py",
    )

    def test_agents_abort_outside_dev(self):
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "LANG")}
        env.update({"RANCH_ENV": "PROD", "RANCH_SENTINEL_ENABLED": "0"})
        for rel in self.AGENTS:
            with self.subTest(agent=rel):
                done = subprocess.run(
                    [sys.executable, str(ROOT / rel)],
                    cwd=str(ROOT),
                    env=env,
                    input="",
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self.assertNotEqual(done.returncode, 0)
                self.assertIn("HARD RULE: Not DEV", done.stderr)
                # Nothing ran: no banner, no event JSON.
                self.assertNotIn("=====", done.stdout)
                self.assertNotIn('"agent"', done.stdout)


if __name__ == "__main__":
    unittest.main()
