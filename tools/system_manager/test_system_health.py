import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import system_health as health


class HealthTests(unittest.TestCase):
    def test_backup_cadences_and_future(self):
        now = 2_000_000_000
        self.assertTrue(health.backup_label(now - 3 * 86400, now, 8 * 86400).startswith("Current"))
        self.assertTrue(health.backup_label(now - 3 * 86400, now, 2 * 86400).startswith("Overdue"))
        self.assertEqual(health.backup_label(now + 3600, now, 86400), "Unknown")
        self.assertEqual(health.backup_label(None, now, 86400), "Unknown")

    def test_backup_success_is_not_watchdog_ok(self):
        rows = [(100, "OpenClaw backup watchdog OK."), (90, "Automatic backup status: completed")]
        self.assertEqual(health.last_matching(rows, "Automatic backup status: completed"), 90)

    def test_inaccessible_inputs_are_not_healthy(self):
        with patch.object(health, "run", return_value=None), patch.object(health, "journal", return_value=None):
            text = health.collect(now=2_000_000_000)["text"]
        self.assertIn("Attention", text)
        self.assertIn("Production backup: Unknown", text)
        self.assertIn("DEV backup: Unknown", text)
        self.assertNotIn("Problems: None", text)

    def test_prod_ignores_stale_dev_feed(self):
        now = 2_000_000_000
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "dev-observations.json").write_text(json.dumps({
                "checked_epoch": now - 901,
                "values": {"dev_gateway": "running healthy"},
            }))
            with patch.object(health, "STATE", state), patch.object(health, "ENVIRONMENT", "prod"), \
                    patch.object(health, "run", return_value=None), patch.object(health, "journal", return_value=None):
                text = health.collect(now)["text"]
        self.assertIn("DEV: Unknown", text)

    def test_connected_gateway_overrides_historical_recovery(self):
        now = 2_000_000_000
        def command(args, **kwargs):
            if "channels" in " ".join(args):
                return json.dumps({"channelAccounts": {"telegram": [
                    {"accountId": "default", "running": True, "connected": True}
                ]}})
            return None
        def logs(unit, **kwargs):
            return [(now - 200, "restarting (reason: stopped)")] if unit == "openclaw-gateway.service" else []
        with patch.object(health, "run", side_effect=command), patch.object(health, "journal", side_effect=logs):
            text = health.collect(now)["text"]
        self.assertIn("Production: Telegram connected", text)
        self.assertNotIn("listener is stopping repeatedly", text)


if __name__ == "__main__":
    unittest.main()
