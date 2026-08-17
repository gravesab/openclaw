#!/usr/bin/env python3
"""Fail-closed, audit-only PropertyManager migration authority verifier."""

from __future__ import annotations

import argparse
import enum
import hashlib
import json
import math
import os
import re
import stat
import unicodedata
from collections.abc import Mapping, Sequence, Set
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

MODULE_PATH = Path(__file__).absolute()
CANONICAL_MIGRATION_DIR = MODULE_PATH.parent
CANONICAL_MANIFEST = CANONICAL_MIGRATION_DIR / "migration_authority.json"

# Current inputs total under 50 KiB. These leave ample growth room while bounding work.
MAX_MANIFEST_BYTES = 1 * 1024 * 1024
MAX_MIGRATION_BYTES = 2 * 1024 * 1024
MAX_TOTAL_MIGRATION_BYTES = 8 * 1024 * 1024
MAX_TRAVERSAL_DEPTH = 8
MAX_DISCOVERED_ENTRIES = 512
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 20_000
MAX_TEXT_CHARS = 16_384
MAX_REPORT_TEXT_CHARS = 4_096
MAX_REPORT_DIAGNOSTICS = 64
EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

EXACT_MIGRATION = re.compile(r"^(?P<version>[0-9]{3})_[a-z0-9_]+\.sql$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER = re.compile(r"^[a-z][a-z0-9_]*$")
DIAGNOSTIC_CODE = re.compile(r"^[a-z][a-z0-9_]*$")
URL = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s,;]+")
BEARER = re.compile(r"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+")
SECRET = re.compile(
    r"(?i)\b(password|passwd|pwd|username|user|secret|token|credential|api[_-]?key|passphrase)"
    r"(\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"
)
QUERY_SECRET = re.compile(
    r"(?i)([?&](?:password|passwd|pwd|username|user|secret|token|credential|api[_-]?key|passphrase)=)"
    r"[^&#\s]+"
)
ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9])/(?!/)[^\s,;]+")
WINDOWS_UNC_PATH = re.compile(r"(?<!\\)\\\\[^\s,;]+")
WINDOWS_PATH = re.compile(r"(?i)(?<![A-Za-z0-9])[a-z]:\\[^\s,;]+")
SENSITIVE_KEYS = re.compile(
    r"(?i)(password|passwd|pwd|username|user|secret|token|credential|api[_-]?key|passphrase|authorization)"
)
VAGUE_IDENTITIES = frozenset(
    {"unknown", "unspecified", "unverified", "default", "none", "null", "n/a", "na", "test", "database", "environment"}
)
MUTATING_ACTIONS = frozenset({"apply", "baseline", "bootstrap", "migrate", "repair", "write"})

MANIFEST_KEYS = frozenset(
    {"format_version", "authority", "canonical_migrations", "reserved_versions", "next_canonical_version", "schema_contract"}
)
MIGRATION_KEYS = frozenset({"version", "order", "filename", "sha256", "reapplication_permitted"})
RESERVED_KEYS = frozenset({"version", "status", "reason"})
CONTRACT_KEYS = frozenset({"normalization_version", "comparison", "allowed_extras", "tables", "canonical_data"})
COMPARISON_KEYS = frozenset({"tables", "columns", "constraints", "indexes", "canonical_data"})
TABLE_KEYS = frozenset({"columns", "constraints", "indexes"})
COLUMN_KEYS = frozenset({"name", "type", "nullable", "default", "precision", "scale", "generated"})
CONSTRAINT_KEYS = frozenset({"name", "kind", "columns", "definition", "references", "on_update", "on_delete"})
REFERENCE_KEYS = frozenset({"table", "columns"})
INDEX_KEYS = frozenset({"name", "unique", "method", "keys", "predicate"})
INDEX_KEY_KEYS = frozenset({"expression", "order"})
SEED_KEYS = frozenset({"columns", "key", "rows"})
SNAPSHOT_KEYS = frozenset(
    {"declared_version", "concurrent_migration_activity", "unexplained_schema_objects", "identity", "ledger", "schema"}
)
IDENTITY_KEYS = frozenset({"database_name", "environment"})
LEDGER_KEYS = frozenset({"state", "entries"})
LEDGER_ENTRY_KEYS = frozenset({"order", "version", "filename", "sha256"})


class AuthorityConfigurationError(ValueError):
    """The authority manifest is invalid or ambiguous."""


class MutationForbiddenError(PermissionError):
    """The audit-only verifier was asked to mutate state."""


class BoundedInputError(ValueError):
    """Input exceeded a deterministic verifier resource bound."""


class UnsafeAuthorityObjectError(OSError):
    """An authority filesystem object could not be proven safe and stable."""


class AuditStatus(str, enum.Enum):
    MIGRATION_FILES_VERIFIED = "migration_files_verified"
    MIGRATION_FILES_INVALID = "migration_files_invalid"
    SNAPSHOT_CONSISTENT = "snapshot_consistent_001_010"
    SNAPSHOT_PARTIAL = "snapshot_partial"
    SNAPSHOT_AMBIGUOUS = "snapshot_ambiguous"
    SNAPSHOT_LATER = "snapshot_later_than_authorized"
    SNAPSHOT_INCONSISTENT = "snapshot_inconsistent"
    DATABASE_IDENTITY_UNPROVEN = "database_identity_unproven"
    LEDGER_INCONSISTENT = "ledger_inconsistent"
    AUTHORITY_UNAVAILABLE = "authority_unavailable"


SUCCESS_STATUSES = frozenset({AuditStatus.MIGRATION_FILES_VERIFIED, AuditStatus.SNAPSHOT_CONSISTENT})
SNAPSHOT_STATUSES = frozenset(
    {
        AuditStatus.SNAPSHOT_CONSISTENT,
        AuditStatus.SNAPSHOT_PARTIAL,
        AuditStatus.SNAPSHOT_AMBIGUOUS,
        AuditStatus.SNAPSHOT_LATER,
        AuditStatus.SNAPSHOT_INCONSISTENT,
        AuditStatus.DATABASE_IDENTITY_UNPROVEN,
        AuditStatus.LEDGER_INCONSISTENT,
    }
)


class SchemaMetadataSource(Protocol):
    """Caller-controlled trust boundary for supplied metadata.

    ``inspect_read_only`` is only a method name. Python cannot mechanically
    guarantee that an arbitrary implementation is read-only. This verifier
    supplies no database, network, subprocess, container, or SQL adapter.
    """

    def inspect_read_only(self) -> Mapping[str, Any]: ...


@dataclass(frozen=True)
class ExpectedIdentity:
    database_name: str
    environment: str


@dataclass(frozen=True)
class MigrationSpec:
    version: str
    order: int
    filename: str
    sha256: str
    reapplication_permitted: bool


@dataclass(frozen=True)
class AuthorityManifest:
    canonical: tuple[MigrationSpec, ...]
    reserved_versions: tuple[str, ...]
    next_canonical_version: str
    schema_contract: Mapping[str, Any]


@dataclass(frozen=True)
class Diagnostic:
    code: str
    message: str

    def __post_init__(self) -> None:
        if type(self.code) is not str or DIAGNOSTIC_CODE.fullmatch(self.code) is None:
            raise TypeError("invalid diagnostic code")
        if type(self.message) is not str:
            raise TypeError("invalid diagnostic message")

    def as_dict(self) -> dict[str, str]:
        return {"code": sanitize_line(self.code), "message": sanitize_line(self.message)}


@dataclass(frozen=True)
class AuditResult:
    status: AuditStatus
    canonical_versions: tuple[str, ...]
    reserved_versions: tuple[str, ...]
    next_canonical_version: str
    diagnostics: tuple[Diagnostic, ...] = ()
    identity_assurance: str = "not_applicable"

    def __post_init__(self) -> None:
        if not isinstance(self.status, AuditStatus):
            raise TypeError("status must be an AuditStatus")
        if type(self.canonical_versions) is not tuple or any(
            type(item) is not str or re.fullmatch(r"[0-9]{3}", item) is None for item in self.canonical_versions
        ):
            raise TypeError("invalid canonical versions")
        if type(self.reserved_versions) is not tuple or any(
            type(item) is not str or re.fullmatch(r"[0-9]{3}", item) is None for item in self.reserved_versions
        ):
            raise TypeError("invalid reserved versions")
        if self.next_canonical_version != "unknown" and (
            type(self.next_canonical_version) is not str
            or re.fullmatch(r"[0-9]{3}", self.next_canonical_version) is None
        ):
            raise TypeError("invalid next canonical version")
        if (
            type(self.diagnostics) is not tuple
            or len(self.diagnostics) > MAX_REPORT_DIAGNOSTICS
            or any(type(item) is not Diagnostic for item in self.diagnostics)
        ):
            raise TypeError("invalid diagnostics")
        if self.identity_assurance not in {"not_applicable", "unproven"}:
            raise TypeError("invalid identity assurance")
        if self.status in SNAPSHOT_STATUSES and self.identity_assurance != "unproven":
            raise TypeError("snapshot status requires unproven identity")
        if self.status in {AuditStatus.MIGRATION_FILES_VERIFIED, AuditStatus.MIGRATION_FILES_INVALID} and self.identity_assurance != "not_applicable":
            raise TypeError("file status cannot claim identity")

    @property
    def ok(self) -> bool:
        return self.status in SUCCESS_STATUSES

    def as_dict(self) -> dict[str, Any]:
        return {
            "format_version": 1,
            "status": self.status.value,
            "ok": self.ok,
            "identity_assurance": sanitize_line(self.identity_assurance),
            "canonical_versions": [sanitize_line(item) for item in self.canonical_versions],
            "reserved_versions": [sanitize_line(item) for item in self.reserved_versions],
            "next_canonical_version": sanitize_line(self.next_canonical_version),
            "diagnostics": [item.as_dict() for item in self.diagnostics],
        }

    def machine_report(self) -> str:
        return json.dumps(redact_value(self.as_dict()), sort_keys=True, separators=(",", ":"))

    def human_report(self) -> str:
        values = self.as_dict()
        lines = [
            "PropertyManager migration authority audit",
            f"status: {values['status']}",
            f"successful: {'yes' if values['ok'] else 'no'}",
            f"identity assurance: {values['identity_assurance']}",
            f"canonical: {', '.join(values['canonical_versions'])}",
            f"reserved: {', '.join(values['reserved_versions'])}",
            f"next canonical: {values['next_canonical_version']}",
        ]
        lines.extend(f"{item['code']}: {item['message']}" for item in values["diagnostics"])
        return "\n".join(lines)


def _strip_unsafe_unicode(value: str) -> str:
    return "".join(
        " " if unicodedata.category(character) in {"Cc", "Cf", "Cs"} or character in {"\u2028", "\u2029"} else character
        for character in value
    )


def sanitize_line(value: Any) -> str:
    try:
        raw = str(value)
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return "[UNAVAILABLE]"
    truncated = len(raw) > MAX_REPORT_TEXT_CHARS
    text = _strip_unsafe_unicode(raw[:MAX_REPORT_TEXT_CHARS])
    text = URL.sub("[REDACTED_URL]", text)
    text = BEARER.sub(r"\1[REDACTED]", text)
    text = QUERY_SECRET.sub(r"\1[REDACTED]", text)
    text = SECRET.sub(r"\1\2[REDACTED]", text)
    text = WINDOWS_UNC_PATH.sub("[REDACTED_PATH]", text)
    text = WINDOWS_PATH.sub("[REDACTED_PATH]", text)
    text = ABSOLUTE_PATH.sub("[REDACTED_PATH]", text)
    return text + ("[TRUNCATED]" if truncated else "")


def redact_value(
    value: Any,
    *,
    key: str = "",
    _depth: int = 0,
    _counter: list[int] | None = None,
) -> Any:
    try:
        if _counter is None:
            _counter = [0]
        _counter[0] += 1
        if _depth > MAX_JSON_DEPTH or _counter[0] > MAX_JSON_NODES:
            return "[REDACTED_BOUNDED]"
        if SENSITIVE_KEYS.search(sanitize_line(key)):
            return "[REDACTED]"
        if isinstance(value, Mapping):
            items = list(value.items())
            items.sort(key=lambda item: sanitize_line(item[0]))
            return {
                sanitize_line(item_key): redact_value(
                    item_value,
                    key=sanitize_line(item_key),
                    _depth=_depth + 1,
                    _counter=_counter,
                )
                for item_key, item_value in items
            }
        if isinstance(value, (list, tuple)):
            return [
                redact_value(item, _depth=_depth + 1, _counter=_counter)
                for item in value
            ]
        if isinstance(value, Set) and not isinstance(value, (str, bytes, bytearray)):
            return sorted(
                (redact_value(item, _depth=_depth + 1, _counter=_counter) for item in value),
                key=repr,
            )
        if isinstance(value, (str, bytes, bytearray, BaseException)):
            return sanitize_line(value)
        return value
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return "[REDACTED_UNAVAILABLE]"


def reject_mutation(action: str) -> None:
    if type(action) is not str:
        raise MutationForbiddenError("non-text action is forbidden")
    normalized = action.strip().lower()
    if normalized != "audit":
        raise MutationForbiddenError(f"action {sanitize_line(normalized)!r} is forbidden")


def _require_exact_keys(value: Any, expected: frozenset[str], field: str) -> dict[str, Any]:
    if type(value) is not dict or set(value) != expected:
        raise AuthorityConfigurationError(f"{field} keys are invalid")
    return value


def _validate_plain_json(value: Any, *, depth: int = 0, counter: list[int] | None = None) -> None:
    if counter is None:
        counter = [0]
    counter[0] += 1
    if counter[0] > MAX_JSON_NODES or depth > MAX_JSON_DEPTH:
        raise BoundedInputError("structured input exceeds bounds")
    if value is None or type(value) in {bool, int}:
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise AuthorityConfigurationError("non-finite number is invalid")
        return
    if type(value) is str:
        if len(value) > MAX_TEXT_CHARS:
            raise BoundedInputError("text input exceeds bounds")
        return
    if type(value) is list:
        for item in value:
            _validate_plain_json(item, depth=depth + 1, counter=counter)
        return
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str or len(key) > MAX_TEXT_CHARS:
                raise AuthorityConfigurationError("mapping key is invalid")
            _validate_plain_json(item, depth=depth + 1, counter=counter)
        return
    raise AuthorityConfigurationError("non-JSON-safe value is invalid")


def _safe_contract_text(value: Any, field: str, *, identifier: bool = False) -> str:
    if type(value) is not str or not value or len(value) > MAX_TEXT_CHARS or _contains_unsafe_identity_char(value):
        raise AuthorityConfigurationError(f"{field} text is invalid")
    if identifier and IDENTIFIER.fullmatch(value) is None:
        raise AuthorityConfigurationError(f"{field} identifier is invalid")
    return value


def _contains_unsafe_identity_char(value: str) -> bool:
    return any(
        unicodedata.category(character) in {"Cc", "Cf", "Cs"} or character in {"\u2028", "\u2029"}
        for character in value
    )


def _identity_valid(value: Any) -> bool:
    return (
        type(value) is str
        and bool(value)
        and value == value.strip()
        and len(value) <= 255
        and not _contains_unsafe_identity_char(value)
        and value.casefold() not in VAGUE_IDENTITIES
    )


def _expected_identity_values(value: Any) -> tuple[str, str] | None:
    if type(value) is not ExpectedIdentity:
        return None
    try:
        database_name = value.database_name
        environment = value.environment
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return None
    if not _identity_valid(database_name) or not _identity_valid(environment):
        return None
    return database_name, environment


def _no_symlink_components(path: Path) -> bool:
    current = Path(path.anchor) if path.is_absolute() else Path.cwd()
    parts = path.parts[1:] if path.is_absolute() else path.parts
    try:
        for part in parts:
            current = current / part
            if stat.S_ISLNK(os.lstat(current).st_mode):
                return False
        return True
    except (OSError, TypeError, ValueError, RecursionError):
        return False


def _directory_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _file_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _open_directory(path: Path) -> int:
    if not isinstance(path, Path) or not _no_symlink_components(path):
        raise UnsafeAuthorityObjectError("unsafe authority directory")
    before = os.lstat(path)
    if not stat.S_ISDIR(before.st_mode):
        raise UnsafeAuthorityObjectError("authority directory is not regular")
    required_flags = getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    if (
        not hasattr(os, "O_DIRECTORY")
        or not hasattr(os, "O_NOFOLLOW")
        or os.open not in os.supports_dir_fd
        or os.stat not in os.supports_dir_fd
    ):
        raise UnsafeAuthorityObjectError("descriptor-relative authority checks unavailable")
    descriptor = os.open(path, os.O_RDONLY | required_flags)
    opened = os.fstat(descriptor)
    after = os.lstat(path)
    if not stat.S_ISDIR(opened.st_mode) or not (
        _directory_identity(before) == _directory_identity(opened) == _directory_identity(after)
    ):
        os.close(descriptor)
        raise UnsafeAuthorityObjectError("authority directory changed")
    return descriptor


def _verify_directory_path(path: Path, descriptor: int) -> None:
    if not _no_symlink_components(path):
        raise UnsafeAuthorityObjectError("authority directory became unsafe")
    opened = os.fstat(descriptor)
    current = os.lstat(path)
    if _directory_identity(opened) != _directory_identity(current):
        raise UnsafeAuthorityObjectError("authority directory was replaced")


def _read_regular_at(
    directory_fd: int,
    name: str,
    *,
    max_bytes: int,
    _post_open: Any = None,
    _post_read: Any = None,
) -> bytes:
    if type(name) is not str or not name or "/" in name or "\x00" in name:
        raise UnsafeAuthorityObjectError("unsafe authority object name")
    before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise UnsafeAuthorityObjectError("authority object is not a single-link regular file")
    if before.st_size > max_bytes:
        raise BoundedInputError("authority object exceeds byte limit")
    flags = os.O_RDONLY | os.O_NOFOLLOW
    descriptor = os.open(name, flags, dir_fd=directory_fd)
    try:
        opened_before = os.fstat(descriptor)
        if _post_open is not None:
            _post_open()
        if _file_identity(before) != _file_identity(opened_before):
            raise UnsafeAuthorityObjectError("authority object changed before open")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, max_bytes - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise BoundedInputError("authority object exceeds byte limit")
            chunks.append(chunk)
        if _post_read is not None:
            _post_read()
        opened_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not (_file_identity(before) == _file_identity(opened_after) == _file_identity(after)):
        raise UnsafeAuthorityObjectError("authority object changed during read")
    return b"".join(chunks)


def _read_regular_file(
    path: Path,
    *,
    max_bytes: int | None = None,
    _post_open: Any = None,
    _post_read: Any = None,
) -> bytes:
    if not isinstance(path, Path):
        raise UnsafeAuthorityObjectError("unsafe authority path")
    descriptor = _open_directory(path.parent)
    try:
        data = _read_regular_at(
            descriptor,
            path.name,
            max_bytes=MAX_MIGRATION_BYTES if max_bytes is None else max_bytes,
            _post_open=_post_open,
            _post_read=_post_read,
        )
        _verify_directory_path(path.parent, descriptor)
        return data
    finally:
        os.close(descriptor)


def _migration_like(name: str) -> bool:
    stripped = name.lstrip(".#~")
    return bool(stripped and stripped[0].isascii() and stripped[0].isdigit() and ".sql" in stripped.casefold())


def _scan_migration_tree(
    root_fd: int,
) -> tuple[list[str], list[str], tuple[tuple[str, str, tuple[int, int, int, int, int, int, int]], ...]]:
    direct: list[str] = []
    invalid: list[str] = []
    inventory: list[tuple[str, str, tuple[int, int, int, int, int, int, int]]] = []
    discovered = 0
    root_before = os.fstat(root_fd)

    def walk(directory_fd: int, depth: int, prefix: str) -> None:
        nonlocal discovered
        entries = []
        with os.scandir(directory_fd) as iterator:
            for entry in iterator:
                discovered += 1
                if discovered > MAX_DISCOVERED_ENTRIES:
                    raise BoundedInputError("authority directory exceeds entry limit")
                entries.append(entry)
        for entry in sorted(entries, key=lambda item: item.name):
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError:
                invalid.append("authority_entry_unavailable")
                continue
            relative_name = f"{prefix}/{entry.name}" if prefix else entry.name
            if stat.S_ISREG(info.st_mode):
                object_type = "regular"
            elif stat.S_ISDIR(info.st_mode):
                object_type = "directory"
            elif stat.S_ISLNK(info.st_mode):
                object_type = "symlink"
            else:
                object_type = "other"
            inventory.append((relative_name, object_type, _file_identity(info)))
            looks_like = _migration_like(entry.name)
            if looks_like:
                if depth != 0 or EXACT_MIGRATION.fullmatch(entry.name) is None or not stat.S_ISREG(info.st_mode):
                    invalid.append("unexpected_migration_object")
                else:
                    direct.append(entry.name)
            if stat.S_ISDIR(info.st_mode):
                if depth >= MAX_TRAVERSAL_DEPTH:
                    raise BoundedInputError("authority directory exceeds depth limit")
                child = os.open(
                    entry.name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
                try:
                    opened = os.fstat(child)
                    if _directory_identity(info) != _directory_identity(opened):
                        raise UnsafeAuthorityObjectError("nested authority directory changed")
                    walk(child, depth + 1, relative_name)
                    if _directory_identity(info) != _directory_identity(os.fstat(child)):
                        raise UnsafeAuthorityObjectError("nested authority directory changed during discovery")
                finally:
                    os.close(child)
            elif stat.S_ISLNK(info.st_mode):
                invalid.append("unexpected_symlink_object")

    walk(root_fd, 0, "")
    if _directory_identity(root_before) != _directory_identity(os.fstat(root_fd)):
        raise UnsafeAuthorityObjectError("authority directory changed during discovery")
    return direct, invalid, tuple(inventory)


def _validate_named_objects(value: Any, field: str) -> list[dict[str, Any]]:
    if type(value) is not list:
        raise AuthorityConfigurationError(f"{field} must be a list")
    names: list[str] = []
    for item in value:
        if type(item) is not dict:
            raise AuthorityConfigurationError(f"{field} entry is invalid")
        names.append(_safe_contract_text(item.get("name"), f"{field}.name", identifier=True))
    if names != sorted(names) or len(names) != len(set(names)):
        raise AuthorityConfigurationError(f"{field} must be uniquely name-sorted")
    return value


def _validate_contract(contract: Any) -> dict[str, Any]:
    contract = _require_exact_keys(contract, CONTRACT_KEYS, "schema contract")
    if type(contract["normalization_version"]) is not int or contract["normalization_version"] != 1:
        raise AuthorityConfigurationError("schema normalization version is invalid")
    comparison = _require_exact_keys(contract["comparison"], COMPARISON_KEYS, "schema comparison")
    for key in sorted(COMPARISON_KEYS):
        _safe_contract_text(comparison[key], f"comparison.{key}")
    allowed = _require_exact_keys(contract["allowed_extras"], COMPARISON_KEYS, "allowed extras")
    if any(allowed[key] != [] for key in COMPARISON_KEYS):
        raise AuthorityConfigurationError("allowed extras must be explicitly empty")
    tables = contract["tables"]
    if type(tables) is not dict or not tables or list(tables) != sorted(tables):
        raise AuthorityConfigurationError("schema tables must be name-sorted")
    for table, raw_spec in tables.items():
        _safe_contract_text(table, "table", identifier=True)
        spec = _require_exact_keys(raw_spec, TABLE_KEYS, f"table {table}")
        columns = spec["columns"]
        if type(columns) is not list or not columns:
            raise AuthorityConfigurationError("columns must be an ordinal list")
        column_names: list[str] = []
        for raw_column in columns:
            column = _require_exact_keys(raw_column, COLUMN_KEYS, "column")
            column_names.append(_safe_contract_text(column["name"], "column.name", identifier=True))
            _safe_contract_text(column["type"], "column.type")
            if type(column["nullable"]) is not bool:
                raise AuthorityConfigurationError("column nullability is invalid")
            if column["default"] is not None:
                _safe_contract_text(column["default"], "column.default")
            for numeric_field in ("precision", "scale"):
                value = column[numeric_field]
                if value is not None and (type(value) is not int or value < 0):
                    raise AuthorityConfigurationError(f"column {numeric_field} is invalid")
            if column["generated"] is not None:
                _safe_contract_text(column["generated"], "column.generated")
        if len(column_names) != len(set(column_names)):
            raise AuthorityConfigurationError("duplicate column fingerprint")
        constraints = _validate_named_objects(spec["constraints"], f"{table}.constraints")
        indexes = _validate_named_objects(spec["indexes"], f"{table}.indexes")
        for raw_constraint in constraints:
            constraint = _require_exact_keys(raw_constraint, CONSTRAINT_KEYS, "constraint")
            if constraint["kind"] not in {"primary_key", "foreign_key", "unique", "check"}:
                raise AuthorityConfigurationError("constraint kind is invalid")
            if type(constraint["columns"]) is not list or not constraint["columns"]:
                raise AuthorityConfigurationError("constraint columns are invalid")
            for column_name in constraint["columns"]:
                _safe_contract_text(column_name, "constraint column", identifier=True)
            _safe_contract_text(constraint["definition"], "constraint definition")
            reference = constraint["references"]
            if constraint["kind"] == "foreign_key":
                reference = _require_exact_keys(reference, REFERENCE_KEYS, "foreign-key reference")
                _safe_contract_text(reference["table"], "foreign-key table", identifier=True)
                if type(reference["columns"]) is not list or not reference["columns"]:
                    raise AuthorityConfigurationError("foreign-key columns are invalid")
                for column_name in reference["columns"]:
                    _safe_contract_text(column_name, "foreign-key column", identifier=True)
                if constraint["on_update"] not in {"NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"}:
                    raise AuthorityConfigurationError("foreign-key update action is invalid")
                if constraint["on_delete"] not in {"NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"}:
                    raise AuthorityConfigurationError("foreign-key delete action is invalid")
            elif reference is not None or constraint["on_update"] is not None or constraint["on_delete"] is not None:
                raise AuthorityConfigurationError("non-foreign constraint actions are invalid")
        for raw_index in indexes:
            index = _require_exact_keys(raw_index, INDEX_KEYS, "index")
            if type(index["unique"]) is not bool or index["method"] != "btree":
                raise AuthorityConfigurationError("index method or uniqueness is invalid")
            keys = index["keys"]
            if type(keys) is not list or not keys:
                raise AuthorityConfigurationError("index keys are invalid")
            for raw_key in keys:
                key = _require_exact_keys(raw_key, INDEX_KEY_KEYS, "index key")
                _safe_contract_text(key["expression"], "index expression")
                if key["order"] not in {"ASC", "DESC"}:
                    raise AuthorityConfigurationError("index order is invalid")
            if index["predicate"] is not None:
                _safe_contract_text(index["predicate"], "index predicate")
    canonical_data = contract["canonical_data"]
    if type(canonical_data) is not dict:
        raise AuthorityConfigurationError("canonical data is invalid")
    for table, raw_data in canonical_data.items():
        if table not in tables:
            raise AuthorityConfigurationError("canonical data table is unknown")
        data = _require_exact_keys(raw_data, SEED_KEYS, "canonical data")
        if type(data["columns"]) is not list or type(data["key"]) is not list or type(data["rows"]) is not list:
            raise AuthorityConfigurationError("canonical data collections are invalid")
        for name in data["columns"] + data["key"]:
            _safe_contract_text(name, "canonical data column", identifier=True)
        if not data["key"] or not set(data["key"]) <= set(data["columns"]):
            raise AuthorityConfigurationError("canonical data key is invalid")
        if any(type(row) is not list or len(row) != len(data["columns"]) for row in data["rows"]):
            raise AuthorityConfigurationError("canonical data row is invalid")
        key_indexes = [data["columns"].index(name) for name in data["key"]]
        keys = [tuple(row[index] for index in key_indexes) for row in data["rows"]]
        if keys != sorted(keys) or len(keys) != len(set(keys)):
            raise AuthorityConfigurationError("canonical data rows are not uniquely key-sorted")
    return contract


def _parse_manifest(data: bytes) -> AuthorityManifest:
    try:
        raw = json.loads(
            data.decode("utf-8"),
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
        )
        _validate_plain_json(raw)
        raw = _require_exact_keys(raw, MANIFEST_KEYS, "manifest")
        if type(raw["format_version"]) is not int or raw["format_version"] != 2 or raw["authority"] != "propertymanager":
            raise AuthorityConfigurationError("authority manifest version is invalid")
        entries = raw["canonical_migrations"]
        expected_versions = ("001", "002", "003", "004", "005", "006", "009", "010")
        if type(entries) is not list or len(entries) != len(expected_versions):
            raise AuthorityConfigurationError("canonical migration list is invalid")
        canonical: list[MigrationSpec] = []
        for position, raw_entry in enumerate(entries, 1):
            entry = _require_exact_keys(raw_entry, MIGRATION_KEYS, "migration")
            spec = MigrationSpec(
                entry["version"], entry["order"], entry["filename"], entry["sha256"], entry["reapplication_permitted"]
            )
            if (
                type(spec.version) is not str
                or spec.version != expected_versions[position - 1]
                or type(spec.order) is not int
                or spec.order != position
                or type(spec.filename) is not str
                or (match := EXACT_MIGRATION.fullmatch(spec.filename)) is None
                or match.group("version") != spec.version
                or type(spec.sha256) is not str
                or SHA256.fullmatch(spec.sha256) is None
                or type(spec.reapplication_permitted) is not bool
            ):
                raise AuthorityConfigurationError("canonical migration entry is invalid")
            canonical.append(spec)
        reserved = raw["reserved_versions"]
        if type(reserved) is not list or len(reserved) != 2:
            raise AuthorityConfigurationError("reserved migration list is invalid")
        reserved_versions: list[str] = []
        for raw_entry in reserved:
            entry = _require_exact_keys(raw_entry, RESERVED_KEYS, "reserved migration")
            if type(entry["version"]) is not str or entry["status"] != "noncanonical_forbidden":
                raise AuthorityConfigurationError("reserved migration entry is invalid")
            _safe_contract_text(entry["reason"], "reserved migration reason")
            reserved_versions.append(entry["version"])
        if reserved_versions != ["007", "008"] or raw["next_canonical_version"] != "011":
            raise AuthorityConfigurationError("reserved or next migration version is invalid")
        return AuthorityManifest(tuple(canonical), ("007", "008"), "011", _validate_contract(raw["schema_contract"]))
    except AuthorityConfigurationError:
        raise
    except (BoundedInputError, MemoryError, RecursionError, TypeError, ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise AuthorityConfigurationError("authority manifest is malformed") from exc


def _load_manifest_at(path: Path) -> AuthorityManifest:
    try:
        return _parse_manifest(_read_regular_file(path, max_bytes=MAX_MANIFEST_BYTES))
    except AuthorityConfigurationError:
        raise
    except (BoundedInputError, MemoryError, OSError, RecursionError, TypeError, ValueError, UnicodeError) as exc:
        raise AuthorityConfigurationError("authority manifest unavailable") from exc


def load_manifest() -> AuthorityManifest:
    """Load only the repository-pinned production authority manifest."""
    return _load_manifest_at(CANONICAL_MANIFEST)


def _result(
    status: AuditStatus,
    manifest: AuthorityManifest | None,
    diagnostics: Sequence[Diagnostic] = (),
    *,
    identity_assurance: str = "not_applicable",
) -> AuditResult:
    canonical = tuple(spec.version for spec in manifest.canonical) if manifest else ()
    reserved = manifest.reserved_versions if manifest else ()
    next_version = manifest.next_canonical_version if manifest else "unknown"
    return AuditResult(status, canonical, reserved, next_version, tuple(diagnostics), identity_assurance)


def _audit_migration_authority_at(
    directory: Path,
    manifest_path: Path,
    *,
    _post_inventory: Any = None,
) -> tuple[AuditResult, AuthorityManifest | None]:
    manifest: AuthorityManifest | None = None
    directory_fd: int | None = None
    phase = "opening"
    try:
        if not isinstance(directory, Path) or not isinstance(manifest_path, Path):
            raise UnsafeAuthorityObjectError("authority paths are invalid")
        directory = directory.absolute()
        manifest_path = manifest_path.absolute()
        if manifest_path.parent != directory:
            raise UnsafeAuthorityObjectError("manifest is outside authority directory")
        directory_fd = _open_directory(directory)
        phase = "inventory"
        found, invalid, initial_inventory = _scan_migration_tree(directory_fd)
        phase = "manifest"
        manifest = _parse_manifest(
            _read_regular_at(directory_fd, manifest_path.name, max_bytes=MAX_MANIFEST_BYTES)
        )
        phase = "verification"
        if _post_inventory is not None:
            _post_inventory()
        expected = {spec.filename: spec for spec in manifest.canonical}
        actual = set(found)
        diagnostics = [
            Diagnostic(code, "migration authority contains an invalid object")
            for code in invalid[: MAX_REPORT_DIAGNOSTICS - 1]
        ]
        if len(invalid) >= MAX_REPORT_DIAGNOSTICS:
            diagnostics.append(Diagnostic("authority_invalid_objects_truncated", "additional invalid objects omitted"))
        if actual != set(expected):
            diagnostics.append(Diagnostic("migration_set_mismatch", "canonical migration set is not exact"))
        total_bytes = 0
        initial_files = {
            name: identity
            for name, object_type, identity in initial_inventory
            if object_type == "regular" and "/" not in name
        }
        candidates = manifest.canonical if not diagnostics else ()
        for spec in candidates:
            name = spec.filename
            remaining = MAX_TOTAL_MIGRATION_BYTES - total_bytes
            initial_identity = initial_files.get(name)
            initial_size = initial_identity[4] if initial_identity is not None else None
            if type(initial_size) is not int or initial_size < 0 or initial_size > MAX_MIGRATION_BYTES or initial_size > remaining:
                diagnostics.append(Diagnostic("migration_size_invalid", "canonical migration input exceeds bounds"))
                break
            if remaining == 0:
                if (
                    initial_identity is None
                    or initial_size != 0
                    or initial_identity[3] != 1
                    or not stat.S_ISREG(initial_identity[2])
                ):
                    diagnostics.append(Diagnostic("migration_size_invalid", "canonical migration input exceeds bounds"))
                    break
                if spec.sha256 != EMPTY_SHA256:
                    diagnostics.append(Diagnostic("migration_checksum_mismatch", "canonical migration checksum differs"))
                    break
                continue
            try:
                data = _read_regular_at(directory_fd, name, max_bytes=min(MAX_MIGRATION_BYTES, remaining))
                total_bytes += len(data)
                if hashlib.sha256(data).hexdigest() != spec.sha256:
                    diagnostics.append(Diagnostic("migration_checksum_mismatch", "canonical migration checksum differs"))
                    break
            except BoundedInputError:
                diagnostics.append(Diagnostic("migration_size_invalid", "canonical migration input exceeds bounds"))
                break
            except (MemoryError, OSError, RecursionError, TypeError, ValueError):
                diagnostics.append(Diagnostic("migration_read_failed", "canonical migration could not be read safely"))
                break
        final_found, final_invalid, final_inventory = _scan_migration_tree(directory_fd)
        if (
            initial_inventory != final_inventory
            or found != final_found
            or invalid != final_invalid
        ):
            diagnostics.append(Diagnostic("authority_inventory_changed", "migration authority changed during verification"))
        _verify_directory_path(directory, directory_fd)
        if diagnostics:
            return _result(AuditStatus.MIGRATION_FILES_INVALID, manifest, diagnostics), manifest
        return _result(AuditStatus.MIGRATION_FILES_VERIFIED, manifest), manifest
    except BoundedInputError:
        status = (
            AuditStatus.MIGRATION_FILES_INVALID
            if manifest is not None or phase == "inventory"
            else AuditStatus.AUTHORITY_UNAVAILABLE
        )
        return _result(status, manifest, (Diagnostic("authority_bounds_exceeded", "authority input exceeds bounds"),)), manifest
    except (AuthorityConfigurationError, MemoryError, OSError, RecursionError, TypeError, ValueError, UnicodeError):
        return (
            _result(
                AuditStatus.AUTHORITY_UNAVAILABLE,
                manifest,
                (Diagnostic("authority_unavailable", "canonical authority could not be read safely"),),
            ),
            manifest,
        )
    finally:
        if directory_fd is not None:
            os.close(directory_fd)


def _audit_migration_files_at(
    directory: Path,
    manifest_path: Path,
    *,
    _post_inventory: Any = None,
) -> AuditResult:
    result, _manifest = _audit_migration_authority_at(
        directory,
        manifest_path,
        _post_inventory=_post_inventory,
    )
    return result


def audit_canonical_migration_files() -> AuditResult:
    try:
        result, _manifest = _audit_migration_authority_at(CANONICAL_MIGRATION_DIR, CANONICAL_MANIFEST)
        return result
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return _result(
            AuditStatus.AUTHORITY_UNAVAILABLE,
            None,
            (Diagnostic("authority_unavailable", "canonical authority could not be read safely"),),
        )


def _schema_key_classification(expected: dict[str, Any], supplied: dict[str, Any]) -> AuditStatus | None:
    missing = set(expected) - set(supplied)
    extra = set(supplied) - set(expected)
    if missing:
        return AuditStatus.SNAPSHOT_PARTIAL
    if extra:
        return AuditStatus.SNAPSHOT_LATER
    return None


def _classify_schema(expected: Mapping[str, Any], supplied: Any) -> AuditStatus | None:
    try:
        if type(expected) is not dict or type(supplied) is not dict:
            return AuditStatus.SNAPSHOT_AMBIGUOUS
        key_status = _schema_key_classification(expected, supplied)
        if key_status:
            return key_status
        for key in ("normalization_version", "comparison", "allowed_extras"):
            if supplied[key] != expected[key]:
                return AuditStatus.SNAPSHOT_INCONSISTENT
        expected_tables, supplied_tables = expected["tables"], supplied["tables"]
        if type(supplied_tables) is not dict:
            return AuditStatus.SNAPSHOT_AMBIGUOUS
        key_status = _schema_key_classification(expected_tables, supplied_tables)
        if key_status:
            return key_status
        for table in sorted(expected_tables):
            wanted_table, actual_table = expected_tables[table], supplied_tables[table]
            if type(actual_table) is not dict:
                return AuditStatus.SNAPSHOT_AMBIGUOUS
            key_status = _schema_key_classification(wanted_table, actual_table)
            if key_status:
                return key_status
            for collection in ("columns", "constraints", "indexes"):
                wanted, actual = wanted_table[collection], actual_table[collection]
                if type(actual) is not list:
                    return AuditStatus.SNAPSHOT_AMBIGUOUS
                wanted_names = [item["name"] for item in wanted]
                actual_names = []
                for item in actual:
                    if type(item) is not dict or type(item.get("name")) is not str:
                        return AuditStatus.SNAPSHOT_AMBIGUOUS
                    actual_names.append(item["name"])
                if len(actual_names) != len(set(actual_names)):
                    return AuditStatus.SNAPSHOT_AMBIGUOUS
                if set(wanted_names) - set(actual_names):
                    return AuditStatus.SNAPSHOT_PARTIAL
                if set(actual_names) - set(wanted_names):
                    return AuditStatus.SNAPSHOT_LATER
                if actual != wanted:
                    return AuditStatus.SNAPSHOT_INCONSISTENT
        expected_data, supplied_data = expected["canonical_data"], supplied["canonical_data"]
        if type(supplied_data) is not dict:
            return AuditStatus.SNAPSHOT_AMBIGUOUS
        key_status = _schema_key_classification(expected_data, supplied_data)
        if key_status:
            return key_status
        if supplied_data != expected_data:
            return AuditStatus.SNAPSHOT_INCONSISTENT
        return None
    except (MemoryError, RecursionError, TypeError, ValueError, KeyError):
        return AuditStatus.SNAPSHOT_AMBIGUOUS


def _classify_ledger(manifest: AuthorityManifest, ledger: Any) -> AuditStatus | None:
    try:
        if type(ledger) is not dict or set(ledger) != LEDGER_KEYS:
            return AuditStatus.LEDGER_INCONSISTENT
        state, entries = ledger["state"], ledger["entries"]
        if state not in {"absent", "present"} or type(entries) is not list:
            return AuditStatus.LEDGER_INCONSISTENT
        if state == "absent":
            return None if entries == [] else AuditStatus.LEDGER_INCONSISTENT
        for entry in entries:
            if type(entry) is not dict or set(entry) != LEDGER_ENTRY_KEYS:
                return AuditStatus.LEDGER_INCONSISTENT
            if (
                type(entry["order"]) is not int
                or type(entry["version"]) is not str
                or re.fullmatch(r"[0-9]{3}", entry["version"]) is None
                or type(entry["filename"]) is not str
                or type(entry["sha256"]) is not str
            ):
                return AuditStatus.LEDGER_INCONSISTENT
            if entry["version"] > "010":
                return AuditStatus.SNAPSHOT_LATER
        expected = [
            {"order": spec.order, "version": spec.version, "filename": spec.filename, "sha256": spec.sha256}
            for spec in manifest.canonical
        ]
        return None if entries == expected else AuditStatus.LEDGER_INCONSISTENT
    except (MemoryError, RecursionError, TypeError, ValueError, KeyError):
        return AuditStatus.LEDGER_INCONSISTENT


def _audit_supplied_metadata(
    metadata: Any, expected_identity: ExpectedIdentity, manifest: AuthorityManifest
) -> AuditResult:
    assurance = "unproven"
    try:
        expected_values = _expected_identity_values(expected_identity)
        if expected_values is None:
            return _result(
                AuditStatus.DATABASE_IDENTITY_UNPROVEN,
                manifest,
                (Diagnostic("expected_identity_invalid", "expected database identity is invalid"),),
                identity_assurance=assurance,
            )
        expected_database_name, expected_environment = expected_values
        _validate_plain_json(metadata)
        if type(metadata) is not dict or set(metadata) != SNAPSHOT_KEYS:
            return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
        identity = metadata["identity"]
        if type(identity) is not dict or set(identity) != IDENTITY_KEYS:
            return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
        database_name, environment = identity["database_name"], identity["environment"]
        if not _identity_valid(database_name) or not _identity_valid(environment):
            return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
        if database_name != expected_database_name or environment != expected_environment:
            return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
        for field in ("concurrent_migration_activity", "unexplained_schema_objects"):
            if type(metadata[field]) is not bool or metadata[field]:
                return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
        declared = metadata["declared_version"]
        if type(declared) is not str or re.fullmatch(r"[0-9]{3}", declared) is None:
            return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
        if declared < "010":
            return _result(AuditStatus.SNAPSHOT_PARTIAL, manifest, identity_assurance=assurance)
        if declared > "010":
            return _result(AuditStatus.SNAPSHOT_LATER, manifest, identity_assurance=assurance)
        ledger_status = _classify_ledger(manifest, metadata["ledger"])
        if ledger_status:
            return _result(ledger_status, manifest, identity_assurance=assurance)
        schema_status = _classify_schema(manifest.schema_contract, metadata["schema"])
        if schema_status:
            return _result(schema_status, manifest, identity_assurance=assurance)
        return _result(AuditStatus.SNAPSHOT_CONSISTENT, manifest, identity_assurance=assurance)
    except (AuthorityConfigurationError, AttributeError, BoundedInputError, MemoryError, RecursionError, TypeError, ValueError, KeyError):
        return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)


def audit_schema_metadata(source: SchemaMetadataSource, expected_identity: ExpectedIdentity) -> AuditResult:
    """Compare an untrusted supplied snapshot; never verify a real database."""
    try:
        file_result, manifest = _audit_migration_authority_at(CANONICAL_MIGRATION_DIR, CANONICAL_MANIFEST)
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return _result(AuditStatus.AUTHORITY_UNAVAILABLE, None)
    if not file_result.ok:
        return file_result
    if manifest is None:
        return _result(AuditStatus.AUTHORITY_UNAVAILABLE, None)
    if _expected_identity_values(expected_identity) is None:
        return _result(
            AuditStatus.DATABASE_IDENTITY_UNPROVEN,
            manifest,
            (Diagnostic("expected_identity_invalid", "expected database identity is invalid"),),
            identity_assurance="unproven",
        )
    try:
        metadata = source.inspect_read_only()
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return _result(
            AuditStatus.AUTHORITY_UNAVAILABLE,
            manifest,
            (Diagnostic("metadata_unavailable", "supplied metadata unavailable"),),
            identity_assurance="unproven",
        )
    try:
        return _audit_supplied_metadata(metadata, expected_identity, manifest)
    except (BaseException,) as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        return _result(
            AuditStatus.SNAPSHOT_AMBIGUOUS,
            manifest,
            (Diagnostic("metadata_invalid", "supplied metadata is invalid"),),
            identity_assurance="unproven",
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Audit canonical PropertyManager migration files")
    parser.add_argument("action", nargs="?", default="audit", choices=("audit",))
    parser.add_argument("--format", choices=("human", "json"), default="human")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    reject_mutation(arguments.action)
    result = audit_canonical_migration_files()
    print(result.machine_report() if arguments.format == "json" else result.human_report())
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
