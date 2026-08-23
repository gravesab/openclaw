"""DEV-only MCP v2 server for bounded AI Intelligence execution."""

from __future__ import annotations

from typing import Any, Callable

from mcp.server import MCPServer

from tools.ai_intelligence.execution_engine import build_execution_engine_from_environment
from tools.ai_intelligence.mcp_boundary import (
    parse_mcp_execution_request,
    require_dev_mcp_environment,
)
from tools.ai_intelligence.routing_models import RoutingRequest


def serialize_mcp_result(result: Any) -> dict[str, Any]:
    """Return the bounded router result shape exposed by the MCP tool."""

    return {
        "requestId": result.request_id,
        "componentId": result.component_id,
        "status": result.status.value,
        "content": result.content,
        "selectedModelId": result.selected_model_id,
        "attempts": [
            {
                "providerName": attempt.provider_name,
                "modelId": attempt.model_id,
                "status": attempt.status.value,
                "startedAt": attempt.started_at.isoformat(),
                "finishedAt": attempt.finished_at.isoformat(),
                "durationMs": attempt.duration_ms,
                "errorType": attempt.error_type,
                "errorMessage": attempt.error_message,
            }
            for attempt in result.attempts
        ],
    }


def execute_mcp_request(
    component_id: str,
    prompt: str,
    system_prompt: str | None = None,
    timeout_seconds: float = 60.0,
) -> dict[str, Any]:
    """Execute one validated MCP request through the same router as Gateway RPC."""

    require_dev_mcp_environment()
    request = parse_mcp_execution_request(
        {
            "component_id": component_id,
            "prompt": prompt,
            "system_prompt": system_prompt,
            "timeout_seconds": timeout_seconds,
        }
    )
    result = build_execution_engine_from_environment().execute(
        RoutingRequest(component_id=request.component_id),
        prompt=request.prompt,
        system_prompt=request.system_prompt,
        timeout_seconds=request.timeout_seconds,
    )
    return serialize_mcp_result(result)


def create_mcp_server(
    execute: Callable[..., dict[str, Any]] = execute_mcp_request,
) -> MCPServer:
    """Build the official MCP Python SDK v2 server."""

    mcp = MCPServer(
        "openclaw-ai-intelligence-dev",
        instructions=(
            "DEV-only bounded AI execution. Use configured components only; "
            "the router enforces privacy and ordered fallback."
        ),
    )

    @mcp.tool()
    def ai_execute(
        component_id: str,
        prompt: str,
        system_prompt: str | None = None,
        timeout_seconds: float = 60.0,
    ) -> dict[str, Any]:
        """Execute a configured AI component through OpenClaw's DEV router."""

        return execute(component_id, prompt, system_prompt, timeout_seconds)

    return mcp


mcp = create_mcp_server()


if __name__ == "__main__":
    mcp.run()
