import os
import time
import unittest
from unittest.mock import patch

from tools.security.actuator import freeze_memory_writes, pause_container, revoke_tokens
from tools.security.allowlist import _is_allowed_host, _is_loopback_only
from tools.security.sentinel import health
from tools.security.shell_guard import run_checked
from tools.watchdog.watchdog import publish


class WatchdogFixTests(unittest.TestCase):
    def setUp(self):
        self._saved = {
            key: os.environ.get(key)
            for key in (
                "RANCH_ENV",
                "RANCH_ALLOW_PRIVATE_LAN",
                "RANCH_SHELL_APPROVAL",
                "RANCH_SENTINEL_DRY_RUN",
                "RANCH_ACTUATOR_PAUSE",
                "RANCH_ACTUATOR_REVOKE",
                "ENVIRONMENT",
                "RANCH_HOST_ALLOWLIST",
            )
        }
        os.environ["RANCH_ENV"] = "DEV"
        os.environ.pop("RANCH_ALLOW_PRIVATE_LAN", None)
        os.environ.pop("RANCH_SHELL_APPROVAL", None)
        os.environ.pop("RANCH_HOST_ALLOWLIST", None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_hosts(self):
        self.assertTrue(_is_loopback_only("127.0.0.1"))
        self.assertTrue(_is_loopback_only("::1"))
        self.assertTrue(_is_loopback_only("localhost"))
        self.assertFalse(_is_loopback_only("0.0.0.0"))
        self.assertFalse(_is_loopback_only("10.0.0.1"))
        self.assertTrue(_is_allowed_host("127.0.0.1", service="watchdog-test"))
        self.assertFalse(_is_allowed_host("attacker.com", service="watchdog-test"))
        self.assertFalse(_is_allowed_host("0.0.0.0", service="watchdog-test"))
        self.assertFalse(_is_allowed_host("10.0.0.1", service="watchdog-test"))
        self.assertFalse(_is_allowed_host("172.17.0.1", service="watchdog-test"))
        self.assertFalse(_is_allowed_host("192.168.50.117", service="watchdog-test"))
        os.environ["RANCH_ALLOW_PRIVATE_LAN"] = "1"
        with patch("tools.security.allowlist._note_private_lan"):
            self.assertTrue(_is_allowed_host("10.0.0.1", service="watchdog-test"))
            self.assertFalse(_is_allowed_host("0.0.0.0", service="watchdog-test"))
            self.assertFalse(_is_allowed_host("attacker.com", service="watchdog-test"))

    def test_publish_survives_a_down_redis(self):
        publish("WatchdogAgent", "service_alert", "redis dry-run", None)

    def test_isolation_without_approval_is_fast(self):
        os.environ["ENVIRONMENT"] = "development"
        os.environ["RANCH_SENTINEL_DRY_RUN"] = "0"
        os.environ["RANCH_ACTUATOR_PAUSE"] = "1"
        os.environ["RANCH_ACTUATOR_REVOKE"] = "1"
        started = time.perf_counter()
        with patch("tools.security.actuator.subprocess.run") as run:
            self.assertFalse(pause_container("homeassistant"))
            self.assertEqual(revoke_tokens("proof-tenant"), 0)
            freeze_memory_writes()
        elapsed = time.perf_counter() - started
        self.assertLess(elapsed, 0.1)
        run.assert_not_called()

    def test_missing_binary_does_not_raise(self):
        with patch("tools.security.shell_guard.subprocess.run", side_effect=FileNotFoundError):
            self.assertEqual(run_checked(["free", "-h"], service="test"), "command refused")

    def test_health_names_loopback(self):
        body = health()
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["bind"], "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
