from __future__ import annotations

import unittest
from unittest import mock

from tools.dashboard.test_scorecard_approval import dashboard


class SystemHealthTests(unittest.TestCase):
    def test_gateway_uses_user_runtime_and_listener_uses_system_scope(self):
        omlx = {"connected": True, "status": "Online"}

        def check_service_result(name, _command, scope):
            return (name, scope, "Connected", "#16a34a")

        with mock.patch.object(
            dashboard,
            "check_service",
            side_effect=check_service_result,
        ) as check_service:
            services = dashboard.build_system_health(omlx)

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
        self.assertIn(
            ("oMLX API", "HTTP endpoint", "Connected", "#16a34a"),
            services,
        )
        self.assertEqual(
            [service[0] for service in services],
            sorted((service[0] for service in services), key=str.casefold),
        )

    def test_omlx_offline_status_is_displayed_in_service_health(self):
        omlx = {"connected": False, "status": "Credentials not configured"}
        with mock.patch.object(dashboard, "check_service", return_value=("a", "b", "c", "d")):
            services = dashboard.build_system_health(omlx)

        self.assertIn(
            (
                "oMLX API",
                "HTTP endpoint",
                "Credentials not configured",
                "#b91c1c",
            ),
            services,
        )


if __name__ == "__main__":
    unittest.main()
