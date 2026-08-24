"""Fixed, read-only PostgreSQL queries for the PropertyManager MCP v1 surface."""

from __future__ import annotations

from typing import Any, Protocol

from tools.property_manager.mcp_boundary import PropertyManagerMCPDatabaseConfiguration

STATEMENT_TIMEOUT_MILLISECONDS = 5_000


class PropertyManagerMCPDatabaseError(RuntimeError):
    """Sanitized failure while establishing the dedicated read-only boundary."""


class PropertyManagerReadRepository(Protocol):
    def get_asset(self, *, asset_id: str | None, external_id: str | None) -> dict[str, Any] | None: ...
    def search_assets(self, *, query: str, limit: int) -> list[dict[str, Any]]: ...
    def list_tasks(self, *, days: int) -> list[dict[str, Any]]: ...
    def maintenance_history(self, *, task_id: str, limit: int) -> list[dict[str, Any]]: ...
    def runtime_hours(self, *, asset_id: str) -> dict[str, Any] | None: ...
    def search_manuals(
        self, *, asset_id: str | None, external_id: str | None, query: str, limit: int, offset: int
    ) -> list[dict[str, Any]]: ...


class PostgresPropertyManagerReadRepository:
    """Uses only the explicit MCP DSN in verified read-only transactions."""

    def __init__(self, configuration: PropertyManagerMCPDatabaseConfiguration) -> None:
        self._configuration = configuration

    def _rows(self, query: str, parameters: tuple[Any, ...]) -> list[dict[str, Any]]:
        import psycopg2
        from psycopg2.extras import RealDictCursor

        connection = None
        try:
            connection = psycopg2.connect(self._configuration.database_url)
            connection.set_session(readonly=True, autocommit=False)
            with connection.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute("SHOW transaction_read_only")
                mode = cursor.fetchone()["transaction_read_only"]
                if mode != "on":
                    raise PropertyManagerMCPDatabaseError("PropertyManager MCP read-only mode could not be verified")
                cursor.execute("SELECT set_config('statement_timeout', %s, true)", (str(STATEMENT_TIMEOUT_MILLISECONDS),))
                cursor.execute(
                    "SELECT current_setting('statement_timeout')::interval > interval '0' "
                    "AND current_setting('statement_timeout')::interval <= interval '5 seconds' "
                    "AS statement_timeout_bounded"
                )
                if not cursor.fetchone()["statement_timeout_bounded"]:
                    raise PropertyManagerMCPDatabaseError("PropertyManager MCP statement timeout could not be verified")
                cursor.execute(query, parameters)
                return [dict(row) for row in cursor.fetchall()]
        except PropertyManagerMCPDatabaseError:
            raise
        except psycopg2.Error as exc:
            raise PropertyManagerMCPDatabaseError("PropertyManager MCP database read failed closed") from exc
        finally:
            if connection is not None:
                try:
                    connection.rollback()
                finally:
                    connection.close()

    def get_asset(self, *, asset_id: str | None, external_id: str | None) -> dict[str, Any] | None:
        if asset_id is not None:
            query, parameters = (
                """SELECT a.id, a.external_id, a.name, a.manufacturer, a.model, a.category, a.location,
                           a.aliases, m.meter_type, m.current_value, m.unit, m.latest_reading_at
                    FROM propertymanager.assets a LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
                    WHERE a.is_active = true AND a.id = %s""",
                (asset_id,),
            )
        else:
            query, parameters = (
                """SELECT a.id, a.external_id, a.name, a.manufacturer, a.model, a.category, a.location,
                           a.aliases, m.meter_type, m.current_value, m.unit, m.latest_reading_at
                    FROM propertymanager.assets a LEFT JOIN propertymanager.asset_meter m ON m.asset_id = a.id
                    WHERE a.is_active = true AND a.external_id = %s""",
                (external_id,),
            )
        rows = self._rows(query, parameters)
        return rows[0] if rows else None

    def search_assets(self, *, query: str, limit: int) -> list[dict[str, Any]]:
        pattern = f"%{query}%"
        return self._rows(
            """SELECT id, external_id, name, manufacturer, model, category, location, aliases
                 FROM propertymanager.assets WHERE is_active = true
                   AND (name ILIKE %s OR external_id ILIKE %s OR category ILIKE %s OR aliases::text ILIKE %s)
                 ORDER BY category, name LIMIT %s""",
            (pattern, pattern, pattern, pattern, limit),
        )

    def list_tasks(self, *, days: int) -> list[dict[str, Any]]:
        return self._rows(
            """SELECT t.id, t.area, t.item, t.category_name, t.kind, t.next_due, t.schedule_kind,
                       t.next_due_meter_value, a.id AS asset_id, a.name AS asset_name,
                       m.current_value, m.meter_type, m.unit
                 FROM propertymanager.maintenance_tasks t
                 LEFT JOIN propertymanager.assets a ON a.id = t.asset_id AND a.is_active = true
                 LEFT JOIN propertymanager.asset_meter m ON m.asset_id = t.asset_id
                 WHERE t.is_active = true ORDER BY t.next_due, t.area, t.item LIMIT %s""",
            (min(days * 20, 1000),),
        )

    def maintenance_history(self, *, task_id: str, limit: int) -> list[dict[str, Any]]:
        return self._rows(
            """SELECT id, task_id, completed_at, note, meter_value_at_completion
                 FROM propertymanager.maintenance_completions WHERE task_id = %s
                 ORDER BY completed_at DESC, created_at DESC LIMIT %s""",
            (task_id, limit),
        )

    def runtime_hours(self, *, asset_id: str) -> dict[str, Any] | None:
        rows = self._rows(
            """SELECT a.id AS asset_id, a.external_id, a.name, m.current_value, m.unit, m.latest_reading_at
                 FROM propertymanager.assets a JOIN propertymanager.asset_meter m ON m.asset_id = a.id
                 WHERE a.id = %s AND a.is_active = true AND m.meter_type = 'runtime_hours'""",
            (asset_id,),
        )
        return rows[0] if rows else None

    def search_manuals(
        self, *, asset_id: str | None, external_id: str | None, query: str, limit: int, offset: int
    ) -> list[dict[str, Any]]:
        if asset_id is not None:
            asset_clause, identity = "a.id = %s", asset_id
        else:
            asset_clause, identity = "a.external_id = %s", external_id
        return self._rows(
            f"""SELECT a.id AS asset_id, a.external_id, m.id AS manual_id, m.title, m.document_type,
                       m.manufacturer, m.model_number, v.id AS manual_version_id, v.version_number,
                       v.source_display_name, c.id AS chunk_id, c.page_number, c.section_heading,
                       ts_rank(c.search_vector, plainto_tsquery('english', %s)) AS rank,
                       left(ts_headline('english', c.content, plainto_tsquery('english', %s),
                           'MaxFragments=1, MaxWords=60, MinWords=20, StartSel=<b>, StopSel=</b>'), 1000) AS excerpt
                  FROM propertymanager.assets a
                  JOIN propertymanager.asset_manual m ON m.asset_id = a.id
                  JOIN propertymanager.asset_manual_version v ON v.manual_id = m.id
                  JOIN propertymanager.asset_manual_chunk c ON c.manual_version_id = v.id
                 WHERE {asset_clause} AND a.is_active = true
                   AND v.ingestion_status = 'extracted' AND v.review_status = 'approved'
                   AND v.lifecycle_status = 'active'
                   AND c.search_vector @@ plainto_tsquery('english', %s)
                 ORDER BY rank DESC, m.id, v.id, c.chunk_ordinal LIMIT %s OFFSET %s""",
            (query, query, identity, query, limit, offset),
        )
