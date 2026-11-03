"""Validated request boundary shared by the AI Intelligence MCP server."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from os import environ
from typing import Any
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class MCPExecutionRequest:
    """Validated AI request accepted from an MCP host."""

    component_id: str
    prompt: str
    system_prompt: str | None
    timeout_seconds: float


MCP_ENABLED_ENV = "OPENCLAW_AI_INTELLIGENCE_MCP_ENABLED"
MCP_ENVIRONMENT_ENV = "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT"


def _notify_sentinel(event: dict) -> None:
    if environ.get("RANCH_SENTINEL_ENABLED", "0") != "1":
        return
    url = environ.get("RANCH_SENTINEL_URL", "http://127.0.0.1:8001/sense")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        return
    payload = json.dumps(event).encode("utf-8")
    outgoing = Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urlopen(outgoing, timeout=0.5):
            return
    except (OSError, URLError, TimeoutError):
        return


def _service_quarantined(service: str) -> bool:
    if environ.get("RANCH_SENTINEL_ENABLED", "0") != "1":
        return False
    base = urlparse(environ.get("RANCH_SENTINEL_URL", "http://127.0.0.1:8001/sense"))
    if base.scheme not in {"http", "https"} or base.hostname not in {"127.0.0.1", "localhost", "::1"}:
        return False
    port = base.port or (443 if base.scheme == "https" else 80)
    status_url = f"{base.scheme}://{base.hostname}:{port}/quarantine/{service}"
    try:
        with urlopen(status_url, timeout=0.05) as response:
            body = json.loads(response.read().decode("utf-8"))
        return body.get("quarantined") is True
    except (OSError, URLError, TimeoutError, json.JSONDecodeError):
        return False


def require_dev_mcp_environment() -> None:
    """Allow MCP execution only after explicit DEV activation."""

    if _service_quarantined("ai_intelligence_mcp"):
        raise PermissionError("503 quarantined")
    if environ.get(MCP_ENABLED_ENV) != "1":
        _notify_sentinel({
            "type": "mcp.dev_bypass_attempt",
            "service": "ai_intelligence_mcp",
            "score": 1.0,
            "payload": {"reason": "disabled"},
        })
        raise PermissionError("AI Intelligence MCP is disabled")
    if environ.get(MCP_ENVIRONMENT_ENV) != "development":
        _notify_sentinel({
            "type": "mcp.dev_bypass_attempt",
            "service": "ai_intelligence_mcp",
            "score": 1.0,
            "payload": {"reason": "environment"},
        })
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
