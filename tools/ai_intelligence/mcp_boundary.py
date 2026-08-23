"""Validated request boundary shared by the AI Intelligence MCP server."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from os import environ
from typing import Any


@dataclass(frozen=True)
class MCPExecutionRequest:
    """Validated AI request accepted from an MCP host."""

    component_id: str
    prompt: str
    system_prompt: str | None
    timeout_seconds: float


MCP_ENABLED_ENV = "OPENCLAW_AI_INTELLIGENCE_MCP_ENABLED"
MCP_ENVIRONMENT_ENV = "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT"


def require_dev_mcp_environment() -> None:
    """Allow MCP execution only after explicit DEV activation."""

    if environ.get(MCP_ENABLED_ENV) != "1":
        raise PermissionError("AI Intelligence MCP is disabled")
    if environ.get(MCP_ENVIRONMENT_ENV) != "development":
        raise PermissionError(
            "AI Intelligence MCP is restricted to the development environment"
        )


def parse_mcp_execution_request(arguments: Mapping[str, Any]) -> MCPExecutionRequest:
    """Reject malformed MCP tool arguments before reaching the router."""

    component_id = arguments.get("component_id")
    prompt = arguments.get("prompt")
    system_prompt = arguments.get("system_prompt")
    timeout_seconds = arguments.get("timeout_seconds", 60.0)

    if not isinstance(component_id, str) or not component_id.strip():
        raise ValueError("component_id must be a non-empty string")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("prompt must be a non-empty string")
    if system_prompt is not None and not isinstance(system_prompt, str):
        raise ValueError("system_prompt must be a string when provided")
    if isinstance(timeout_seconds, bool):
        raise ValueError("timeout_seconds must be numeric")
    try:
        timeout = float(timeout_seconds)
    except (TypeError, ValueError) as exc:
        raise ValueError("timeout_seconds must be numeric") from exc
    if not 0.1 <= timeout <= 300:
        raise ValueError("timeout_seconds must be between 0.1 and 300")

    return MCPExecutionRequest(
        component_id=component_id.strip(),
        prompt=prompt,
        system_prompt=system_prompt,
        timeout_seconds=timeout,
    )
