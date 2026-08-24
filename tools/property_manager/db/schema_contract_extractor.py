"""Canonical, read-only PostgreSQL schema-contract extraction for PropertyManager."""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Mapping
from typing import Any, Protocol

SCHEMA_NAME = "propertymanager"
STATEMENT_TIMEOUT_MILLISECONDS = 5_000
CANONICAL_DATA = {
    "maintenance_categories": {
        "key": ("id",),
        "columns": ("id", "name", "icon", "color_name", "is_built_in", "sort_order"),
    }
}


class SchemaContractExtractionError(RuntimeError):
    """The database could not be proven safe for schema extraction."""


class Cursor(Protocol):
    def execute(self, query: str, parameters: tuple[Any, ...] = ()) -> None: ...
    def fetchall(self) -> list[tuple[Any, ...]]: ...
    def fetchone(self) -> tuple[Any, ...] | None: ...
    def __enter__(self) -> "Cursor": ...
    def __exit__(self, *_args: Any) -> None: ...


class Connection(Protocol):
    def set_session(self, *, readonly: bool, autocommit: bool) -> None: ...
    def cursor(self) -> Cursor: ...
    def rollback(self) -> None: ...
    def close(self) -> None: ...


ConnectionFactory = Callable[[], Connection]

_CAST = re.compile(r"(?<!:):{2}(?:text|character varying|timestamp with time zone|regconfig)(?:\[\])?")
_SPACE = re.compile(r"\s+")
_ANY_ARRAY = re.compile(r"(?:\()?([a-z_]+) = ANY \(ARRAY\[([^\]]+)\]\)(?:\))?")


def canonical_json(value: Mapping[str, Any]) -> str:
    """The one serialization used by authority snapshots and generated fixtures."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _normalize_expression(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = _CAST.sub("", value)
    normalized = normalized.replace("(", "(").replace(")", ")")
    normalized = _SPACE.sub(" ", normalized).strip()
    return normalized


def _strip_wrapping(value: str | None) -> str | None:
    normalized = _normalize_expression(value)
    if normalized is None:
        return None
    while normalized.startswith("(") and normalized.endswith(")"):
        inner = normalized[1:-1].strip()
        if not inner or inner.count("(") != inner.count(")"):
            break
        normalized = inner
    return normalized


def _constraint_columns(attnums: list[int], names: Mapping[int, str]) -> list[str]:
    return [names[number] for number in attnums if number in names]


def _normalize_check(value: str) -> str:
    normalized = _normalize_expression(value) or ""
    normalized = _ANY_ARRAY.sub(r"\1 IN (\2)", normalized)
    normalized = normalized.replace("( ", "(").replace(" )", ")")
    normalized = normalized.replace("( (", "(")
    if normalized.startswith("CHECK ") and not normalized.startswith("CHECK ("):
        normalized = "CHECK (" + normalized.removeprefix("CHECK ") + ")"
    if normalized.startswith("CHECK (") and normalized.endswith(")"):
        body = normalized[7:-1]
        if body.count(" OR ") == 1:
            left, right = body.split(" OR ")
            if " AND " in left and " AND " in right:
                normalized = f"CHECK (({left}) OR ({right}))"
    return normalized


class PostgresSchemaContractExtractor:
    """Extract only the fixed PropertyManager catalog contract in a read-only tx."""

    def __init__(self, connect: ConnectionFactory) -> None:
        self._connect = connect

    def extract(self) -> dict[str, Any]:
        connection = None
        try:
            connection = self._connect()
            connection.set_session(readonly=True, autocommit=False)
            with connection.cursor() as cursor:
                cursor.execute("SHOW transaction_read_only")
                mode = cursor.fetchone()
                if mode != ("on",):
                    raise SchemaContractExtractionError("read-only transaction could not be verified")
                cursor.execute("SELECT set_config('statement_timeout', %s, true)", (str(STATEMENT_TIMEOUT_MILLISECONDS),))
                cursor.execute("SELECT current_setting('statement_timeout')::interval <= interval '5 seconds'")
                if cursor.fetchone() != (True,):
                    raise SchemaContractExtractionError("statement timeout could not be verified")
                return self._extract(cursor)
        except SchemaContractExtractionError:
            raise
        except Exception as exc:
            raise SchemaContractExtractionError("schema contract extraction failed closed") from exc
        finally:
            if connection is not None:
                try:
                    connection.rollback()
                finally:
                    connection.close()

    def _extract(self, cursor: Cursor) -> dict[str, Any]:
        cursor.execute(
            "SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE n.nspname = 'propertymanager' AND c.relkind = 'r' ORDER BY c.relname"
        )
        tables: dict[str, Any] = {}
        for table_oid, table_name in cursor.fetchall():
            tables[str(table_name)] = self._table(cursor, int(table_oid))
        return {
            "normalization_version": 1,
            "comparison": {
                "tables": "exact lexical-name set",
                "columns": "exact ordinal list",
                "constraints": "exact lexical-name list using normalized logical definitions",
                "indexes": "exact lexical-name list using normalized expressions, order, uniqueness, and predicates",
                "canonical_data": "exact key-sorted rows for declared canonical data",
            },
            "allowed_extras": {"tables": [], "columns": [], "constraints": [], "indexes": [], "canonical_data": []},
            "tables": tables,
            "canonical_data": self._canonical_data(cursor),
        }

    def _table(self, cursor: Cursor, table_oid: int) -> dict[str, Any]:
        cursor.execute(
            "SELECT a.attnum, a.attname, format_type(a.atttypid, NULL), a.attnotnull, "
            "pg_get_expr(ad.adbin, ad.adrelid), a.atttypmod, a.attgenerated, "
            "CASE WHEN a.atttypid = 1700 THEN ((a.atttypmod - 4) >> 16) END, "
            "CASE WHEN a.atttypid = 1700 THEN ((a.atttypmod - 4) & 65535) END "
            "FROM pg_attribute a LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum "
            "WHERE a.attrelid = %s AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum",
            (table_oid,),
        )
        rows = cursor.fetchall()
        names = {int(row[0]): str(row[1]) for row in rows}
        columns = [
            {
                "name": str(name), "type": str(data_type), "nullable": not bool(not_null),
                "default": _normalize_expression(default) if generated == "" else None if default is None else _normalize_expression(default),
                "precision": int(precision) if precision is not None else None,
                "scale": int(scale) if scale is not None else None,
                "generated": _normalize_expression(default) if generated else None,
            }
            for _number, name, data_type, not_null, default, _typmod, generated, precision, scale in rows
        ]
        cursor.execute(
            "SELECT conname, contype, conkey, confrelid, confkey, confupdtype, confdeltype, pg_get_constraintdef(oid, true) "
            "FROM pg_constraint WHERE conrelid = %s ORDER BY conname",
            (table_oid,),
        )
        constraints = []
        for name, kind, conkey, ref_oid, confkey, update, delete, definition in cursor.fetchall():
            constraint_kind = {"p": "primary_key", "f": "foreign_key", "u": "unique", "c": "check"}.get(str(kind))
            if constraint_kind is None:
                raise SchemaContractExtractionError("unsupported constraint kind")
            entry: dict[str, Any] = {
                "name": str(name), "kind": constraint_kind, "columns": _constraint_columns(list(conkey or []), names),
                "definition": "", "references": None, "on_update": None, "on_delete": None,
            }
            if constraint_kind == "foreign_key":
                cursor.execute(
                    "SELECT c.relname, array_agg(a.attname ORDER BY x.ordinality) "
                    "FROM pg_class c JOIN unnest(%s::smallint[]) WITH ORDINALITY x(attnum, ordinality) ON true "
                    "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = x.attnum WHERE c.oid = %s GROUP BY c.relname",
                    (list(confkey or []), ref_oid),
                )
                referenced = cursor.fetchone()
                if referenced is None:
                    raise SchemaContractExtractionError("foreign key target unavailable")
                entry["references"] = {"table": referenced[0], "columns": list(referenced[1])}
                entry["on_update"] = {"a": "NO ACTION", "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL", "d": "SET DEFAULT"}[update]
                entry["on_delete"] = {"a": "NO ACTION", "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL", "d": "SET DEFAULT"}[delete]
                entry["definition"] = f"FOREIGN KEY ({', '.join(entry['columns'])}) REFERENCES propertymanager.{referenced[0]} ({', '.join(referenced[1])})"
            elif constraint_kind == "primary_key":
                entry["definition"] = f"PRIMARY KEY ({', '.join(entry['columns'])})"
            elif constraint_kind == "unique":
                entry["definition"] = f"UNIQUE ({', '.join(entry['columns'])})"
            else:
                entry["columns"].sort()
                entry["definition"] = _normalize_check(str(definition))
            constraints.append(entry)
        cursor.execute(
            "SELECT i.relname, ix.indexrelid, ix.indisunique, am.amname, array_length(ix.indkey, 1), ix.indoption, pg_get_expr(ix.indpred, ix.indrelid) "
            "FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_am am ON am.oid = i.relam "
            "WHERE ix.indrelid = %s ORDER BY i.relname",
            (table_oid,),
        )
        indexes = []
        for name, index_oid, unique, method, key_count, options, predicate in cursor.fetchall():
            if method not in {"btree", "gin"}:
                raise SchemaContractExtractionError("unsupported index method")
            if isinstance(options, str):
                options = re.findall(r"\d+", options)
            keys = []
            for position in range(1, int(key_count) + 1):
                cursor.execute("SELECT pg_get_indexdef(%s, %s, true)", (index_oid, position))
                rendered = str(cursor.fetchone()[0])
                words = rendered.rsplit(" ", 1)
                descending = bool(int(options[position - 1]) & 1)
                keys.append({"expression": _normalize_expression(words[0]), "order": "DESC" if descending else "ASC"})
            normalized_predicate = _strip_wrapping(predicate)
            if normalized_predicate is not None:
                normalized_predicate = normalized_predicate.replace(") AND (", " AND ")
            indexes.append({"name": str(name), "unique": bool(unique), "method": str(method), "keys": keys, "predicate": normalized_predicate})
        return {"columns": columns, "constraints": constraints, "indexes": indexes}

    def _canonical_data(self, cursor: Cursor) -> dict[str, Any]:
        data: dict[str, Any] = {}
        for table, spec in CANONICAL_DATA.items():
            columns, key = spec["columns"], spec["key"]
            if table != "maintenance_categories":
                raise SchemaContractExtractionError("unknown canonical data declaration")
            cursor.execute(
                "SELECT id, name, icon, color_name, is_built_in, sort_order "
                "FROM propertymanager.maintenance_categories ORDER BY id"
            )
            data[table] = {"key": list(key), "columns": list(columns), "rows": [list(row) for row in cursor.fetchall()]}
        return data
