from __future__ import annotations

import unittest
from unittest import mock

from tools.dashboard.test_scorecard_approval import dashboard


class SystemHealthTests(unittest.TestCase):
    def test_gateway_uses_user_runtime_and_listener_uses_system_scope(self):
        with mock.patch.object(dashboard, "check_service") as check_service:
            dashboard.build_system_health()

        calls = {call.args[0]: call.args[1:] for call in check_service.call_args_list}
        self.assertEqual(
            calls["OpenClaw Gateway"],
            (
                "XDG_RUNTIME_DIR=/run/user/$(id -u) "
                "systemctl --user is-active openclaw-gateway.service",
                "User service",
            ),
        )
        self.assertEqual(
            calls["OpenClaw Listener"],
            (
                "systemctl is-active openclaw-listener.service",
                "System service",
            ),
        )


if __name__ == "__main__":
    unittest.main()
