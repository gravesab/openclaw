#!/usr/bin/env python3
"""Fail-closed, audit-only PropertyManager migration authority verification.

This module deliberately has no database client, SQL executor, ledger writer,
or migration application path. A future read-only adapter may supply metadata
through ``SchemaMetadataSource``; the verifier can only classify that metadata.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Protocol, Sequence

DEFAULT_MANIFEST = Path(__file__).with_name("migration_authority.json")
DEFAULT_MIGRATION_DIR = Path(__file__).parent
NUMBERED_MIGRATION = re.compile(r"^(?P<version>[0-9]{3})_.+\.sql$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SENSITIVE_KEY_PARTS = ("credential", "dsn", "password", "secret", "token", "url")
MUTATING_ACTIONS = frozenset({"apply", "baseline", "bootstrap", "migrate", "repair", "write"})


class AuthorityConfigurationError(ValueError):
    """The authority manifest itself is invalid or ambiguous."""


class MutationForbiddenError(PermissionError):
    """A caller requested behavior this audit-only module cannot perform."""


class SchemaMetadataSource(Protocol):
    """Read-only boundary for future metadata adapters.

    Implementations return already-collected metadata. This package provides no
    network, database, container, or subprocess implementation.
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
    required_tables: tuple[str, ...]
    required_columns: Mapping[str, tuple[str, ...]]
    required_constraints: tuple[str, ...]


@dataclass(frozen=True)
class Diagnostic:
    code: str
    message: str

    def as_dict(self) -> dict[str, str]:
        return {"code": self.code, "message": redact_text(self.message)}


@dataclass(frozen=True)
class AuditResult:
    status: str
    ok: bool
    canonical_versions: tuple[str, ...]
    reserved_versions: tuple[str, ...]
    next_canonical_version: str
    diagnostics: tuple[Diagnostic, ...]
    identity: Mapping[str, str]

    def as_dict(self) -> dict[str, Any]:
        return {
            "canonical_versions": list(self.canonical_versions),
            "diagnostics": [item.as_dict() for item in self.diagnostics],
            "identity": redact_mapping(self.identity),
            "next_canonical_version": self.next_canonical_version,
            "ok": self.ok,
            "reserved_versions": list(self.reserved_versions),
            "status": self.status,
        }

    def machine_report(self) -> str:
        return json.dumps(self.as_dict(), sort_keys=True, separators=(",", ":"))

    def human_report(self) -> str:
        lines = [
            "PropertyManager migration authority audit",
            f"status: {self.status}",
            f"verified: {'yes' if self.ok else 'no'}",
            f"canonical: {', '.join(self.canonical_versions)}",
            f"reserved: {', '.join(self.reserved_versions)}",
            f"next canonical: {self.next_canonical_version}",
        ]
        if self.identity:
            safe_identity = redact_mapping(self.identity)
            for key in sorted(safe_identity):
                lines.append(f"identity {key}: {safe_identity[key]}")
        for diagnostic in self.diagnostics:
            safe = diagnostic.as_dict()
            lines.append(f"{safe['code']}: {safe['message']}")
        return "\n".join(lines)


def redact_text(value: Any) -> str:
    """Redact complete URLs and common inline credential forms."""
    text = str(value)
    text = re.sub(r"(?i)\b[a-z][a-z0-9+.-]*://[^\s,;]+", "[REDACTED_URL]", text)
    text = re.sub(
        r"(?i)\b(password|passwd|pwd|secret|token|credential|username|user)"
        r"\s*[:=]\s*[^\s,;]+",
        lambda match: f"{match.group(1)}=[REDACTED]",
        text,
    )
    return text


def redact_mapping(value: Mapping[str, Any]) -> dict[str, Any]:
    redacted: dict[str, Any] = {}
    for key in sorted(value):
        item = value[key]
        if any(part in key.lower() for part in SENSITIVE_KEY_PARTS):
            redacted[key] = "[REDACTED]"
        elif isinstance(item, Mapping):
            redacted[key] = redact_mapping(item)
        elif isinstance(item, list):
            redacted[key] = [redact_text(entry) for entry in item]
        else:
            redacted[key] = redact_text(item)
    return redacted


def reject_mutation(action: str) -> None:
    """Accept only audit; explicitly reject every write-oriented action."""
    normalized = action.strip().lower()
    if normalized != "audit":
        if normalized in MUTATING_ACTIONS:
            raise MutationForbiddenError(f"mutation action {normalized!r} is forbidden")
        raise MutationForbiddenError(f"unsupported action {normalized!r}; audit is the only action")


def _string_list(value: Any, *, field: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise AuthorityConfigurationError(f"{field} must be a list of non-empty strings")
    if len(set(value)) != len(value):
        raise AuthorityConfigurationError(f"{field} contains duplicates")
    return tuple(value)


def load_manifest(path: Path = DEFAULT_MANIFEST) -> AuthorityManifest:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if raw.get("format_version") != 1 or raw.get("authority") != "propertymanager":
        raise AuthorityConfigurationError("unsupported or wrong migration authority manifest")

    entries = raw.get("canonical_migrations")
    if not isinstance(entries, list) or not entries:
        raise AuthorityConfigurationError("canonical_migrations must be a non-empty list")

    canonical: list[MigrationSpec] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise AuthorityConfigurationError("canonical migration entry must be an object")
        try:
            spec = MigrationSpec(
                version=str(entry["version"]),
                order=int(entry["order"]),
                filename=str(entry["filename"]),
                sha256=str(entry["sha256"]),
                reapplication_permitted=entry["reapplication_permitted"],
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise AuthorityConfigurationError("invalid canonical migration entry") from exc
        if not re.fullmatch(r"[0-9]{3}", spec.version):
            raise AuthorityConfigurationError(f"invalid canonical version {spec.version!r}")
        if not SHA256_PATTERN.fullmatch(spec.sha256):
            raise AuthorityConfigurationError(f"invalid SHA-256 for version {spec.version}")
        if not isinstance(spec.reapplication_permitted, bool):
            raise AuthorityConfigurationError(
                f"reapplication_permitted must be boolean for version {spec.version}"
            )
        match = NUMBERED_MIGRATION.fullmatch(spec.filename)
        if match is None or match.group("version") != spec.version:
            raise AuthorityConfigurationError(
                f"filename/version mismatch for canonical version {spec.version}"
            )
        canonical.append(spec)

    versions = [spec.version for spec in canonical]
    orders = [spec.order for spec in canonical]
    if versions != [f"{value:03d}" for value in range(1, 7)]:
        raise AuthorityConfigurationError("canonical versions must be exactly ordered 001 through 006")
    if orders != list(range(1, 7)):
        raise AuthorityConfigurationError("canonical migration order must be exactly 1 through 6")
    if len({spec.filename for spec in canonical}) != len(canonical):
        raise AuthorityConfigurationError("canonical migration filenames contain duplicates")

    reserved_raw = raw.get("reserved_versions")
    if not isinstance(reserved_raw, list):
        raise AuthorityConfigurationError("reserved_versions must be a list")
    reserved: list[str] = []
    for entry in reserved_raw:
        if not isinstance(entry, dict):
            raise AuthorityConfigurationError("reserved version entry must be an object")
        version = str(entry.get("version", ""))
        if entry.get("status") != "noncanonical_forbidden":
            raise AuthorityConfigurationError(f"reserved version {version!r} is not forbidden")
        reserved.append(version)
    if reserved != ["007", "008"]:
        raise AuthorityConfigurationError("reserved versions must be exactly ordered 007 and 008")
    if set(reserved) & set(versions):
        raise AuthorityConfigurationError("a reserved version cannot be canonical")
    if raw.get("next_canonical_version") != "009":
        raise AuthorityConfigurationError("next canonical version must be 009")

    contract = raw.get("schema_contract")
    if not isinstance(contract, dict):
        raise AuthorityConfigurationError("schema_contract must be an object")
    required_columns_raw = contract.get("required_columns")
    if not isinstance(required_columns_raw, dict):
        raise AuthorityConfigurationError("required_columns must be an object")
    required_columns = {
        str(table): _string_list(columns, field=f"required_columns.{table}")
        for table, columns in sorted(required_columns_raw.items())
    }
    return AuthorityManifest(
        canonical=tuple(canonical),
        reserved_versions=tuple(reserved),
        next_canonical_version="009",
        required_tables=_string_list(contract.get("required_tables"), field="required_tables"),
        required_columns=required_columns,
        required_constraints=_string_list(
            contract.get("required_constraints"), field="required_constraints"
        ),
    )


def _result(
    manifest: AuthorityManifest,
    status: str,
    diagnostics: Sequence[Diagnostic],
    *,
    identity: Mapping[str, str] | None = None,
) -> AuditResult:
    ordered = tuple(sorted(diagnostics, key=lambda item: (item.code, item.message)))
    return AuditResult(
        status=status,
        ok=status == "verified_001_006",
        canonical_versions=tuple(spec.version for spec in manifest.canonical),
        reserved_versions=manifest.reserved_versions,
        next_canonical_version=manifest.next_canonical_version,
        diagnostics=ordered,
        identity=identity or {},
    )


def audit_migration_files(
    migration_dir: Path = DEFAULT_MIGRATION_DIR,
    manifest_path: Path = DEFAULT_MANIFEST,
) -> AuditResult:
    try:
        manifest = load_manifest(manifest_path)
    except (AuthorityConfigurationError, json.JSONDecodeError, OSError) as exc:
        empty = AuthorityManifest((), ("007", "008"), "009", (), {}, ())
        return _result(empty, "ambiguous_authority", [Diagnostic("manifest_invalid", str(exc))])

    discovered: list[tuple[str, str, Path]] = []
    for path in sorted(migration_dir.glob("[0-9][0-9][0-9]_*.sql"), key=lambda item: item.name):
        match = NUMBERED_MIGRATION.fullmatch(path.name)
        if match is not None:
            discovered.append((match.group("version"), path.name, path))

    diagnostics: list[Diagnostic] = []
    by_version: dict[str, list[tuple[str, Path]]] = {}
    for version, filename, path in discovered:
        by_version.setdefault(version, []).append((filename, path))
    for version, files in sorted(by_version.items()):
        if len(files) > 1:
            diagnostics.append(
                Diagnostic("duplicate_version", f"version {version} has {len(files)} migration files")
            )
        if version in manifest.reserved_versions:
            diagnostics.append(
                Diagnostic("reserved_version_present", f"forbidden reserved version {version} is present")
            )
        elif version not in {spec.version for spec in manifest.canonical}:
            diagnostics.append(
                Diagnostic("unexpected_version", f"unexpected numbered migration {version} is present")
            )

    checksum_drift = False
    for spec in manifest.canonical:
        candidates = by_version.get(spec.version, [])
        if not candidates:
            diagnostics.append(
                Diagnostic("missing_migration", f"canonical migration {spec.filename} is missing")
            )
            continue
        names = [name for name, _path in candidates]
        if spec.filename not in names:
            diagnostics.append(
                Diagnostic(
                    "renamed_migration",
                    f"canonical version {spec.version} must be named {spec.filename}",
                )
            )
            continue
        path = next(path for name, path in candidates if name == spec.filename)
        actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual_hash != spec.sha256:
            checksum_drift = True
            diagnostics.append(
                Diagnostic("checksum_drift", f"checksum differs for canonical migration {spec.filename}")
            )

    if diagnostics:
        if checksum_drift:
            status = "checksum_drift"
        elif any(item.code in {"reserved_version_present", "unexpected_version"} for item in diagnostics):
            status = "unexpected_later_schema"
        else:
            status = "ambiguous_authority"
        return _result(manifest, status, diagnostics)
    return _result(manifest, "verified_001_006", ())


def _metadata_collection(value: Any, field: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{field} must be a list of strings")
    if len(set(value)) != len(value):
        raise ValueError(f"{field} contains duplicates")
    return tuple(value)


def audit_schema_metadata(
    source: SchemaMetadataSource,
    expected_identity: ExpectedIdentity,
    *,
    migration_dir: Path = DEFAULT_MIGRATION_DIR,
    manifest_path: Path = DEFAULT_MANIFEST,
) -> AuditResult:
    file_result = audit_migration_files(migration_dir, manifest_path)
    if not file_result.ok:
        return file_result
    manifest = load_manifest(manifest_path)

    try:
        metadata = source.inspect_read_only()
    except Exception as exc:
        return _result(
            manifest,
            "identity_unavailable",
            [Diagnostic("metadata_unavailable", f"read-only metadata unavailable: {exc}")],
        )
    if not isinstance(metadata, Mapping):
        return _result(
            manifest,
            "ambiguous_schema",
            [Diagnostic("metadata_invalid", "read-only metadata must be an object")],
        )

    identity_raw = metadata.get("identity")
    if not isinstance(identity_raw, Mapping):
        return _result(
            manifest,
            "identity_unavailable",
            [Diagnostic("identity_unavailable", "database identity metadata is unavailable")],
        )
    safe_identity = {
        "database_name": str(identity_raw.get("database_name", "")),
        "environment": str(identity_raw.get("environment", "")),
    }
    if identity_raw.get("proven") is not True:
        return _result(
            manifest,
            "identity_unavailable",
            [Diagnostic("identity_unproven", "database identity could not be proven")],
            identity=safe_identity,
        )
    if (
        safe_identity["database_name"] != expected_identity.database_name
        or safe_identity["environment"] != expected_identity.environment
    ):
        return _result(
            manifest,
            "identity_unavailable",
            [Diagnostic("identity_mismatch", "observed database identity does not match expectation")],
            identity=safe_identity,
        )
    if metadata.get("concurrent_migration_activity") is True:
        return _result(
            manifest,
            "ambiguous_schema",
            [Diagnostic("concurrent_activity", "concurrent migration activity makes the audit ambiguous")],
            identity=safe_identity,
        )

    try:
        declared_version = str(metadata.get("declared_version", "006"))
        if not re.fullmatch(r"[0-9]{3}", declared_version):
            raise ValueError("declared_version must be a three-digit string")
        if int(declared_version) > 6:
            return _result(
                manifest,
                "unexpected_later_schema",
                [Diagnostic("unexpected_declared_version", f"unexpected schema version {declared_version}")],
                identity=safe_identity,
            )
        if int(declared_version) < 6:
            return _result(
                manifest,
                "partial_schema",
                [Diagnostic("partial_declared_version", f"schema reports version {declared_version}")],
                identity=safe_identity,
            )

        ledger_raw = metadata.get("ledger_entries", [])
        if not isinstance(ledger_raw, list):
            raise ValueError("ledger_entries must be a list")
        ledger: dict[str, str] = {}
        for entry in ledger_raw:
            if not isinstance(entry, Mapping):
                raise ValueError("ledger entry must be an object")
            version = str(entry.get("version", ""))
            checksum = str(entry.get("sha256", ""))
            if not re.fullmatch(r"[0-9]{3}", version) or not SHA256_PATTERN.fullmatch(checksum):
                raise ValueError("ledger entry has invalid version or checksum")
            if version in ledger:
                raise ValueError(f"ledger contains duplicate version {version}")
            ledger[version] = checksum
        higher = sorted(version for version in ledger if int(version) > 6)
        if higher:
            return _result(
                manifest,
                "unexpected_later_schema",
                [Diagnostic("unexpected_ledger_version", f"unexpected ledger version {higher[0]}")],
                identity=safe_identity,
            )
        if ledger:
            expected_versions = {spec.version for spec in manifest.canonical}
            if set(ledger) != expected_versions:
                return _result(
                    manifest,
                    "partial_schema",
                    [Diagnostic("partial_ledger", "ledger does not contain exactly canonical 001 through 006")],
                    identity=safe_identity,
                )
            drifted = [spec.filename for spec in manifest.canonical if ledger[spec.version] != spec.sha256]
            if drifted:
                return _result(
                    manifest,
                    "checksum_drift",
                    [Diagnostic("ledger_checksum_drift", f"ledger checksum differs for {name}") for name in drifted],
                    identity=safe_identity,
                )

        schema_raw = metadata.get("schema")
        if not isinstance(schema_raw, Mapping):
            raise ValueError("schema metadata must be an object")
        tables = set(_metadata_collection(schema_raw.get("tables"), "schema.tables"))
        constraints = set(
            _metadata_collection(schema_raw.get("constraints"), "schema.constraints")
        )
        columns_raw = schema_raw.get("columns")
        if not isinstance(columns_raw, Mapping):
            raise ValueError("schema.columns must be an object")
        columns = {
            str(table): set(_metadata_collection(values, f"schema.columns.{table}"))
            for table, values in columns_raw.items()
        }
    except (TypeError, ValueError) as exc:
        return _result(
            manifest,
            "ambiguous_schema",
            [Diagnostic("metadata_ambiguous", str(exc))],
            identity=safe_identity,
        )

    missing: list[str] = []
    for table in manifest.required_tables:
        if table not in tables:
            missing.append(f"table:{table}")
    for table, required in manifest.required_columns.items():
        actual = columns.get(table, set())
        missing.extend(f"column:{table}.{column}" for column in required if column not in actual)
    missing.extend(
        f"constraint:{constraint}"
        for constraint in manifest.required_constraints
        if constraint not in constraints
    )
    if missing:
        return _result(
            manifest,
            "partial_schema",
            [Diagnostic("schema_object_missing", item) for item in missing],
            identity=safe_identity,
        )
    if metadata.get("unexplained_schema_objects") is True:
        return _result(
            manifest,
            "ambiguous_schema",
            [Diagnostic("unexplained_schema_objects", "unexplained schema objects were reported")],
            identity=safe_identity,
        )
    return _result(manifest, "verified_001_006", (), identity=safe_identity)


class JsonFixtureMetadataSource:
    """Read metadata from a local JSON fixture; never opens a database connection."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def inspect_read_only(self) -> Mapping[str, Any]:
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(value, Mapping):
            raise ValueError("metadata fixture must contain a JSON object")
        return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", default="audit", choices=("audit",))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--migration-dir", type=Path, default=DEFAULT_MIGRATION_DIR)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--expected-database-name")
    parser.add_argument("--expected-environment")
    parser.add_argument("--format", choices=("human", "json"), default="human")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    reject_mutation(args.action)
    file_result = audit_migration_files(args.migration_dir, args.manifest)
    if not file_result.ok:
        result = file_result
    elif args.metadata is None:
        manifest = load_manifest(args.manifest)
        result = _result(
            manifest,
            "identity_unavailable",
            [Diagnostic("identity_unavailable", "metadata source and database identity are required")],
        )
    elif not args.expected_database_name or not args.expected_environment:
        manifest = load_manifest(args.manifest)
        result = _result(
            manifest,
            "identity_unavailable",
            [Diagnostic("identity_unavailable", "both expected identity fields are required")],
        )
    else:
        result = audit_schema_metadata(
            JsonFixtureMetadataSource(args.metadata),
            ExpectedIdentity(args.expected_database_name, args.expected_environment),
            migration_dir=args.migration_dir,
            manifest_path=args.manifest,
        )
    print(result.machine_report() if args.format == "json" else result.human_report())
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
