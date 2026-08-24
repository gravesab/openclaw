"""Focused MCP v1 tests for bounded, DEV-only PropertyManager reads."""

from __future__ import annotations

import asyncio
import os
import sys
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

from tools.property_manager.mcp_boundary import (
    PropertyManagerMCPDatabaseConfiguration,
    require_dev_mcp_environment,
)
from tools.property_manager.mcp_repository import (
    PropertyManagerMCPDatabaseError,
    PostgresPropertyManagerReadRepository,
    STATEMENT_TIMEOUT_MILLISECONDS,
)
from tools.property_manager.mcp_server import create_mcp_server


ASSET_ID = "11111111-1111-1111-1111-111111111111"
TASK_ID = "22222222-2222-2222-2222-222222222222"

STDIO_SERVER = """
from tools.property_manager.mcp_server import create_mcp_server

class Repository:
    def get_asset(self, **kwargs): return {"id": kwargs.get("asset_id") or "asset", "external_id": "mower-1"}
    def search_assets(self, **kwargs): return [{"id": "asset", "name": "Mower"}]
    def list_tasks(self, **kwargs): return []
    def maintenance_history(self, **kwargs): return []
    def runtime_hours(self, **kwargs): return {"asset_id": kwargs["asset_id"], "current_value": "12.5", "unit": "hours"}
    def search_manuals(self, **kwargs): return [{"manual_id": "manual", "excerpt": "bounded manual excerpt"}]

create_mcp_server(lambda: Repository()).run()
"""


class FakeRepository:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    def get_asset(self, **kwargs):
        self.calls.append(("get_asset", kwargs))
        return {"id": kwargs.get("asset_id") or "asset", "external_id": "mower-1"}

    def search_assets(self, **kwargs):
        self.calls.append(("search_assets", kwargs))
        return [{"id": ASSET_ID, "name": "Mower"}]

    def list_tasks(self, **kwargs):
        self.calls.append(("list_tasks", kwargs))
        return []

    def maintenance_history(self, **kwargs):
        self.calls.append(("maintenance_history", kwargs))
        return []

    def runtime_hours(self, **kwargs):
        self.calls.append(("runtime_hours", kwargs))
        return {"asset_id": kwargs["asset_id"], "current_value": "12.5", "unit": "hours"}

    def search_manuals(self, **kwargs):
        self.calls.append(("search_manuals", kwargs))
        return [{"manual_id": "manual", "excerpt": "bounded manual excerpt"}]


async def run_stdio_handshake(environment: dict[str, str]) -> dict[str, object]:
    root = Path(__file__).resolve().parents[3]
    parameters = StdioServerParameters(command=sys.executable, args=["-c", STDIO_SERVER], cwd=root, env=environment)
    async with stdio_client(parameters) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            tools = await session.list_tools()
            resources = await session.list_resources()
            prompts = await session.list_prompts()
            calls = {}
            for name, arguments in (
                ("get_asset", {"asset_id": ASSET_ID}),
                ("search_assets", {"query": "mower", "limit": 1}),
                ("get_due_tasks", {"days": 30}),
                ("get_overdue_tasks", {"days": 30}),
                ("get_maintenance_history", {"task_id": TASK_ID, "limit": 1}),
                ("get_runtime_hours", {"asset_id": ASSET_ID}),
                ("search_asset_manual", {"asset_id": ASSET_ID, "query": "oil", "limit": 1, "offset": 0}),
            ):
                calls[name] = await session.call_tool(name, arguments)
            malformed = await session.call_tool("search_asset_manual", {"asset_id": ASSET_ID, "query": "x"})
            return {
                "tools": [tool.name for tool in tools.tools],
                "resources": list(resources.resources),
                "prompts": list(prompts.prompts),
                "calls": calls,
                "malformed": malformed,
            }


class Cursor:
    def __init__(self, readonly: str) -> None:
        self.readonly = readonly
        self.calls: list[tuple[str, tuple[object, ...] | None]] = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def execute(self, query, parameters=None):
        self.calls.append((query, parameters))

    def fetchone(self):
        if self.calls[-1][0].startswith("SELECT current_setting"):
            return {"statement_timeout_bounded": True}
        return {"transaction_read_only": self.readonly}

    def fetchall(self):
        return []


class Connection:
    def __init__(self, readonly: str = "on") -> None:
        self.cursor_instance = Cursor(readonly)
        self.set_session_calls = []
        self.rolled_back = False
        self.closed = False

    def set_session(self, **kwargs):
        self.set_session_calls.append(kwargs)

    def cursor(self, **_kwargs):
        return self.cursor_instance

    def rollback(self):
        self.rolled_back = True

    def close(self):
        self.closed = True


class PropertyManagerMCPV1Tests(unittest.TestCase):
    def test_requires_explicit_development_gate(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(PermissionError, "disabled"):
                require_dev_mcp_environment()
        with patch.dict(
            os.environ,
            {"OPENCLAW_PROPERTYMANAGER_MCP_ENABLED": "1", "OPENCLAW_PROPERTYMANAGER_MCP_ENVIRONMENT": "production"},
            clear=True,
        ):
            with self.assertRaisesRegex(PermissionError, "development"):
                require_dev_mcp_environment()

    def test_exposes_exactly_the_seven_read_only_v1_tools(self) -> None:
        server = create_mcp_server(FakeRepository)
        tools = asyncio.run(server.list_tools())
        self.assertEqual(
            [tool.name for tool in tools],
            [
                "get_asset", "search_assets", "get_due_tasks", "get_overdue_tasks",
                "get_maintenance_history", "get_runtime_hours", "search_asset_manual",
            ],
        )
        self.assertNotIn("sql", " ".join(tool.name for tool in tools).lower())
        self.assertNotIn("shell", " ".join(tool.name for tool in tools).lower())

    def test_database_configuration_has_no_generic_or_production_fallback(self) -> None:
        with patch.dict(
            os.environ,
            {"OPENCLAW_PROPERTYMANAGER_MCP_ENABLED": "1", "OPENCLAW_PROPERTYMANAGER_MCP_ENVIRONMENT": "development", "OPENCLAW_DB_PASSWORD": "ignored"},
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "database URL"):
                PropertyManagerMCPDatabaseConfiguration.from_environment()

    def test_mcp_stdio_handshake_exercises_all_seven_tools_without_protocol_noise(self) -> None:
        result = asyncio.run(
            run_stdio_handshake(
                {
                    "OPENCLAW_PROPERTYMANAGER_MCP_ENABLED": "1",
                    "OPENCLAW_PROPERTYMANAGER_MCP_ENVIRONMENT": "development",
                    "PYTHONUNBUFFERED": "1",
                }
            )
        )
        self.assertEqual(
            result["tools"],
            [
                "get_asset", "search_assets", "get_due_tasks", "get_overdue_tasks",
                "get_maintenance_history", "get_runtime_hours", "search_asset_manual",
            ],
        )
        self.assertEqual(result["resources"], [])
        self.assertEqual(result["prompts"], [])
        self.assertTrue(all(not response.is_error for response in result["calls"].values()))
        self.assertTrue(result["malformed"].is_error)

    def test_stdio_denies_all_runtime_tools_outside_development(self) -> None:
        result = asyncio.run(
            run_stdio_handshake(
                {
                    "OPENCLAW_PROPERTYMANAGER_MCP_ENABLED": "1",
                    "OPENCLAW_PROPERTYMANAGER_MCP_ENVIRONMENT": "production",
                    "PYTHONUNBUFFERED": "1",
                }
            )
        )
        self.assertTrue(all(response.is_error for response in result["calls"].values()))

    def test_manual_inputs_reject_sql_shell_and_path_shaped_values_before_repository_access(self) -> None:
        repository = FakeRepository()
        server = create_mcp_server(lambda: repository)
        tool = server._tool_manager._tools["search_asset_manual"].fn
        with patch.dict(os.environ, {"OPENCLAW_PROPERTYMANAGER_MCP_ENABLED": "1", "OPENCLAW_PROPERTYMANAGER_MCP_ENVIRONMENT": "development"}, clear=True):
            with self.assertRaises(ValueError):
                tool(asset_id="../../etc/passwd", query="select * from assets")
            with self.assertRaises(ValueError):
                tool(asset_id=ASSET_ID, query="x")
        self.assertEqual(repository.calls, [])

    def test_read_only_mode_timeout_and_cleanup_are_required(self) -> None:
        connection = Connection()
        psycopg2 = ModuleType("psycopg2")
        psycopg2.Error = Exception
        psycopg2.connect = lambda _dsn: connection
        extras = ModuleType("psycopg2.extras")
        extras.RealDictCursor = object
        repository = PostgresPropertyManagerReadRepository(PropertyManagerMCPDatabaseConfiguration("postgresql://dev-only"))
        with patch.dict(sys.modules, {"psycopg2": psycopg2, "psycopg2.extras": extras}):
            self.assertEqual(repository.search_assets(query="mower", limit=1), [])
        self.assertEqual(connection.set_session_calls, [{"readonly": True, "autocommit": False}])
        self.assertTrue(connection.rolled_back)
        self.assertTrue(connection.closed)
        self.assertEqual(connection.cursor_instance.calls[0][0], "SHOW transaction_read_only")
        self.assertEqual(connection.cursor_instance.calls[1], ("SELECT set_config('statement_timeout', %s, true)", (str(STATEMENT_TIMEOUT_MILLISECONDS),)))
        self.assertTrue(connection.cursor_instance.calls[2][0].startswith("SELECT current_setting"))

    def test_unverified_read_only_mode_fails_closed_and_closes_connection(self) -> None:
        connection = Connection("off")
        psycopg2 = ModuleType("psycopg2")
        psycopg2.Error = Exception
        psycopg2.connect = lambda _dsn: connection
        extras = ModuleType("psycopg2.extras")
        extras.RealDictCursor = object
        repository = PostgresPropertyManagerReadRepository(PropertyManagerMCPDatabaseConfiguration("postgresql://dev-only"))
        with patch.dict(sys.modules, {"psycopg2": psycopg2, "psycopg2.extras": extras}):
            with self.assertRaisesRegex(PropertyManagerMCPDatabaseError, "could not be verified"):
                repository.search_assets(query="mower", limit=1)
        self.assertTrue(connection.rolled_back)
        self.assertTrue(connection.closed)

    def test_search_result_contract_never_selects_source_locator_or_unbounded_content(self) -> None:
        source = Path(__file__).resolve().parents[1] / "mcp_repository.py"
        search = source.read_text(encoding="utf-8").split("def search_manuals", 1)[1]
        self.assertNotIn("source_locator", search)
        self.assertIn("left(ts_headline", search)
        self.assertIn(", 1000)", search)
        self.assertIn("plainto_tsquery", search)


if __name__ == "__main__":
    unittest.main()
