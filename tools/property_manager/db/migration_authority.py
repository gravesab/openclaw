#!/usr/bin/env python3
"""Fail-closed, audit-only PropertyManager migration authority verifier."""

from __future__ import annotations

import argparse
import enum
import hashlib
import json
import os
import re
import stat
from collections.abc import Mapping, Sequence, Set
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

MODULE_PATH = Path(__file__).absolute()
CANONICAL_MIGRATION_DIR = MODULE_PATH.parent
CANONICAL_MANIFEST = CANONICAL_MIGRATION_DIR / "migration_authority.json"
EXACT_MIGRATION = re.compile(r"^(?P<version>[0-9]{3})_[a-z0-9_]+\.sql$")
MIGRATION_LIKE = re.compile(r"^[0-9]+_.*\.sql$", re.IGNORECASE)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
URL = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s,;]+")
BEARER = re.compile(r"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+")
SECRET = re.compile(
    r"(?i)\b(password|passwd|pwd|username|user|token|credential|api[_-]?key|passphrase)"
    r"(\s*[:=]\s*)[^\s,;&]+"
)
QUERY_SECRET = re.compile(
    r"(?i)([?&](?:password|passwd|pwd|username|user|token|credential|api[_-]?key|passphrase)=)"
    r"[^&#\s]+"
)
ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9])/(?:[^/\s]+/)+[^\s,;]*")
SENSITIVE_KEYS = re.compile(
    r"(?i)(password|passwd|pwd|username|user|token|credential|api[_-]?key|passphrase|authorization)"
)
MUTATING_ACTIONS = frozenset({"apply", "baseline", "bootstrap", "migrate", "repair", "write"})


class AuthorityConfigurationError(ValueError):
    """The authority manifest is invalid or ambiguous."""


class MutationForbiddenError(PermissionError):
    """The audit-only verifier was asked to mutate state."""


class AuditStatus(str, enum.Enum):
    MIGRATION_FILES_VERIFIED = "migration_files_verified"
    MIGRATION_FILES_INVALID = "migration_files_invalid"
    SNAPSHOT_CONSISTENT = "snapshot_consistent_001_006"
    SNAPSHOT_PARTIAL = "snapshot_partial"
    SNAPSHOT_AMBIGUOUS = "snapshot_ambiguous"
    SNAPSHOT_LATER = "snapshot_later_than_authorized"
    SNAPSHOT_INCONSISTENT = "snapshot_inconsistent"
    DATABASE_IDENTITY_UNPROVEN = "database_identity_unproven"
    LEDGER_INCONSISTENT = "ledger_inconsistent"
    AUTHORITY_UNAVAILABLE = "authority_unavailable"


SUCCESS_STATUSES = frozenset(
    {AuditStatus.MIGRATION_FILES_VERIFIED, AuditStatus.SNAPSHOT_CONSISTENT}
)


class SchemaMetadataSource(Protocol):
    """Trust boundary for caller-supplied metadata.

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

    @property
    def ok(self) -> bool:
        return self.status in SUCCESS_STATUSES

    def as_dict(self) -> dict[str, Any]:
        return {
            "format_version": 1,
            "status": self.status.value,
            "ok": self.ok,
            "identity_assurance": self.identity_assurance,
            "canonical_versions": list(self.canonical_versions),
            "reserved_versions": list(self.reserved_versions),
            "next_canonical_version": self.next_canonical_version,
            "diagnostics": [item.as_dict() for item in self.diagnostics],
        }

    def machine_report(self) -> str:
        return json.dumps(redact_value(self.as_dict()), sort_keys=True, separators=(",", ":"))

    def human_report(self) -> str:
        lines = [
            "PropertyManager migration authority audit",
            f"status: {self.status.value}",
            f"successful: {'yes' if self.ok else 'no'}",
            f"identity assurance: {self.identity_assurance}",
            f"canonical: {', '.join(self.canonical_versions)}",
            f"reserved: {', '.join(self.reserved_versions)}",
            f"next canonical: {self.next_canonical_version}",
        ]
        lines.extend(
            f"{item.as_dict()['code']}: {item.as_dict()['message']}" for item in self.diagnostics
        )
        return "\n".join(lines)


def sanitize_line(value: Any) -> str:
    text = CONTROL.sub(" ", str(value))
    text = URL.sub("[REDACTED_URL]", text)
    text = BEARER.sub(r"\1[REDACTED]", text)
    text = QUERY_SECRET.sub(r"\1[REDACTED]", text)
    text = SECRET.sub(r"\1\2[REDACTED]", text)
    return ABSOLUTE_PATH.sub("[REDACTED_PATH]", text)


def redact_value(value: Any, *, key: str = "") -> Any:
    if SENSITIVE_KEYS.search(str(key)):
        return "[REDACTED]"
    if isinstance(value, Mapping):
        return {
            sanitize_line(item_key): redact_value(value[item_key], key=str(item_key))
            for item_key in sorted(value, key=lambda item: str(item))
        }
    if isinstance(value, (list, tuple)):
        return [redact_value(item) for item in value]
    if isinstance(value, Set) and not isinstance(value, (str, bytes, bytearray)):
        return sorted((redact_value(item) for item in value), key=lambda item: repr(item))
    if isinstance(value, (str, bytes, bytearray, BaseException)):
        return sanitize_line(value)
    return value


def reject_mutation(action: str) -> None:
    normalized = action.strip().lower()
    if normalized != "audit":
        raise MutationForbiddenError(f"action {sanitize_line(normalized)!r} is forbidden")


def _no_symlink_components(path: Path) -> bool:
    current = Path(path.anchor) if path.is_absolute() else Path.cwd()
    parts = path.parts[1:] if path.is_absolute() else path.parts
    try:
        for part in parts:
            current = current / part
            if stat.S_ISLNK(os.lstat(current).st_mode):
                return False
        return True
    except OSError:
        return False


def _read_regular_file(path: Path, *, _post_read: Any = None) -> bytes:
    if not _no_symlink_components(path):
        raise OSError("unsafe authority path")
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        raise OSError("authority object is not regular")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened_before = os.fstat(descriptor)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        if _post_read is not None:
            _post_read()
        opened_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after = os.lstat(path)
    fingerprint = lambda item: (
        item.st_dev,
        item.st_ino,
        item.st_mode,
        item.st_size,
        item.st_mtime_ns,
        item.st_ctime_ns,
    )
    if not (fingerprint(before) == fingerprint(opened_before) == fingerprint(opened_after) == fingerprint(after)):
        raise OSError("authority object changed during read")
    return b"".join(chunks)


def _validate_named_objects(value: Any, field: str) -> None:
    if not isinstance(value, list):
        raise AuthorityConfigurationError(f"{field} must be a list")
    names = []
    for item in value:
        if not isinstance(item, Mapping) or not isinstance(item.get("name"), str) or not item["name"]:
            raise AuthorityConfigurationError(f"{field} entry is invalid")
        names.append(item["name"])
    if names != sorted(names) or len(names) != len(set(names)):
        raise AuthorityConfigurationError(f"{field} must be uniquely name-sorted")


def _validate_contract(contract: Any) -> Mapping[str, Any]:
    if not isinstance(contract, Mapping) or contract.get("normalization_version") != 1:
        raise AuthorityConfigurationError("schema contract is invalid")
    allowed = contract.get("allowed_extras")
    if not isinstance(allowed, Mapping) or any(allowed.get(key) != [] for key in (
        "tables", "columns", "constraints", "indexes", "canonical_data"
    )):
        raise AuthorityConfigurationError("allowed extras must be explicitly empty")
    tables = contract.get("tables")
    if not isinstance(tables, Mapping) or list(tables) != sorted(tables) or not tables:
        raise AuthorityConfigurationError("schema tables must be name-sorted")
    for table, spec in tables.items():
        if not isinstance(spec, Mapping):
            raise AuthorityConfigurationError("table contract is invalid")
        columns = spec.get("columns")
        if not isinstance(columns, list) or not columns:
            raise AuthorityConfigurationError("columns must be an ordinal list")
        column_names = []
        for column in columns:
            required = {"name", "type", "nullable", "default", "precision", "scale", "generated"}
            if not isinstance(column, Mapping) or set(column) != required:
                raise AuthorityConfigurationError("column fingerprint is incomplete")
            if not isinstance(column["name"], str) or not isinstance(column["type"], str):
                raise AuthorityConfigurationError("column name/type is invalid")
            if not isinstance(column["nullable"], bool):
                raise AuthorityConfigurationError("column nullability is invalid")
            column_names.append(column["name"])
        if len(column_names) != len(set(column_names)):
            raise AuthorityConfigurationError("duplicate column fingerprint")
        _validate_named_objects(spec.get("constraints"), f"{table}.constraints")
        _validate_named_objects(spec.get("indexes"), f"{table}.indexes")
        for constraint in spec["constraints"]:
            if set(constraint) != {
                "name", "kind", "columns", "definition", "references", "on_update", "on_delete"
            }:
                raise AuthorityConfigurationError("constraint fingerprint is incomplete")
            if (
                constraint["kind"] not in {"primary_key", "foreign_key", "unique", "check"}
                or not isinstance(constraint["columns"], list)
                or not all(isinstance(item, str) and item for item in constraint["columns"])
                or not isinstance(constraint["definition"], str)
            ):
                raise AuthorityConfigurationError("constraint fingerprint is invalid")
            reference = constraint["references"]
            if reference is not None and (
                not isinstance(reference, Mapping)
                or set(reference) != {"table", "columns"}
                or not isinstance(reference["table"], str)
                or not isinstance(reference["columns"], list)
            ):
                raise AuthorityConfigurationError("foreign-key fingerprint is invalid")
        for index in spec["indexes"]:
            if set(index) != {"name", "unique", "method", "keys", "predicate"}:
                raise AuthorityConfigurationError("index fingerprint is incomplete")
            if (
                not isinstance(index["unique"], bool)
                or not isinstance(index["method"], str)
                or not isinstance(index["keys"], list)
                or not index["keys"]
            ):
                raise AuthorityConfigurationError("index fingerprint is invalid")
            for key in index["keys"]:
                if (
                    not isinstance(key, Mapping)
                    or set(key) != {"expression", "order"}
                    or not isinstance(key["expression"], str)
                    or key["order"] not in {"ASC", "DESC"}
                ):
                    raise AuthorityConfigurationError("index key fingerprint is invalid")
    canonical_data = contract.get("canonical_data")
    if not isinstance(canonical_data, Mapping):
        raise AuthorityConfigurationError("canonical data is invalid")
    for table, data in canonical_data.items():
        if (
            table not in tables
            or not isinstance(data, Mapping)
            or set(data) != {"columns", "key", "rows"}
            or not isinstance(data["columns"], list)
            or not isinstance(data["key"], list)
            or not isinstance(data["rows"], list)
            or any(not isinstance(row, list) or len(row) != len(data["columns"]) for row in data["rows"])
        ):
            raise AuthorityConfigurationError("canonical data fingerprint is incomplete")
    return contract


def _load_manifest_at(path: Path) -> AuthorityManifest:
    try:
        raw = json.loads(_read_regular_file(path).decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AuthorityConfigurationError("authority manifest unavailable") from exc
    if not isinstance(raw, Mapping) or raw.get("format_version") != 2 or raw.get("authority") != "propertymanager":
        raise AuthorityConfigurationError("authority manifest version is invalid")
    entries = raw.get("canonical_migrations")
    if not isinstance(entries, list) or len(entries) != 6:
        raise AuthorityConfigurationError("canonical migration list is invalid")
    canonical = []
    for position, entry in enumerate(entries, 1):
        if not isinstance(entry, Mapping) or set(entry) != {
            "version", "order", "filename", "sha256", "reapplication_permitted"
        }:
            raise AuthorityConfigurationError("canonical migration fingerprint is incomplete")
        spec = MigrationSpec(
            entry["version"], entry["order"], entry["filename"], entry["sha256"],
            entry["reapplication_permitted"],
        )
        if (
            spec.version != f"{position:03d}"
            or spec.order != position
            or not isinstance(spec.filename, str)
            or (match := EXACT_MIGRATION.fullmatch(spec.filename)) is None
            or match.group("version") != spec.version
            or not isinstance(spec.sha256, str)
            or SHA256.fullmatch(spec.sha256) is None
            or not isinstance(spec.reapplication_permitted, bool)
        ):
            raise AuthorityConfigurationError("canonical migration entry is invalid")
        canonical.append(spec)
    reserved = raw.get("reserved_versions")
    if not isinstance(reserved, list) or [item.get("version") for item in reserved if isinstance(item, Mapping)] != ["007", "008"]:
        raise AuthorityConfigurationError("reserved migration list is invalid")
    if any(item.get("status") != "noncanonical_forbidden" for item in reserved):
        raise AuthorityConfigurationError("reserved migration status is invalid")
    if raw.get("next_canonical_version") != "009":
        raise AuthorityConfigurationError("next canonical version is invalid")
    return AuthorityManifest(tuple(canonical), ("007", "008"), "009", _validate_contract(raw.get("schema_contract")))


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


def _walk_migration_like(directory: Path) -> tuple[list[Path], list[str]]:
    found: list[Path] = []
    invalid: list[str] = []

    def walk(current: Path, nested: bool) -> None:
        with os.scandir(current) as iterator:
            entries = sorted(iterator, key=lambda item: item.name)
        for entry in entries:
            name = entry.name
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError:
                invalid.append("authority_entry_unavailable")
                continue
            path = Path(entry.path)
            looks_like = bool(MIGRATION_LIKE.fullmatch(name))
            if looks_like:
                if nested or EXACT_MIGRATION.fullmatch(name) is None or not stat.S_ISREG(info.st_mode):
                    invalid.append("unexpected_migration_object")
                else:
                    found.append(path)
            if stat.S_ISDIR(info.st_mode):
                walk(path, True)
            elif stat.S_ISLNK(info.st_mode) and looks_like:
                invalid.append("unexpected_migration_object")

    walk(directory, False)
    return found, invalid


def _audit_migration_files_at(directory: Path, manifest_path: Path) -> AuditResult:
    manifest: AuthorityManifest | None = None
    try:
        manifest = _load_manifest_at(manifest_path)
        if not _no_symlink_components(directory) or not stat.S_ISDIR(os.lstat(directory).st_mode):
            raise OSError("unsafe authority directory")
        found, invalid = _walk_migration_like(directory)
        expected = {spec.filename: spec for spec in manifest.canonical}
        actual = {path.name: path for path in found}
        diagnostics = [Diagnostic(code, "migration authority contains an invalid object") for code in invalid]
        if set(actual) != set(expected):
            diagnostics.append(Diagnostic("migration_set_mismatch", "canonical migration set is not exact"))
        for name in sorted(set(actual) & set(expected)):
            try:
                digest = hashlib.sha256(_read_regular_file(actual[name])).hexdigest()
            except OSError:
                diagnostics.append(Diagnostic("migration_read_failed", "canonical migration could not be read safely"))
                continue
            if digest != expected[name].sha256:
                diagnostics.append(Diagnostic("migration_checksum_mismatch", "canonical migration checksum differs"))
        if diagnostics:
            return _result(AuditStatus.MIGRATION_FILES_INVALID, manifest, diagnostics)
        return _result(AuditStatus.MIGRATION_FILES_VERIFIED, manifest)
    except (AuthorityConfigurationError, OSError):
        return _result(
            AuditStatus.AUTHORITY_UNAVAILABLE,
            manifest,
            (Diagnostic("authority_unavailable", "canonical authority could not be read safely"),),
        )


def audit_canonical_migration_files() -> AuditResult:
    return _audit_migration_files_at(CANONICAL_MIGRATION_DIR, CANONICAL_MANIFEST)


def _identity_valid(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip()) and CONTROL.search(value) is None and len(value) <= 255


def _classify_schema(expected: Mapping[str, Any], supplied: Any) -> AuditStatus | None:
    if not isinstance(supplied, Mapping) or not isinstance(supplied.get("tables"), Mapping):
        return AuditStatus.SNAPSHOT_AMBIGUOUS
    expected_tables = expected["tables"]
    supplied_tables = supplied["tables"]
    missing = set(expected_tables) - set(supplied_tables)
    extra = set(supplied_tables) - set(expected_tables)
    if missing:
        return AuditStatus.SNAPSHOT_PARTIAL
    if extra:
        return AuditStatus.SNAPSHOT_LATER
    for table in sorted(expected_tables):
        actual_table = supplied_tables[table]
        if not isinstance(actual_table, Mapping):
            return AuditStatus.SNAPSHOT_AMBIGUOUS
        for collection in ("columns", "constraints", "indexes"):
            wanted = expected_tables[table][collection]
            actual = actual_table.get(collection)
            if not isinstance(actual, list):
                return AuditStatus.SNAPSHOT_AMBIGUOUS
            key = lambda item: item.get("name") if isinstance(item, Mapping) else None
            wanted_names, actual_names = [key(item) for item in wanted], [key(item) for item in actual]
            if any(name is None for name in actual_names) or len(actual_names) != len(set(actual_names)):
                return AuditStatus.SNAPSHOT_AMBIGUOUS
            if set(wanted_names) - set(actual_names):
                return AuditStatus.SNAPSHOT_PARTIAL
            if set(actual_names) - set(wanted_names):
                return AuditStatus.SNAPSHOT_LATER
            if actual != wanted:
                return AuditStatus.SNAPSHOT_INCONSISTENT
    supplied_data = supplied.get("canonical_data")
    expected_data = expected.get("canonical_data")
    if supplied_data is None:
        return AuditStatus.SNAPSHOT_AMBIGUOUS
    if supplied_data != expected_data:
        if isinstance(supplied_data, Mapping) and isinstance(expected_data, Mapping):
            if set(expected_data) - set(supplied_data):
                return AuditStatus.SNAPSHOT_PARTIAL
            if set(supplied_data) - set(expected_data):
                return AuditStatus.SNAPSHOT_LATER
        return AuditStatus.SNAPSHOT_INCONSISTENT
    return None


def _classify_ledger(manifest: AuthorityManifest, ledger: Any) -> AuditStatus | None:
    if not isinstance(ledger, Mapping) or ledger.get("state") not in {"absent", "present"}:
        return AuditStatus.LEDGER_INCONSISTENT
    entries = ledger.get("entries")
    if ledger["state"] == "absent":
        return None if entries == [] else AuditStatus.LEDGER_INCONSISTENT
    if not isinstance(entries, list):
        return AuditStatus.LEDGER_INCONSISTENT
    if any(isinstance(item, Mapping) and str(item.get("version", "")) > "006" for item in entries):
        return AuditStatus.SNAPSHOT_LATER
    expected = [
        {"order": spec.order, "version": spec.version, "filename": spec.filename, "sha256": spec.sha256}
        for spec in manifest.canonical
    ]
    return None if entries == expected else AuditStatus.LEDGER_INCONSISTENT


def _audit_supplied_metadata(
    metadata: Any, expected_identity: ExpectedIdentity, manifest: AuthorityManifest
) -> AuditResult:
    assurance = "unproven"
    if not _identity_valid(expected_identity.database_name) or not _identity_valid(expected_identity.environment):
        return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
    if not isinstance(metadata, Mapping):
        return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
    identity = metadata.get("identity")
    if not isinstance(identity, Mapping) or set(identity) != {"database_name", "environment"}:
        return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
    database_name, environment = identity.get("database_name"), identity.get("environment")
    if not _identity_valid(database_name) or not _identity_valid(environment):
        return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
    if database_name != expected_identity.database_name or environment != expected_identity.environment:
        return _result(AuditStatus.DATABASE_IDENTITY_UNPROVEN, manifest, identity_assurance=assurance)
    for field in ("concurrent_migration_activity", "unexplained_schema_objects"):
        if type(metadata.get(field)) is not bool:
            return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
        if metadata[field]:
            return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
    declared = metadata.get("declared_version")
    if not isinstance(declared, str) or re.fullmatch(r"[0-9]{3}", declared) is None:
        return _result(AuditStatus.SNAPSHOT_AMBIGUOUS, manifest, identity_assurance=assurance)
    if declared < "006":
        return _result(AuditStatus.SNAPSHOT_PARTIAL, manifest, identity_assurance=assurance)
    if declared > "006":
        return _result(AuditStatus.SNAPSHOT_LATER, manifest, identity_assurance=assurance)
    ledger_status = _classify_ledger(manifest, metadata.get("ledger"))
    if ledger_status:
        return _result(ledger_status, manifest, identity_assurance=assurance)
    schema_status = _classify_schema(manifest.schema_contract, metadata.get("schema"))
    if schema_status:
        return _result(schema_status, manifest, identity_assurance=assurance)
    return _result(AuditStatus.SNAPSHOT_CONSISTENT, manifest, identity_assurance=assurance)


def audit_schema_metadata(source: SchemaMetadataSource, expected_identity: ExpectedIdentity) -> AuditResult:
    """Compare an untrusted supplied snapshot; never verify a real database."""
    try:
        manifest = load_manifest()
    except AuthorityConfigurationError:
        return _result(AuditStatus.AUTHORITY_UNAVAILABLE, None)
    file_result = audit_canonical_migration_files()
    if not file_result.ok:
        return file_result
    try:
        metadata = source.inspect_read_only()
    except Exception:  # Boundary implementations are arbitrary and untrusted.
        return _result(
            AuditStatus.AUTHORITY_UNAVAILABLE,
            manifest,
            (Diagnostic("metadata_unavailable", "supplied metadata unavailable"),),
            identity_assurance="unproven",
        )
    return _audit_supplied_metadata(metadata, expected_identity, manifest)


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
