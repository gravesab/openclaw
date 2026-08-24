"""DEV-only, read-only PropertyManager MCP v1 server."""

from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation
from typing import Any, Callable
from uuid import UUID
from zoneinfo import ZoneInfo

from mcp.server import MCPServer

from tools.property_manager.mcp_boundary import PropertyManagerMCPDatabaseConfiguration, require_dev_mcp_environment
from tools.property_manager.mcp_repository import PostgresPropertyManagerReadRepository, PropertyManagerReadRepository

CHICAGO = ZoneInfo("America/Chicago")
DEFAULT_DUE_WINDOW_DAYS = 30
MAX_DUE_WINDOW_DAYS = 365


def _limit(value: int, *, default: int = 50) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 100:
        raise ValueError("limit must be an integer between 1 and 100")
    return value


def _days(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_DUE_WINDOW_DAYS:
        raise ValueError("days must be an integer between 1 and 365")
    return value


def _asset_identity(asset_id: str | None, external_id: str | None) -> tuple[str | None, str | None]:
    if bool(asset_id) == bool(external_id):
        raise ValueError("provide exactly one of asset_id or external_id")
    if asset_id is not None:
        if not isinstance(asset_id, str):
            raise ValueError("asset_id must be a UUID")
        try:
            return str(UUID(asset_id)), None
        except (AttributeError, ValueError) as exc:
            raise ValueError("asset_id must be a UUID") from exc
    if not isinstance(external_id, str) or not external_id.strip() or len(external_id.strip()) > 255:
        raise ValueError("external_id must be a non-empty string of at most 255 characters")
    return None, external_id.strip()


def _uuid(value: str, *, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a UUID")
    try:
        return str(UUID(value))
    except (AttributeError, ValueError) as exc:
        raise ValueError(f"{field} must be a UUID") from exc




def create_mcp_server(repository_factory: Callable[[], PropertyManagerReadRepository] | None = None) -> MCPServer:
    """Create the dedicated PropertyManager v1 server; no AI router is involved."""
    if repository_factory is None:
        repository_factory = lambda: PostgresPropertyManagerReadRepository(PropertyManagerMCPDatabaseConfiguration.from_environment())

    def repository() -> PropertyManagerReadRepository:
        require_dev_mcp_environment()
        return repository_factory()

    mcp = MCPServer("openclaw-propertymanager-dev", instructions="DEV-only read-only PropertyManager MCP v1.")

    @mcp.tool()
    def get_asset(asset_id: str | None = None, external_id: str | None = None) -> dict[str, Any]:
        """Get one active asset by exactly one approved identifier."""
        asset_id, external_id = _asset_identity(asset_id, external_id)
        return {"asset": repository().get_asset(asset_id=asset_id, external_id=external_id)}

    @mcp.tool()
    def search_assets(query: str, limit: int = 50) -> dict[str, Any]:
        """Search active assets with a bounded, stable result set."""
        if not isinstance(query, str) or not query.strip() or len(query) > 120:
            raise ValueError("query must be a non-empty string of at most 120 characters")
        return {"assets": repository().search_assets(query=query.strip(), limit=_limit(limit))}

    def task_window(days: int, overdue: bool) -> dict[str, Any]:
        window = _days(days)
        today = datetime.now(CHICAGO).date()
        end = today + timedelta(days=window)
        result = []
        for task in repository().list_tasks(days=window):
            due_date = task.get("next_due")
            current, trigger = task.get("current_value"), task.get("next_due_meter_value")
            calendar_overdue = bool(due_date and str(due_date)[:10] < today.isoformat())
            calendar_due = bool(due_date and today.isoformat() <= str(due_date)[:10] <= end.isoformat())
            try:
                meter_overdue = bool(current is not None and trigger is not None and Decimal(str(current)) > Decimal(str(trigger)))
                meter_due = bool(current is not None and trigger is not None and Decimal(str(current)) == Decimal(str(trigger)))
            except (InvalidOperation, ValueError):
                meter_overdue = meter_due = False
            include = (calendar_overdue or meter_overdue) if overdue else (calendar_due or meter_due)
            if include:
                result.append({**task, "calendar_due": calendar_due, "calendar_overdue": calendar_overdue, "meter_due": meter_due, "meter_overdue": meter_overdue})
        return {"timezone": "America/Chicago", "days": window, "tasks": result}

    @mcp.tool()
    def get_due_tasks(days: int = DEFAULT_DUE_WINDOW_DAYS) -> dict[str, Any]:
        """Return active tasks due within the bounded America/Chicago window."""
        return task_window(days, False)

    @mcp.tool()
    def get_overdue_tasks(days: int = DEFAULT_DUE_WINDOW_DAYS) -> dict[str, Any]:
        """Return active tasks overdue under strict calendar and meter comparisons."""
        return task_window(days, True)

    @mcp.tool()
    def get_maintenance_history(task_id: str, limit: int = 50) -> dict[str, Any]:
        """Return bounded normalized completion history for one task."""
        return {"history": repository().maintenance_history(task_id=_uuid(task_id, field="task_id"), limit=_limit(limit))}

    @mcp.tool()
    def get_runtime_hours(asset_id: str) -> dict[str, Any]:
        """Return current runtime hours for one active runtime-hours asset."""
        return {"runtime_hours": repository().runtime_hours(asset_id=_uuid(asset_id, field="asset_id"))}

    @mcp.tool()
    def search_asset_manual(asset_id: str | None = None, external_id: str | None = None, query: str = "", limit: int = 10, offset: int = 0) -> dict[str, Any]:
        """Search approved active indexed handbook chunks for exactly one asset."""
        asset_id, external_id = _asset_identity(asset_id, external_id)
        if not isinstance(query, str) or not 2 <= len(query.strip()) <= 200: raise ValueError("query must contain 2 to 200 characters")
        if isinstance(offset, bool) or not isinstance(offset, int) or not 0 <= offset <= 500: raise ValueError("offset must be an integer between 0 and 500")
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 25: raise ValueError("limit must be an integer between 1 and 25")
        return {"manuals": repository().search_manuals(asset_id=asset_id, external_id=external_id, query=query.strip(), limit=limit, offset=offset)}

    return mcp


mcp = create_mcp_server()

if __name__ == "__main__":
    mcp.run()
