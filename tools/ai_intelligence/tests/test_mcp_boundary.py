"""Tests for the DEV-only MCP v2 request boundary."""

from __future__ import annotations

import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

from tools.ai_intelligence.mcp_boundary import (
    parse_mcp_execution_request,
    require_dev_mcp_environment,
)
from tools.ai_intelligence.database import DatabaseConfigurationError
from tools.ai_intelligence.mcp_server import create_mcp_server, execute_mcp_request


STDIO_SERVER = """
from tools.ai_intelligence.mcp_boundary import (
    parse_mcp_execution_request,
    require_dev_mcp_environment,
)
from tools.ai_intelligence.mcp_server import create_mcp_server

def execute(component_id, prompt, system_prompt=None, timeout_seconds=60.0):
    require_dev_mcp_environment()
    request = parse_mcp_execution_request({
        "component_id": component_id,
        "prompt": prompt,
        "system_prompt": system_prompt,
        "timeout_seconds": timeout_seconds,
    })
    return {
        "status": "success",
        "component_id": request.component_id,
        "content": "bounded response",
    }

create_mcp_server(execute).run()
"""


async def run_stdio_handshake(environment: dict[str, str]) -> dict[str, object]:
    root = Path(__file__).resolve().parents[3]
    parameters = StdioServerParameters(
        command=sys.executable,
        args=["-c", STDIO_SERVER],
        cwd=root,
        env=environment,
    )
    async with stdio_client(parameters) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            tools = await session.list_tools()
            resources = await session.list_resources()
            prompts = await session.list_prompts()
            valid = await session.call_tool(
                "ai_execute",
                {
                    "component_id": "routine_local_query",
                    "prompt": "Return a bounded response.",
                    "timeout_seconds": 30,
                },
            )
            malformed = await session.call_tool(
                "ai_execute",
                {"component_id": "", "prompt": "Return a bounded response."},
            )
            return {
                "tools": [tool.name for tool in tools.tools],
                "resources": list(resources.resources),
                "prompts": list(prompts.prompts),
                "valid": valid,
                "malformed": malformed,
            }


class MCPBoundaryTests(unittest.TestCase):
    def test_accepts_bounded_execution_request(self) -> None:
        request = parse_mcp_execution_request(
            {
                "component_id": "property_manager",
                "prompt": "Summarize open work.",
                "system_prompt": "Use local records only.",
                "timeout_seconds": 30,
            }
        )

        self.assertEqual(request.component_id, "property_manager")
        self.assertEqual(request.timeout_seconds, 30)

    def test_rejects_unbounded_timeout(self) -> None:
        with self.assertRaisesRegex(ValueError, "between 0.1 and 300"):
            parse_mcp_execution_request(
                {
                    "component_id": "property_manager",
                    "prompt": "Summarize open work.",
                    "timeout_seconds": 301,
                }
            )

    def test_rejects_malformed_component_id(self) -> None:
        with self.assertRaisesRegex(ValueError, "component_id"):
            parse_mcp_execution_request(
                {"component_id": [], "prompt": "Summarize open work."}
            )

    @patch.dict("os.environ", {}, clear=True)
    def test_denies_mcp_without_explicit_dev_activation(self) -> None:
        with self.assertRaisesRegex(PermissionError, "disabled"):
            require_dev_mcp_environment()

    @patch.dict(
        "os.environ",
        {
            "OPENCLAW_AI_INTELLIGENCE_MCP_ENABLED": "1",
            "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "production",
        },
        clear=True,
    )
    def test_denies_mcp_outside_development(self) -> None:
        with self.assertRaisesRegex(PermissionError, "development"):
            require_dev_mcp_environment()

    def test_exposes_only_the_generic_ai_execute_tool(self) -> None:
        server = create_mcp_server(lambda *args: {"status": "success"})
        tools = asyncio.run(server.list_tools())
        self.assertEqual([tool.name for tool in tools], ["ai_execute"])

    @patch.dict(
        "os.environ",
        {
            "OPENCLAW_AI_INTELLIGENCE_MCP_ENABLED": "1",
            "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development",
        },
        clear=True,
    )
    def test_mcp_fails_closed_without_explicit_database_environment(self) -> None:
        with self.assertRaises(DatabaseConfigurationError):
            execute_mcp_request("routine_local_query", "Return a bounded response.")

    def test_uses_official_mcp_v2_surface_without_fastmcp(self) -> None:
        root = Path(__file__).resolve().parents[3]
        requirements = (root / "tools" / "ai_intelligence" / "requirements.txt").read_text(encoding="utf-8")
        server = (root / "tools" / "ai_intelligence" / "mcp_server.py").read_text(encoding="utf-8")

        self.assertIn("mcp>=2,<3", requirements)
        self.assertIn("from mcp.server import MCPServer", server)
        self.assertNotIn("mcp.server.fastmcp", server)

    def test_mcp_stdio_v2_handshake_is_clean_and_bounded(self) -> None:
        result = asyncio.run(
            run_stdio_handshake(
                {
                    "OPENCLAW_AI_INTELLIGENCE_MCP_ENABLED": "1",
                    "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development",
                    "PYTHONUNBUFFERED": "1",
                }
            )
        )

        self.assertEqual(result["tools"], ["ai_execute"])
        self.assertEqual(result["resources"], [])
        self.assertEqual(result["prompts"], [])
        self.assertFalse(result["valid"].is_error)
        self.assertIn("bounded response", result["valid"].content[0].text)
        self.assertTrue(result["malformed"].is_error)

    def test_mcp_stdio_denies_execution_outside_development(self) -> None:
        result = asyncio.run(
            run_stdio_handshake(
                {
                    "OPENCLAW_AI_INTELLIGENCE_MCP_ENABLED": "1",
                    "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "production",
                    "PYTHONUNBUFFERED": "1",
                }
            )
        )

        self.assertTrue(result["valid"].is_error)


if __name__ == "__main__":
    unittest.main()
