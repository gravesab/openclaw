from __future__ import annotations

import unittest
from unittest import mock

from tools.dashboard.test_scorecard_approval import dashboard
from tools.property_manager.mcp_boundary import (
    MCP_DATABASE_URL_ENV,
    MCP_ENABLED_ENV,
    MCP_ENVIRONMENT_ENV,
)


class SystemHealthTests(unittest.TestCase):
    def test_gateway_uses_user_runtime_and_listener_uses_system_scope(self):
        omlx = {"connected": True, "status": "Online"}
        propertymanager_mcp = {"ready": True, "status": "Ready (on demand)"}

        def check_service_result(name, _command, scope):
            return (name, scope, "Connected", "#16a34a")

        with mock.patch.object(
            dashboard,
            "check_service",
            side_effect=check_service_result,
        ) as check_service:
            services = dashboard.build_system_health(omlx, propertymanager_mcp)

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
        self.assertIn(
            (
                "PropertyManager MCP",
                "On-demand stdio server",
                "Ready (on demand)",
                "#16a34a",
            ),
            services,
        )
        self.assertEqual(
            [service[0] for service in services],
            sorted((service[0] for service in services), key=str.casefold),
        )

    def test_omlx_offline_status_is_displayed_in_service_health(self):
        omlx = {"connected": False, "status": "Credentials not configured"}
        with mock.patch.object(dashboard, "check_service", return_value=("a", "b", "c", "d")):
            services = dashboard.build_system_health(
                omlx,
                {"ready": False, "status": "Disabled"},
            )

        self.assertIn(
            (
                "oMLX API",
                "HTTP endpoint",
                "Credentials not configured",
                "#b91c1c",
            ),
            services,
        )

    def test_propertymanager_mcp_status_uses_only_its_dev_configuration_contract(self):
        environment = {
            MCP_ENABLED_ENV: "1",
            MCP_ENVIRONMENT_ENV: "development",
            MCP_DATABASE_URL_ENV: "postgresql://redacted",
        }
        with mock.patch.dict(dashboard.os.environ, environment, clear=True):
            self.assertEqual(
                dashboard.get_propertymanager_mcp_status(),
                {"ready": True, "status": "Ready (on demand)"},
            )

    def test_propertymanager_mcp_status_never_returns_its_database_url(self):
        database_url = "postgresql://dashboard-must-not-render-this"
        environment = {
            MCP_ENABLED_ENV: "1",
            MCP_ENVIRONMENT_ENV: "development",
            MCP_DATABASE_URL_ENV: database_url,
        }
        with mock.patch.dict(dashboard.os.environ, environment, clear=True):
            status = dashboard.get_propertymanager_mcp_status()

        self.assertNotIn(database_url, str(status))

    def test_propertymanager_mcp_status_reports_its_disabled_gate(self):
        with mock.patch.dict(dashboard.os.environ, {}, clear=True):
            self.assertEqual(
                dashboard.get_propertymanager_mcp_status(),
                {"ready": False, "status": "Disabled"},
            )


if __name__ == "__main__":
    unittest.main()
