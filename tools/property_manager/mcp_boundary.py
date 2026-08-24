"""DEV-only validation and configuration for PropertyManager MCP v1."""

from __future__ import annotations

from dataclasses import dataclass
from os import environ


MCP_ENABLED_ENV = "OPENCLAW_PROPERTYMANAGER_MCP_ENABLED"
MCP_ENVIRONMENT_ENV = "OPENCLAW_PROPERTYMANAGER_MCP_ENVIRONMENT"
MCP_DATABASE_URL_ENV = "OPENCLAW_PROPERTYMANAGER_MCP_DATABASE_URL"


@dataclass(frozen=True)
class PropertyManagerMCPDatabaseConfiguration:
    """Dedicated, explicit, read-only DEV database configuration."""

    database_url: str

    @classmethod
    def from_environment(cls) -> "PropertyManagerMCPDatabaseConfiguration":
        require_dev_mcp_environment()
        database_url = environ.get(MCP_DATABASE_URL_ENV, "").strip()
        if not database_url:
            raise RuntimeError("PropertyManager MCP database URL is not configured")
        return cls(database_url=database_url)


def require_dev_mcp_environment() -> None:
    """Reject every MCP request unless it is explicitly DEV-only enabled."""

    if environ.get(MCP_ENABLED_ENV) != "1":
        raise PermissionError("PropertyManager MCP is disabled")
    if environ.get(MCP_ENVIRONMENT_ENV) != "development":
        raise PermissionError("PropertyManager MCP is restricted to development")
