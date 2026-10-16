"""Tenant-scoped PropertyManager repository operations.

Every function here requires a server-derived :class:`TenantContext` and
applies its ``tenant_id`` to every read and write. Row-level security on
the ``propertymanager`` tables independently confines each transaction to
``ranchos.tenant_id``, so even an unfiltered query cannot cross ranches.

This module opens no connections and reads no configuration: callers pass
an already-open PEP 249 connection. It never consults a default ranch.
It never commits or rolls back the caller's transaction either: entering
a session only sets transaction-local state, and the caller owns commit
and rollback. Arbitrary SQL stays private to this module; the only public
database surface is the capability-checked repository operations below.
"""

from __future__ import annotations

from typing import Any, Protocol
from uuid import UUID

from tools.property_manager.tenancy import (
    Capability,
    TenancyError,
    TenancyErrorCode,
    TenantContext,
    require_capability,
)


class _Cursor(Protocol):
    def execute(self, operation: str, parameters: tuple[object, ...] = ...) -> object: ...
    def fetchone(self) -> tuple[object, ...] | None: ...
    def fetchall(self) -> list[tuple[object, ...]]: ...
    def close(self) -> None: ...


class _Connection(Protocol):
    def cursor(self) -> _Cursor: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


class TenantSession:
    """One tenant-scoped transaction on an existing connection.

    Sets transaction-local ``ranchos.principal_id``, ``ranchos.environment``,
    and ``ranchos.tenant_id`` before any repository statement runs, then
    verifies the tenant setting took effect. All settings go through
    parameterized ``set_config`` calls: no value is ever interpolated into
    SQL text. Entering a session never commits or rolls back; the caller
    owns the transaction and must commit or roll back explicitly.
    """

    def __init__(self, connection: _Connection, context: TenantContext) -> None:
        if not isinstance(context, TenantContext):
            raise TenancyError("tenant session requires a tenant context")
        self._connection = connection
        self._context = context
        self._cursor: _Cursor | None = None

    @property
    def context(self) -> TenantContext:
        return self._context

    def __enter__(self) -> TenantSession:
        cursor = self._connection.cursor()
        self._cursor = cursor
        cursor.execute("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")
        privileges = cursor.fetchone()
        if privileges is None or privileges[0] or privileges[1]:
            raise TenancyError("tenant sessions refuse privileged database roles")
        principal_id = str(UUID(str(self._context.principal.id)))
        tenant_id = str(UUID(str(self._context.tenant_id)))
        environment = self._context.environment.strip()
        if not environment:
            raise TenancyError("environment is required")
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", principal_id))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.environment", environment))
        cursor.execute("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", tenant_id))
        cursor.execute("SELECT current_setting('ranchos.tenant_id', true)")
        if cursor.fetchone() != (tenant_id,):
            raise TenancyError("tenant setting did not take effect")
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if self._cursor is not None:
            self._cursor.close()
            self._cursor = None

    def _require_open(self) -> _Cursor:
        if self._cursor is None:
            raise TenancyError("tenant session is not open")
        return self._cursor

    def _fetchall(self, query: str, parameters: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
        cursor = self._require_open()
        cursor.execute(query, parameters)
        return list(cursor.fetchall())

    def _fetchone(self, query: str, parameters: tuple[object, ...] = ()) -> tuple[object, ...] | None:
        cursor = self._require_open()
        cursor.execute(query, parameters)
        return cursor.fetchone()

    def _execute(self, query: str, parameters: tuple[object, ...] = ()) -> None:
        cursor = self._require_open()
        cursor.execute(query, parameters)


def _read_row(session: TenantSession, query: str, parameters: tuple[object, ...]) -> tuple[object, ...] | None:
    require_capability(session.context, Capability.READ)
    return session._fetchone(query, parameters)


def _read_rows(session: TenantSession, query: str, parameters: tuple[object, ...]) -> list[tuple[object, ...]]:
    require_capability(session.context, Capability.READ)
    return session._fetchall(query, parameters)


def _write(session: TenantSession, query: str, parameters: tuple[object, ...]) -> None:
    require_capability(session.context, Capability.WRITE)
    session._execute(query, parameters)


def create_asset(
    session: TenantSession,
    *,
    asset_id: str,
    external_id: str,
    name: str,
    qr_token: str,
) -> None:
    """Insert one asset owned by the session tenant. The tenant comes from
    the context; callers cannot name another ranch."""
    _write(
        session,
        "INSERT INTO propertymanager.assets (tenant_id, id, external_id, name, qr_token)"
        " VALUES (%s, %s, %s, %s, %s)",
        (session.context.tenant_id, asset_id, external_id, name, qr_token),
    )


def get_asset(session: TenantSession, *, asset_id: str) -> tuple[object, ...] | None:
    return _read_row(
        session,
        "SELECT id, external_id, name FROM propertymanager.assets WHERE tenant_id = %s AND id = %s",
        (session.context.tenant_id, asset_id),
    )


def list_assets(session: TenantSession) -> list[tuple[object, ...]]:
    return _read_rows(
        session,
        "SELECT id, external_id, name FROM propertymanager.assets WHERE tenant_id = %s ORDER BY name",
        (session.context.tenant_id,),
    )


def update_asset_name(session: TenantSession, *, asset_id: str, name: str) -> int:
    """Rename an asset of the session tenant. Returns rows matched."""
    require_capability(session.context, Capability.WRITE)
    row = session._fetchone(
        "UPDATE propertymanager.assets SET name = %s WHERE tenant_id = %s AND id = %s RETURNING id",
        (name, session.context.tenant_id, asset_id),
    )
    return 1 if row else 0


def delete_asset(session: TenantSession, *, asset_id: str) -> int:
    """Delete an asset of the session tenant. Returns rows matched.

    Owner-only: the tenancy contract reserves delete and archive for owners.
    """
    require_capability(session.context, Capability.ADMIN)
    row = session._fetchone(
        "DELETE FROM propertymanager.assets WHERE tenant_id = %s AND id = %s RETURNING id",
        (session.context.tenant_id, asset_id),
    )
    return 1 if row else 0


def create_task(
    session: TenantSession,
    *,
    task_id: str,
    area: str,
    item: str,
    warning_days: int,
    critical_days: int,
    asset_id: str | None = None,
) -> None:
    _write(
        session,
        "INSERT INTO propertymanager.maintenance_tasks"
        " (tenant_id, id, area, item, warning_days, critical_days, last_done, next_due, asset_id)"
        " VALUES (%s, %s, %s, %s, %s, %s, now(), now(), %s)",
        (session.context.tenant_id, task_id, area, item, warning_days, critical_days, asset_id),
    )


def get_task(session: TenantSession, *, task_id: str) -> tuple[object, ...] | None:
    return _read_row(
        session,
        "SELECT id, area, item FROM propertymanager.maintenance_tasks WHERE tenant_id = %s AND id = %s",
        (session.context.tenant_id, task_id),
    )


def list_tasks(session: TenantSession) -> list[tuple[object, ...]]:
    return _read_rows(
        session,
        "SELECT id, area, item FROM propertymanager.maintenance_tasks WHERE tenant_id = %s ORDER BY area, item",
        (session.context.tenant_id,),
    )


def record_reading(
    session: TenantSession,
    *,
    reading_id: str,
    asset_id: str,
    value: object,
) -> None:
    _write(
        session,
        "INSERT INTO propertymanager.asset_meter_reading (tenant_id, id, asset_id, value)"
        " VALUES (%s, %s, %s, %s)",
        (session.context.tenant_id, reading_id, asset_id, value),
    )


def list_readings(session: TenantSession, *, asset_id: str) -> list[tuple[object, ...]]:
    return _read_rows(
        session,
        "SELECT id, value FROM propertymanager.asset_meter_reading"
        " WHERE tenant_id = %s AND asset_id = %s ORDER BY reading_at",
        (session.context.tenant_id, asset_id),
    )


def record_completion(
    session: TenantSession,
    *,
    completion_id: str,
    task_id: str,
    note: str | None = None,
) -> None:
    _write(
        session,
        "INSERT INTO propertymanager.maintenance_completions (tenant_id, id, task_id, completed_at, note)"
        " VALUES (%s, %s, %s, now(), %s)",
        (session.context.tenant_id, completion_id, task_id, note),
    )


def list_completions(session: TenantSession, *, task_id: str) -> list[tuple[object, ...]]:
    return _read_rows(
        session,
        "SELECT id, note FROM propertymanager.maintenance_completions"
        " WHERE tenant_id = %s AND task_id = %s ORDER BY completed_at",
        (session.context.tenant_id, task_id),
    )


def code_of(error: BaseException) -> TenancyErrorCode | None:
    """Map a tenancy failure to its code, or None for other errors."""
    if isinstance(error, TenancyError):
        return error.code
    return None


__all__ = [
    "TenantSession",
    "code_of",
    "create_asset",
    "create_task",
    "delete_asset",
    "get_asset",
    "get_task",
    "list_assets",
    "list_completions",
    "list_readings",
    "list_tasks",
    "record_completion",
    "record_reading",
    "update_asset_name",
]
