#!/usr/bin/env python3
"""Adversarial tests for the audit-only migration authority verifier."""

from __future__ import annotations

import ast
import copy
import hashlib
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from collections.abc import Mapping
from pathlib import Path
from unittest import mock

from tools.property_manager.db import migration_authority as authority

REPO_ROOT = Path(__file__).resolve().parents[3]
DB_DIR = REPO_ROOT / "tools" / "property_manager" / "db"
MANIFEST_PATH = DB_DIR / "migration_authority.json"
API_DIR = REPO_ROOT / "tools" / "property_manager" / "api"
APPROVED_HASHES = {
    "001_initial_schema.sql": "11b4427e5115cb159b1b48e0a2886ef1e9e04575f7455c26e2e4ba068021d84f",
    "002_rich_task_model.sql": "a60c5e604bc42d5331c2b77819e3976588d76b99ae25880eb8c85114f59d8ec2",
    "003_part_quantity.sql": "49365ba4d30ff4543ad3a48a9aa3a0b430aebb300c3d67e568c6a679bb218147",
    "004_task_origin.sql": "1e9a03e9cc383928c992638685df922a3bc6a28a4a54a8a8f18b98be0da6c40c",
    "005_assets_and_meters.sql": "f90a39cdc6234d72a431d4caba23720d98aa7b4dff1a83f15845ecb936ff0147",
    "006_phase1_meter_audit.sql": "3d5c09888b0ae9a4898a7497bf01bf2a46ccddbaf3236e94c804b5cf6cb521a0",
    "009_maintenance_proposals.sql": "9a4e8e530042861562a8c521d6b6daaa987b8bfb4baf093b49b70e5a3af4f17a",
    "010_handbook_ingestion_v1.sql": "17ba25449a4f3dc8f1f4137313930bfff6fcd213397493a01bc5bc6035230db5",
}
APPROVED_CONTRACT_HASH = "63063adf5396817e8fa8607a5ccb108cdc3d79a4f9c6a046e6068ee1a6f59a52"
APPROVED_EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
APPROVED_RESOURCE_LIMITS = {
    "MAX_MANIFEST_BYTES": 1 * 1024 * 1024,
    "MAX_MIGRATION_BYTES": 2 * 1024 * 1024,
    "MAX_TOTAL_MIGRATION_BYTES": 8 * 1024 * 1024,
    "MAX_TRAVERSAL_DEPTH": 8,
    "MAX_DISCOVERED_ENTRIES": 512,
    "MAX_JSON_DEPTH": 64,
    "MAX_JSON_NODES": 20_000,
    "MAX_TEXT_CHARS": 16_384,
}
APPROVED_REAPPLICATION = {
    "001": False,
    "002": False,
    "003": False,
    "004": False,
    "005": True,
    "006": True,
    "009": True,
    "010": False,
}
APPROVED_TABLES = (
    "asset_meter",
    "asset_meter_reading",
    "asset_task_mapping_proposals",
    "assets",
    "maintenance_categories",
    "maintenance_completions",
    "maintenance_proposals",
    "maintenance_task_parts",
    "maintenance_task_photos",
    "maintenance_tasks",
)


def column(name, data_type, nullable, default=None, precision=None, scale=None):
    return {
        "name": name,
        "type": data_type,
        "nullable": nullable,
        "default": default,
        "precision": precision,
        "scale": scale,
        "generated": None,
    }


def primary(name, *columns):
    return {
        "name": name,
        "kind": "primary_key",
        "columns": list(columns),
        "definition": f"PRIMARY KEY ({', '.join(columns)})",
        "references": None,
        "on_update": None,
        "on_delete": None,
    }


def unique(name, *columns):
    return {
        "name": name,
        "kind": "unique",
        "columns": list(columns),
        "definition": f"UNIQUE ({', '.join(columns)})",
        "references": None,
        "on_update": None,
        "on_delete": None,
    }


def foreign(name, columns, table, referenced, on_delete):
    return {
        "name": name,
        "kind": "foreign_key",
        "columns": list(columns),
        "definition": (
            f"FOREIGN KEY ({', '.join(columns)}) REFERENCES "
            f"propertymanager.{table} ({', '.join(referenced)})"
        ),
        "references": {"table": table, "columns": list(referenced)},
        "on_update": "NO ACTION",
        "on_delete": on_delete,
    }


def check(name, columns, definition):
    return {
        "name": name,
        "kind": "check",
        "columns": list(columns),
        "definition": definition,
        "references": None,
        "on_update": None,
        "on_delete": None,
    }


def index(name, unique_value, *keys, predicate=None):
    return {
        "name": name,
        "unique": unique_value,
        "method": "btree",
        "keys": [{"expression": expression, "order": order} for expression, order in keys],
        "predicate": predicate,
    }


# Hand-maintained oracle derived directly from 001_initial_schema.sql through
# 009_maintenance_proposals.sql. It must never be populated from the manifest.
EXPECTED_SCHEMA_ORACLE = {
    "normalization_version": 1,
    "comparison": {
        "tables": "exact lexical-name set",
        "columns": "exact ordinal list",
        "constraints": "exact lexical-name list using normalized logical definitions",
        "indexes": "exact lexical-name list using normalized expressions, order, uniqueness, and predicates",
        "canonical_data": "exact key-sorted rows for declared canonical data",
    },
    "allowed_extras": {
        "tables": [], "columns": [], "constraints": [], "indexes": [], "canonical_data": [],
    },
    "tables": {
        "asset_meter": {
            "columns": [
                column("asset_id", "uuid", False),
                column("meter_type", "text", False, "'none'"),
                column("current_value", "numeric", False, "0", 14, 3),
                column("unit", "text", False, "''"),
                column("latest_reading_at", "timestamp with time zone", True),
                column("updated_at", "timestamp with time zone", False, "now()"),
                column("meter_epoch", "integer", False, "1"),
                column("row_version", "integer", False, "1"),
            ],
            "constraints": [
                foreign("asset_meter_asset_id_fkey", ("asset_id",), "assets", ("id",), "CASCADE"),
                primary("asset_meter_pkey", "asset_id"),
                check("asset_meter_type_check", ("meter_type",), "CHECK (meter_type IN ('runtime_hours', 'mileage', 'cycles', 'none'))"),
            ],
            "indexes": [index("asset_meter_pkey", True, ("asset_id", "ASC"))],
        },
        "asset_meter_reading": {
            "columns": [
                column("id", "uuid", False),
                column("asset_id", "uuid", False),
                column("value", "numeric", False, None, 14, 3),
                column("reading_at", "timestamp with time zone", False, "now()"),
                column("entry_method", "text", False, "'manual'"),
                column("note", "text", True),
                column("correction_reason", "text", True),
                column("usage_since_previous", "numeric", True, None, 14, 3),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("previous_reading_id", "uuid", True),
                column("meter_type_at_entry", "text", True),
                column("unit_at_entry", "text", True),
                column("status", "text", False, "'accepted'"),
                column("operator_identity", "text", True),
                column("integration_identity", "text", True),
                column("idempotency_key", "text", True),
                column("meter_epoch", "integer", False, "1"),
                column("corrects_reading_id", "uuid", True),
            ],
            "constraints": [
                foreign("asset_meter_reading_asset_id_fkey", ("asset_id",), "assets", ("id",), "CASCADE"),
                check("asset_meter_reading_correction_reason_check", ("correction_reason",), "CHECK (correction_reason IS NULL OR correction_reason IN ('replacement', 'rollover', 'correction'))"),
                foreign("asset_meter_reading_corrects_reading_id_fkey", ("corrects_reading_id",), "asset_meter_reading", ("id",), "SET NULL"),
                check("asset_meter_reading_entry_method_check", ("entry_method",), "CHECK (entry_method IN ('manual', 'voice', 'qr', 'api', 'telegram', 'completion'))"),
                primary("asset_meter_reading_pkey", "id"),
                foreign("asset_meter_reading_previous_reading_id_fkey", ("previous_reading_id",), "asset_meter_reading", ("id",), "SET NULL"),
                check("asset_meter_reading_status_check", ("status",), "CHECK (status IN ('accepted', 'rejected', 'corrected'))"),
            ],
            "indexes": [
                index("asset_meter_reading_asset_epoch_reading_at_idx", False, ("asset_id", "ASC"), ("meter_epoch", "ASC"), ("reading_at", "ASC"), ("created_at", "ASC")),
                index("asset_meter_reading_asset_id_reading_at_idx", False, ("asset_id", "ASC"), ("reading_at", "DESC")),
                index("asset_meter_reading_idempotency_idx", True, ("asset_id", "ASC"), ("idempotency_key", "ASC"), predicate="idempotency_key IS NOT NULL AND status = 'accepted'"),
                index("asset_meter_reading_pkey", True, ("id", "ASC")),
                index("asset_meter_reading_status_idx", False, ("asset_id", "ASC"), ("status", "ASC"), predicate="status = 'accepted'"),
            ],
        },
        "asset_task_mapping_proposals": {
            "columns": [
                column("id", "uuid", False),
                column("ranchbrain_task_ref", "text", False),
                column("task_id", "uuid", True),
                column("proposed_asset_id", "uuid", False),
                column("match_rationale", "text", False, "''"),
                column("confidence", "numeric", False, "0", 5, 4),
                column("status", "text", False, "'pending'"),
                column("reviewed_by", "text", True),
                column("reviewed_at", "timestamp with time zone", True),
                column("created_at", "timestamp with time zone", False, "now()"),
            ],
            "constraints": [
                primary("asset_task_mapping_proposals_pkey", "id"),
                foreign("asset_task_mapping_proposals_proposed_asset_id_fkey", ("proposed_asset_id",), "assets", ("id",), "CASCADE"),
                check("asset_task_mapping_proposals_status_check", ("status",), "CHECK (status IN ('pending', 'approved', 'rejected'))"),
                foreign("asset_task_mapping_proposals_task_id_fkey", ("task_id",), "maintenance_tasks", ("id",), "SET NULL"),
            ],
            "indexes": [
                index("asset_task_mapping_proposals_pkey", True, ("id", "ASC")),
                index("asset_task_mapping_proposals_status_idx", False, ("status", "ASC"), ("confidence", "DESC")),
                index("asset_task_mapping_proposals_task_asset_pending_idx", True, ("ranchbrain_task_ref", "ASC"), ("proposed_asset_id", "ASC"), predicate="status = 'pending'"),
            ],
        },
        "assets": {
            "columns": [
                column("id", "uuid", False), column("external_id", "text", False),
                column("ranchbrain_guid", "uuid", True), column("name", "text", False),
                column("manufacturer", "text", False, "''"), column("model", "text", False, "''"),
                column("category", "text", False, "''"), column("location", "text", False, "''"),
                column("aliases", "jsonb", False, "'[]'::jsonb"), column("qr_token", "text", False),
                column("is_active", "boolean", False, "true"),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("updated_at", "timestamp with time zone", False, "now()"),
                column("meter_proposed_type", "text", True), column("meter_proposed_unit", "text", True),
                column("meter_activated_at", "timestamp with time zone", True),
            ],
            "constraints": [
                unique("assets_external_id_key", "external_id"), primary("assets_pkey", "id"),
                unique("assets_qr_token_key", "qr_token"),
            ],
            "indexes": [
                index("assets_external_id_idx", False, ("external_id", "ASC")),
                index("assets_external_id_key", True, ("external_id", "ASC")),
                index("assets_name_lower_idx", False, ("lower(name)", "ASC")),
                index("assets_pkey", True, ("id", "ASC")),
                index("assets_qr_token_idx", False, ("qr_token", "ASC")),
                index("assets_qr_token_key", True, ("qr_token", "ASC")),
            ],
        },
        "maintenance_categories": {
            "columns": [
                column("id", "uuid", False), column("name", "text", False),
                column("icon", "text", False), column("color_name", "text", False),
                column("is_built_in", "boolean", False, "false"), column("sort_order", "integer", False, "0"),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("updated_at", "timestamp with time zone", False, "now()"),
            ],
            "constraints": [unique("maintenance_categories_name_key", "name"), primary("maintenance_categories_pkey", "id")],
            "indexes": [
                index("maintenance_categories_name_key", True, ("name", "ASC")),
                index("maintenance_categories_pkey", True, ("id", "ASC")),
            ],
        },
        "maintenance_completions": {
            "columns": [
                column("id", "uuid", False), column("task_id", "uuid", False),
                column("completed_at", "timestamp with time zone", False), column("note", "text", True),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("meter_value_at_completion", "numeric", True, None, 14, 3),
                column("meter_reading_id", "uuid", True),
            ],
            "constraints": [
                foreign("maintenance_completions_meter_reading_id_fkey", ("meter_reading_id",), "asset_meter_reading", ("id",), "SET NULL"),
                primary("maintenance_completions_pkey", "id"),
                foreign("maintenance_completions_task_id_fkey", ("task_id",), "maintenance_tasks", ("id",), "CASCADE"),
            ],
            "indexes": [index("maintenance_completions_pkey", True, ("id", "ASC"))],
        },
        "maintenance_proposals": {
            "columns": [
                column("id", "uuid", False), column("proposal_version", "integer", False, "1"),
                column("operation_id", "text", False), column("schema_version", "text", False),
                column("source_evidence_ref", "text", False), column("provider", "text", False),
                column("model", "text", False), column("model_output", "jsonb", False),
                column("guardrail_actions", "jsonb", False, "'[]'::jsonb"),
                column("validation_status", "text", False), column("status", "text", False, "'pending'"),
                column("created_by", "text", False), column("integration_identity", "text", False),
                column("idempotency_key", "text", False), column("reviewed_by", "text", True),
                column("reviewed_at", "timestamp with time zone", True), column("rejection_reason", "text", True),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("updated_at", "timestamp with time zone", False, "now()"),
            ],
            "constraints": [
                check("maintenance_proposals_guardrail_actions_array_check", ("guardrail_actions",), "CHECK (jsonb_typeof(guardrail_actions) = 'array')"),
                check("maintenance_proposals_model_output_object_check", ("model_output",), "CHECK (jsonb_typeof(model_output) = 'object')"),
                primary("maintenance_proposals_pkey", "id"),
                check("maintenance_proposals_proposal_version_check", ("proposal_version",), "CHECK (proposal_version > 0)"),
                check("maintenance_proposals_review_check", ("reviewed_at", "reviewed_by", "status"), "CHECK ((status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL) OR (status IN ('confirmed', 'rejected') AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))"),
                check("maintenance_proposals_status_check", ("status",), "CHECK (status IN ('pending', 'confirmed', 'rejected'))"),
                check("maintenance_proposals_validation_status_check", ("validation_status",), "CHECK (validation_status = 'valid')"),
            ],
            "indexes": [
                index("maintenance_proposals_idempotency_idx", True, ("integration_identity", "ASC"), ("idempotency_key", "ASC")),
                index("maintenance_proposals_pkey", True, ("id", "ASC")),
                index("maintenance_proposals_review_queue_idx", False, ("status", "ASC"), ("created_at", "DESC")),
            ],
        },
        "maintenance_task_parts": {
            "columns": [
                column("id", "uuid", False), column("task_id", "uuid", False),
                column("name", "text", False, "''"), column("oem_part_number", "text", False, "''"),
                column("part_number", "text", False, "''"), column("buy_url", "text", False, "''"),
                column("cost", "numeric", False, "0", 10, 2), column("sort_order", "integer", False, "0"),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("updated_at", "timestamp with time zone", False, "now()"),
                column("quantity", "numeric", False, "1", 12, 3),
                column("vendor", "text", False, "''"), column("notes", "text", False, "''"),
            ],
            "constraints": [
                primary("maintenance_task_parts_pkey", "id"),
                foreign("maintenance_task_parts_task_id_fkey", ("task_id",), "maintenance_tasks", ("id",), "CASCADE"),
            ],
            "indexes": [
                index("maintenance_task_parts_pkey", True, ("id", "ASC")),
                index("maintenance_task_parts_task_id_idx", False, ("task_id", "ASC"), ("sort_order", "ASC")),
            ],
        },
        "maintenance_task_photos": {
            "columns": [
                column("id", "uuid", False), column("task_id", "uuid", False),
                column("file_name", "text", False), column("storage_path", "text", False),
                column("created_at", "timestamp with time zone", False, "now()"),
            ],
            "constraints": [
                primary("maintenance_task_photos_pkey", "id"),
                foreign("maintenance_task_photos_task_id_fkey", ("task_id",), "maintenance_tasks", ("id",), "CASCADE"),
            ],
            "indexes": [
                index("maintenance_task_photos_pkey", True, ("id", "ASC")),
                index("maintenance_task_photos_task_id_idx", False, ("task_id", "ASC"), ("created_at", "ASC")),
            ],
        },
        "maintenance_tasks": {
            "columns": [
                column("id", "uuid", False), column("area", "text", False), column("item", "text", False),
                column("category_name", "text", False, "'House'"), column("priority", "text", False, "'Medium'"),
                column("frequency", "text", False, "'As Needed'"), column("task_description", "text", True),
                column("response_instructions", "text", True), column("supplies_needed", "text", True),
                column("notes", "text", True), column("result_notes", "text", True),
                column("estimated_minutes", "integer", True), column("warning_days", "integer", False),
                column("critical_days", "integer", False), column("last_done", "timestamp with time zone", False),
                column("next_due", "timestamp with time zone", False),
                column("send_telegram_update", "boolean", False, "true"),
                column("include_in_daily_briefing", "boolean", False, "true"),
                column("alert_if_overdue", "boolean", False, "true"), column("is_active", "boolean", False, "true"),
                column("part_url", "text", True), column("vendor", "text", True), column("part_number", "text", True),
                column("part_cost", "numeric", True, None, 10, 2), column("annual_cost", "numeric", True, None, 10, 2),
                column("created_at", "timestamp with time zone", False, "now()"),
                column("updated_at", "timestamp with time zone", False, "now()"),
                column("kind", "text", False, "'Scheduled'"), column("manufacturer", "text", True),
                column("source_manual_name", "text", True), column("completion_history", "jsonb", False, "'[]'::jsonb"),
                column("tools_required", "jsonb", False, "'[]'::jsonb"), column("origin", "text", False, "'owner'"),
                column("asset_id", "uuid", True), column("schedule_kind", "text", False, "'calendar'"),
                column("meter_interval_value", "numeric", True, None, 14, 3), column("meter_interval_unit", "text", True),
                column("last_done_meter_value", "numeric", True, None, 14, 3),
                column("next_due_meter_value", "numeric", True, None, 14, 3),
            ],
            "constraints": [
                unique("maintenance_tasks_area_item_unique", "area", "item"),
                foreign("maintenance_tasks_asset_id_fkey", ("asset_id",), "assets", ("id",), "SET NULL"),
                check("maintenance_tasks_kind_check", ("kind",), "CHECK (kind IN ('Scheduled', 'Work Request'))"),
                check("maintenance_tasks_origin_check", ("origin",), "CHECK (origin IN ('manufacturer', 'owner'))"),
                primary("maintenance_tasks_pkey", "id"),
                check("maintenance_tasks_schedule_kind_check", ("schedule_kind",), "CHECK (schedule_kind IN ('calendar', 'meter', 'both'))"),
            ],
            "indexes": [
                index("maintenance_tasks_area_item_unique", True, ("area", "ASC"), ("item", "ASC")),
                index("maintenance_tasks_asset_id_idx", False, ("asset_id", "ASC"), predicate="is_active = true"),
                index("maintenance_tasks_pkey", True, ("id", "ASC")),
            ],
        },
    },
    "canonical_data": {
        "maintenance_categories": {
            "key": ["id"],
            "columns": ["id", "name", "icon", "color_name", "is_built_in", "sort_order"],
            "rows": [
                ["00000000-0000-0000-0000-000000000001", "Pool", "drop.fill", "blue", True, 10],
                ["00000000-0000-0000-0000-000000000002", "Hot Tub", "bubbles.and.sparkles.fill", "cyan", True, 20],
                ["00000000-0000-0000-0000-000000000003", "Grounds", "leaf.fill", "green", True, 30],
                ["00000000-0000-0000-0000-000000000004", "Equipment", "wrench.and.screwdriver.fill", "orange", True, 40],
                ["00000000-0000-0000-0000-000000000005", "House", "house.fill", "purple", True, 50],
                ["00000000-0000-0000-0000-000000000006", "Safety", "shield.fill", "red", True, 60],
                ["00000000-0000-0000-0000-000000000007", "Tractor", "gearshape.2.fill", "brown", True, 70],
                ["00000000-0000-0000-0000-000000000008", "Property", "map.fill", "brown", True, 80],
            ],
        }
    },
}


class FixtureMetadataSource:
    def __init__(self, metadata):
        self.metadata = metadata
        self.calls = 0

    def inspect_read_only(self):
        self.calls += 1
        return copy.deepcopy(self.metadata)


class RaisingMapping(Mapping):
    def __iter__(self):
        raise RuntimeError("must not iterate untrusted mapping")

    def __len__(self):
        raise RuntimeError("must not size untrusted mapping")

    def __getitem__(self, _key):
        raise RuntimeError("must not access untrusted mapping")


class RaisingList(list):
    def __iter__(self):
        raise RuntimeError("must not iterate untrusted collection")


class HostileIdentity:
    @property
    def database_name(self):
        raise RuntimeError("password=identity-secret /private/identity")

    @property
    def environment(self):
        raise RuntimeError("must not access hostile identity")


class MissingIdentityAttributes:
    pass


class AuthorityFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-authority-")
        self.root = Path(self.temporary.name)
        self.db = self.root / "db"
        self.db.mkdir()
        shutil.copy2(MANIFEST_PATH, self.db / MANIFEST_PATH.name)
        for filename in APPROVED_HASHES:
            shutil.copy2(DB_DIR / filename, self.db / filename)
        self.manifest_path = self.db / MANIFEST_PATH.name
        self.manifest = authority._load_manifest_at(self.manifest_path)
        self.identity = authority.ExpectedIdentity("isolated_fixture", "unit-test")

    def tearDown(self):
        self.temporary.cleanup()

    def file_audit(self):
        return authority._audit_migration_files_at(self.db, self.manifest_path)

    def metadata(self, *, terminal_migration="009", ledger_state="absent"):
        snapshot = self.manifest.snapshots[terminal_migration]
        entries = []
        if ledger_state == "present":
            entries = [
                {
                    "order": spec.order,
                    "version": spec.version,
                    "filename": spec.filename,
                    "sha256": spec.sha256,
                }
                for spec in snapshot.canonical
            ]
        return {
            "declared_version": terminal_migration,
            "concurrent_migration_activity": False,
            "unexplained_schema_objects": False,
            "identity": {
                "database_name": self.identity.database_name,
                "environment": self.identity.environment,
            },
            "ledger": {"state": ledger_state, "entries": entries},
            "schema": copy.deepcopy(snapshot.schema_contract),
        }

    def snapshot(self, metadata, *, terminal_migration="009"):
        return authority._audit_supplied_metadata(
            metadata, self.identity, self.manifest, terminal_migration=terminal_migration
        )

    def public_snapshot(self, metadata, expected_identity=..., *, terminal_migration="009"):
        source = FixtureMetadataSource(metadata)
        verified = authority._result(authority.AuditStatus.MIGRATION_FILES_VERIFIED, self.manifest)
        with mock.patch.object(
            authority,
            "_audit_migration_authority_at",
            return_value=(verified, self.manifest),
        ):
            result = authority.audit_schema_metadata(
                source,
                self.identity if expected_identity is ... else expected_identity,
                terminal_migration=terminal_migration,
            )
        return result, source


class ManifestFingerprintTests(AuthorityFixture):
    def test_security_limits_and_migration_policy_are_independently_pinned(self):
        for name, expected in APPROVED_RESOURCE_LIMITS.items():
            self.assertEqual(getattr(authority, name), expected, name)
        self.assertEqual(
            {spec.version: spec.reapplication_permitted for spec in self.manifest.snapshots["010"].canonical},
            APPROVED_REAPPLICATION,
        )
        self.assertEqual(self.manifest.reserved_versions, ("007", "008"))
        self.assertEqual(self.manifest.next_canonical_version, "011")
        self.assertNotIn("007", {spec.version for spec in self.manifest.canonical})
        self.assertNotIn("008", {spec.version for spec in self.manifest.canonical})

    def test_complete_independent_canonical_oracle(self):
        self.assertEqual(self.manifest.snapshots["009"].schema_contract, EXPECTED_SCHEMA_ORACLE)
        tables = EXPECTED_SCHEMA_ORACLE["tables"]
        self.assertEqual(tuple(tables), APPROVED_TABLES)
        self.assertEqual(sum(len(table["columns"]) for table in tables.values()), 143)
        self.assertEqual(sum(len(table["constraints"]) for table in tables.values()), 39)
        self.assertEqual(sum(len(table["indexes"]) for table in tables.values()), 28)
        self.assertEqual(
            len(EXPECTED_SCHEMA_ORACLE["canonical_data"]["maintenance_categories"]["rows"]),
            8,
        )

    def test_each_independent_oracle_leaf_is_enforced(self):
        def leaves(value, path=()):
            if isinstance(value, dict):
                for key in sorted(value):
                    yield from leaves(value[key], path + (key,))
            elif isinstance(value, list):
                for position, item in enumerate(value):
                    yield from leaves(item, path + (position,))
            else:
                yield path, value

        def changed(value):
            if value is None:
                return "unauthorized"
            if type(value) is bool:
                return not value
            if type(value) is int:
                return value + 1
            return value + "_unauthorized"

        for path, original in leaves(EXPECTED_SCHEMA_ORACLE):
            with self.subTest(path=path):
                metadata = self.metadata()
                metadata["schema"] = copy.deepcopy(EXPECTED_SCHEMA_ORACLE)
                target = metadata["schema"]
                for component in path[:-1]:
                    target = target[component]
                target[path[-1]] = changed(original)
                self.assertNotEqual(
                    self.snapshot(metadata).status,
                    authority.AuditStatus.SNAPSHOT_CONSISTENT,
                )

    def test_manifest_has_independently_pinned_contract_and_migrations(self):
        raw = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        historical = raw["snapshots"]["009"]
        current = raw["snapshots"]["010"]
        encoded = json.dumps(historical["schema_contract"], sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), APPROVED_CONTRACT_HASH)
        self.assertEqual(
            {item["filename"]: item["sha256"] for item in current["canonical_migrations"]},
            APPROVED_HASHES,
        )
        contract = historical["schema_contract"]
        self.assertEqual(tuple(contract["tables"]), APPROVED_TABLES)
        self.assertEqual(sum(len(item["columns"]) for item in contract["tables"].values()), 143)
        self.assertEqual(sum(len(item["constraints"]) for item in contract["tables"].values()), 39)
        self.assertEqual(sum(len(item["indexes"]) for item in contract["tables"].values()), 28)
        migration_created_indexes = {
            "maintenance_task_parts_task_id_idx", "maintenance_task_photos_task_id_idx",
            "assets_external_id_idx", "assets_qr_token_idx", "assets_name_lower_idx",
            "asset_meter_reading_asset_id_reading_at_idx", "maintenance_tasks_asset_id_idx",
            "asset_meter_reading_idempotency_idx", "asset_meter_reading_asset_epoch_reading_at_idx",
            "asset_meter_reading_status_idx", "asset_task_mapping_proposals_status_idx",
            "asset_task_mapping_proposals_task_asset_pending_idx",
            "maintenance_proposals_idempotency_idx", "maintenance_proposals_review_queue_idx",
        }
        all_indexes = {
            index["name"]
            for table in contract["tables"].values()
            for index in table["indexes"]
        }
        self.assertTrue(migration_created_indexes <= all_indexes)
        self.assertEqual(len(contract["canonical_data"]["maintenance_categories"]["rows"]), 8)

    def test_every_fingerprinted_property_is_required(self):
        base = self.metadata()
        samples = (
            ("columns", "type", "bogus"),
            ("columns", "nullable", None),
            ("columns", "default", "bogus"),
            ("columns", "precision", 999),
            ("columns", "scale", 999),
            ("columns", "generated", "bogus"),
            ("constraints", "definition", "bogus"),
            ("constraints", "on_update", "CASCADE"),
            ("constraints", "on_delete", "RESTRICT"),
            ("indexes", "unique", None),
            ("indexes", "method", "hash"),
            ("indexes", "keys", []),
            ("indexes", "predicate", "bogus"),
        )
        table = "asset_meter_reading"
        for collection, property_name, value in samples:
            with self.subTest(collection=collection, property=property_name):
                metadata = copy.deepcopy(base)
                candidates = metadata["schema"]["tables"][table][collection]
                candidate = next(
                    item for item in candidates
                    if property_name in item and item[property_name] != value
                )
                candidate[property_name] = value
                self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_INCONSISTENT)

    def test_missing_and_extra_schema_objects_fail_closed(self):
        cases = []
        missing_table = self.metadata()
        del missing_table["schema"]["tables"]["assets"]
        cases.append((missing_table, authority.AuditStatus.SNAPSHOT_PARTIAL))
        extra_table = self.metadata()
        extra_table["schema"]["tables"]["later_table"] = {"columns": [], "constraints": [], "indexes": []}
        cases.append((extra_table, authority.AuditStatus.SNAPSHOT_LATER))
        for collection in ("columns", "constraints", "indexes"):
            missing = self.metadata()
            missing["schema"]["tables"]["assets"][collection].pop()
            cases.append((missing, authority.AuditStatus.SNAPSHOT_PARTIAL))
            extra = self.metadata()
            prototype = copy.deepcopy(extra["schema"]["tables"]["assets"][collection][0])
            prototype["name"] = "later_object"
            extra["schema"]["tables"]["assets"][collection].append(prototype)
            cases.append((extra, authority.AuditStatus.SNAPSHOT_LATER))
        for metadata, status in cases:
            with self.subTest(status=status):
                self.assertEqual(self.snapshot(metadata).status, status)

    def test_seeded_canonical_data_is_exact(self):
        missing = self.metadata()
        missing["schema"]["canonical_data"]["maintenance_categories"]["rows"].pop()
        changed = self.metadata()
        changed["schema"]["canonical_data"]["maintenance_categories"]["rows"][0][1] = "Other"
        self.assertEqual(self.snapshot(missing).status, authority.AuditStatus.SNAPSHOT_INCONSISTENT)
        self.assertEqual(self.snapshot(changed).status, authority.AuditStatus.SNAPSHOT_INCONSISTENT)

    def test_incomplete_manifest_fingerprints_are_rejected(self):
        for collection, property_name in (("columns", "nullable"), ("constraints", "on_delete"), ("indexes", "predicate")):
            raw = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
            del raw["snapshots"]["009"]["schema_contract"]["tables"]["asset_meter_reading"][collection][0][property_name]
            path = self.root / f"incomplete-{collection}.json"
            path.write_text(json.dumps(raw), encoding="utf-8")
            with self.subTest(collection=collection), self.assertRaises(authority.AuthorityConfigurationError):
                authority._load_manifest_at(path)

    def test_malformed_manifest_levels_fail_closed(self):
        cases = []
        legacy_source = json.loads(self.manifest_path.read_text())
        cases.append(
            {
                "format_version": 2,
                "authority": "propertymanager",
                "canonical_migrations": legacy_source["snapshots"]["009"]["canonical_migrations"],
                "reserved_versions": legacy_source["reserved_versions"],
                "next_canonical_version": "010",
                "schema_contract": legacy_source["snapshots"]["009"]["schema_contract"],
            }
        )
        reserved = json.loads(self.manifest_path.read_text())
        reserved["reserved_versions"].append("invalid")
        cases.append(reserved)
        missing_current = json.loads(self.manifest_path.read_text())
        del missing_current["current_snapshot"]
        cases.append(missing_current)
        unknown_current = json.loads(self.manifest_path.read_text())
        unknown_current["current_snapshot"] = "999"
        cases.append(unknown_current)
        table = json.loads(self.manifest_path.read_text())
        table["snapshots"]["009"]["schema_contract"]["tables"]["assets"] = []
        cases.append(table)
        column_case = json.loads(self.manifest_path.read_text())
        column_case["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["columns"][0]["name"] = []
        cases.append(column_case)
        constraint_case = json.loads(self.manifest_path.read_text())
        constraint_case["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["constraints"][0]["columns"] = "external_id"
        cases.append(constraint_case)
        index_case = json.loads(self.manifest_path.read_text())
        index_case["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["indexes"][0]["keys"] = {}
        cases.append(index_case)
        seed_case = json.loads(self.manifest_path.read_text())
        seed_case["snapshots"]["009"]["schema_contract"]["canonical_data"]["maintenance_categories"]["rows"] = {}
        cases.append(seed_case)
        for position, raw in enumerate(cases):
            with self.subTest(position=position):
                path = self.root / f"malformed-{position}.json"
                path.write_text(json.dumps(raw), encoding="utf-8")
                with self.assertRaises(authority.AuthorityConfigurationError):
                    authority._load_manifest_at(path)

    def test_manifest_requires_exact_keys_at_every_level(self):
        mutations = []
        selectors = (
            lambda raw: raw,
            lambda raw: raw["snapshots"]["010"],
            lambda raw: raw["snapshots"]["010"]["canonical_migrations"][0],
            lambda raw: raw["reserved_versions"][0],
            lambda raw: raw["snapshots"]["009"]["schema_contract"],
            lambda raw: raw["snapshots"]["009"]["schema_contract"]["tables"]["assets"],
            lambda raw: raw["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["columns"][0],
            lambda raw: raw["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["constraints"][0],
            lambda raw: raw["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["indexes"][0],
            lambda raw: raw["snapshots"]["009"]["schema_contract"]["canonical_data"]["maintenance_categories"],
        )
        for selector in selectors:
            raw = json.loads(self.manifest_path.read_text())
            selector(raw)["unexpected"] = True
            mutations.append(raw)
        missing = json.loads(self.manifest_path.read_text())
        del missing["snapshots"]["009"]["schema_contract"]["tables"]["assets"]["columns"][0]["type"]
        mutations.append(missing)
        for position, raw in enumerate(mutations):
            path = self.root / f"exact-keys-{position}.json"
            path.write_text(json.dumps(raw), encoding="utf-8")
            with self.subTest(position=position), self.assertRaises(authority.AuthorityConfigurationError):
                authority._load_manifest_at(path)


class FilesystemAuthorityTests(AuthorityFixture):
    def assert_invalid(self, result):
        self.assertFalse(result.ok)
        self.assertIn(result.status, {authority.AuditStatus.MIGRATION_FILES_INVALID, authority.AuditStatus.AUTHORITY_UNAVAILABLE})
        self.assertNotIn(str(self.root), result.human_report())
        self.assertNotIn(str(self.root), result.machine_report())

    def test_private_fixture_helper_and_canonical_production_audit(self):
        self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)
        self.assertEqual(authority.audit_canonical_migration_files().status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)

    def test_manifest_size_limit_accepts_boundary_and_rejects_next_byte(self):
        original = self.manifest_path.read_bytes().rstrip()
        exact = original + b" " * (authority.MAX_MANIFEST_BYTES - len(original))
        self.assertEqual(len(exact), authority.MAX_MANIFEST_BYTES)
        self.manifest_path.write_bytes(exact)
        authority._load_manifest_at(self.manifest_path)
        self.manifest_path.write_bytes(exact + b" ")
        with self.assertRaises(authority.AuthorityConfigurationError):
            authority._load_manifest_at(self.manifest_path)

    def test_migration_size_limit_accepts_boundary_and_rejects_next_byte(self):
        path = self.db / "boundary.bin"
        path.write_bytes(b"x" * authority.MAX_MIGRATION_BYTES)
        self.assertEqual(
            len(authority._read_regular_file(path, max_bytes=authority.MAX_MIGRATION_BYTES)),
            authority.MAX_MIGRATION_BYTES,
        )
        path.write_bytes(b"x" * (authority.MAX_MIGRATION_BYTES + 1))
        with self.assertRaises(authority.BoundedInputError):
            authority._read_regular_file(path, max_bytes=authority.MAX_MIGRATION_BYTES)

    def configure_exact_cumulative_boundary(self):
        self.assertEqual(
            hashlib.sha256(b"").hexdigest(),
            APPROVED_EMPTY_SHA256,
        )
        raw = json.loads(self.manifest_path.read_text())
        for position, entry in enumerate(raw["snapshots"]["010"]["canonical_migrations"]):
            data = b"x" * authority.MAX_MIGRATION_BYTES if position < 4 else b""
            (self.db / entry["filename"]).write_bytes(data)
            entry["sha256"] = (
                hashlib.sha256(data).hexdigest()
                if data
                else APPROVED_EMPTY_SHA256
            )
        self.manifest_path.write_text(json.dumps(raw), encoding="utf-8")
        return raw

    def test_cumulative_migration_limit_accepts_exact_boundary(self):
        raw = self.configure_exact_cumulative_boundary()
        calls = []
        original = authority._read_regular_at

        def record(directory_fd, name, **kwargs):
            calls.append(name)
            return original(directory_fd, name, **kwargs)

        with mock.patch.object(authority, "_read_regular_at", side_effect=record):
            result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)
        successors = [entry["filename"] for entry in raw["snapshots"]["010"]["canonical_migrations"][4:]]
        self.assertTrue(all(name not in calls for name in successors))

    def test_exhausted_budget_rejects_nonempty_replacement_without_opening(self):
        raw = self.configure_exact_cumulative_boundary()
        target = self.db / raw["snapshots"]["010"]["canonical_migrations"][4]["filename"]
        calls = []
        original = authority._read_regular_at

        def record(directory_fd, name, **kwargs):
            calls.append(name)
            return original(directory_fd, name, **kwargs)

        with mock.patch.object(authority, "_read_regular_at", side_effect=record):
            result = authority._audit_migration_files_at(
                self.db,
                self.manifest_path,
                _post_inventory=lambda: target.write_bytes(b"replacement"),
            )
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("authority_inventory_changed", {item.code for item in result.diagnostics})
        self.assertNotIn(target.name, calls)

    def test_exhausted_budget_rejects_incorrect_empty_checksum_without_opening(self):
        raw = self.configure_exact_cumulative_boundary()
        target = self.db / raw["snapshots"]["010"]["canonical_migrations"][4]["filename"]
        raw["snapshots"]["010"]["canonical_migrations"][4]["sha256"] = "0" * 64
        self.manifest_path.write_text(json.dumps(raw), encoding="utf-8")
        calls = []
        original = authority._read_regular_at

        def record(directory_fd, name, **kwargs):
            calls.append(name)
            return original(directory_fd, name, **kwargs)

        with mock.patch.object(authority, "_read_regular_at", side_effect=record):
            result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("migration_checksum_mismatch", {item.code for item in result.diagnostics})
        self.assertNotIn(target.name, calls)

    def test_exhausted_budget_zero_successor_mutations_fail_without_opening(self):
        cases = ("remove", "replace", "hard-link", "type-change")
        for case in cases:
            with self.subTest(case=case):
                raw = self.configure_exact_cumulative_boundary()
                target = self.db / raw["snapshots"]["010"]["canonical_migrations"][4]["filename"]
                external_link = self.root / "zero-successor-hard-link"
                calls = []
                original = authority._read_regular_at

                def record(directory_fd, name, **kwargs):
                    calls.append(name)
                    return original(directory_fd, name, **kwargs)

                def mutate():
                    if case == "remove":
                        target.unlink()
                    elif case == "replace":
                        target.unlink()
                        target.write_bytes(b"")
                    elif case == "hard-link":
                        os.link(target, external_link)
                    else:
                        target.unlink()
                        target.mkdir()

                try:
                    with mock.patch.object(authority, "_read_regular_at", side_effect=record):
                        result = authority._audit_migration_files_at(
                            self.db,
                            self.manifest_path,
                            _post_inventory=mutate,
                        )
                    self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
                    self.assertIn("authority_inventory_changed", {item.code for item in result.diagnostics})
                    self.assertNotIn(target.name, calls)
                finally:
                    if external_link.exists():
                        external_link.unlink()
                    if target.is_dir():
                        target.rmdir()

    def test_cumulative_migration_limit_rejects_first_excess_without_later_reads(self):
        raw = json.loads(self.manifest_path.read_text())
        for position, entry in enumerate(raw["snapshots"]["010"]["canonical_migrations"]):
            data = b"x" * authority.MAX_MIGRATION_BYTES if position < 4 else b"x"
            (self.db / entry["filename"]).write_bytes(data)
            entry["sha256"] = hashlib.sha256(data).hexdigest()
        self.manifest_path.write_text(json.dumps(raw), encoding="utf-8")
        calls = []
        original = authority._read_regular_at

        def record(directory_fd, name, **kwargs):
            calls.append(name)
            return original(directory_fd, name, **kwargs)

        with mock.patch.object(authority, "_read_regular_at", side_effect=record):
            result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("migration_size_invalid", {item.code for item in result.diagnostics})
        self.assertNotIn(raw["snapshots"]["010"]["canonical_migrations"][4]["filename"], calls)
        self.assertNotIn(raw["snapshots"]["010"]["canonical_migrations"][5]["filename"], calls)

    def test_cumulative_accounting_rejects_replacement_before_read(self):
        raw = json.loads(self.manifest_path.read_text())
        for position, entry in enumerate(raw["snapshots"]["010"]["canonical_migrations"]):
            if position < 4:
                data = b"x" * (authority.MAX_MIGRATION_BYTES - 1)
            elif position == 4:
                data = b"x"
            else:
                data = b""
            (self.db / entry["filename"]).write_bytes(data)
            entry["sha256"] = hashlib.sha256(data).hexdigest()
        self.manifest_path.write_text(json.dumps(raw), encoding="utf-8")
        target = self.db / raw["snapshots"]["010"]["canonical_migrations"][4]["filename"]

        result = authority._audit_migration_files_at(
            self.db,
            self.manifest_path,
            _post_inventory=lambda: target.write_bytes(b"12345"),
        )
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn(
            "migration_size_invalid",
            {item.code for item in result.diagnostics},
        )

    def test_traversal_depth_accepts_boundary_and_rejects_next_level(self):
        current = self.db
        for position in range(authority.MAX_TRAVERSAL_DEPTH):
            current = current / f"depth-{position}"
            current.mkdir()
        self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)
        (current / "too-deep").mkdir()
        result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("authority_bounds_exceeded", {item.code for item in result.diagnostics})

    def test_entry_count_accepts_boundary_and_rejects_next_entry(self):
        baseline = len(list(os.scandir(self.db)))
        for position in range(authority.MAX_DISCOVERED_ENTRIES - baseline):
            (self.db / f"ordinary-{position}.txt").touch()
        self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)
        (self.db / "one-too-many.txt").touch()
        result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("authority_bounds_exceeded", {item.code for item in result.diagnostics})

    def test_cli_refuses_authority_path_overrides(self):
        for option in ("--manifest", "--migration-dir"):
            with self.subTest(option=option), self.assertRaises(SystemExit):
                authority._parser().parse_args([option, str(self.root)])

    def test_each_checksum_is_enforced(self):
        for filename in APPROVED_HASHES:
            with self.subTest(filename=filename):
                path = self.db / filename
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                try:
                    self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_INVALID)
                finally:
                    path.write_bytes(original)

    def test_missing_renamed_duplicate_and_later_files_are_rejected(self):
        missing = self.db / "002_rich_task_model.sql"
        original = missing.read_bytes()
        missing.unlink()
        self.assert_invalid(self.file_audit())
        missing.write_bytes(original)
        renamed = self.db / "002_other.sql"
        shutil.copy2(missing, renamed)
        self.assert_invalid(self.file_audit())
        renamed.unlink()
        for name in ("007_future.sql", "008_future.sql", "009_future.sql"):
            path = self.db / name
            path.write_text("SELECT 1;", encoding="utf-8")
            self.assert_invalid(self.file_audit())
            path.unlink()

    def test_symlinked_manifest_directory_and_file_are_rejected(self):
        real_manifest = self.root / "real.json"
        shutil.copy2(self.manifest_path, real_manifest)
        self.manifest_path.unlink()
        self.manifest_path.symlink_to(real_manifest)
        self.assert_invalid(self.file_audit())
        self.manifest_path.unlink()
        shutil.copy2(real_manifest, self.manifest_path)
        real_file = self.db / "real.sql"
        target = self.db / "001_initial_schema.sql"
        target.rename(real_file)
        target.symlink_to(real_file)
        self.assert_invalid(self.file_audit())
        target.unlink()
        real_file.rename(target)
        linked_dir = self.root / "linked-db"
        linked_dir.symlink_to(self.db, target_is_directory=True)
        self.assert_invalid(authority._audit_migration_files_at(linked_dir, self.manifest_path))

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO unavailable")
    def test_fifo_is_rejected_without_opening(self):
        fifo = self.db / "007_fifo.sql"
        os.mkfifo(fifo)
        self.assert_invalid(self.file_audit())

    def test_nested_case_varied_and_alternate_numeric_forms_are_rejected(self):
        names = (
            "001_UPPER.SQL", "001_initial_schema.SQL", "1_initial.sql", "01_initial.sql",
            "0001_initial.sql", "001_initial.sql.bak", "001_initial.sql~",
            ".#001_initial.sql", "#001_initial.sql#", "001-initial.sql.swp",
        )
        for name in names:
            with self.subTest(name=name):
                path = self.db / name
                path.write_text("SELECT 1;", encoding="utf-8")
                self.assert_invalid(self.file_audit())
                path.unlink()
        nested = self.db / "nested"
        nested.mkdir()
        (nested / "010_nested.sql").write_text("SELECT 1;", encoding="utf-8")
        self.assert_invalid(self.file_audit())

    def test_nonregular_directory_masquerading_as_migration_is_rejected(self):
        (self.db / "007_directory.sql").mkdir()
        self.assert_invalid(self.file_audit())

    def test_discovery_read_and_permission_failures_are_sanitized(self):
        with mock.patch.object(authority.os, "scandir", side_effect=PermissionError("/secret/path token=abc")):
            result = self.file_audit()
        self.assert_invalid(result)
        with mock.patch.object(authority, "_read_regular_at", side_effect=PermissionError("/secret/file")):
            result = self.file_audit()
        self.assert_invalid(result)
        target = self.db / "001_initial_schema.sql"
        mode = stat.S_IMODE(target.stat().st_mode)
        target.chmod(0)
        try:
            result = self.file_audit()
            if os.geteuid() != 0:
                self.assert_invalid(result)
        finally:
            target.chmod(mode)

    def test_replacement_during_read_fails_closed(self):
        target = self.db / "001_initial_schema.sql"
        def alter():
            target.write_bytes(target.read_bytes() + b"\n")
        with self.assertRaises(OSError):
            authority._read_regular_file(target, _post_read=alter)

    def test_hard_linked_manifest_and_migration_are_rejected(self):
        manifest_link = self.root / "manifest-link.json"
        os.link(self.manifest_path, manifest_link)
        self.assertEqual(self.file_audit().status, authority.AuditStatus.AUTHORITY_UNAVAILABLE)
        manifest_link.unlink()
        migration = self.db / "001_initial_schema.sql"
        migration_link = self.root / "migration-link.sql"
        os.link(migration, migration_link)
        self.assertEqual(self.file_audit().status, authority.AuditStatus.MIGRATION_FILES_INVALID)

    def test_parent_directory_replacement_race_fails_closed(self):
        target = self.db / "001_initial_schema.sql"
        moved = self.root / "db-original"

        def replace_parent():
            self.db.rename(moved)
            self.db.mkdir()

        try:
            with self.assertRaises(OSError):
                authority._read_regular_file(target, _post_open=replace_parent)
        finally:
            if self.db.exists():
                self.db.rmdir()
            if moved.exists():
                moved.rename(self.db)

    def test_discovery_open_replacement_race_fails_closed(self):
        target = self.db / "001_initial_schema.sql"
        original = self.db / "001_original.sql"

        def replace_file():
            target.rename(original)
            target.write_bytes(b"replacement")

        try:
            with self.assertRaises(OSError):
                authority._read_regular_file(target, _post_open=replace_file)
        finally:
            if target.exists():
                target.unlink()
            if original.exists():
                original.rename(target)

    def test_post_discovery_entry_addition_removal_replacement_and_type_change_fail_closed(self):
        def run_mutation(initializer, mutator):
            path = self.db / "ordinary-race-object"
            initializer(path)
            try:
                result = authority._audit_migration_files_at(
                    self.db,
                    self.manifest_path,
                    _post_inventory=lambda: mutator(path),
                )
                self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
                self.assertIn("authority_inventory_changed", {item.code for item in result.diagnostics})
                self.assertNotIn(str(self.root), result.machine_report())
            finally:
                if path.is_symlink() or path.is_file():
                    path.unlink()
                elif path.is_dir():
                    path.rmdir()

        cases = (
            (lambda _path: None, lambda path: path.write_text("added")),
            (lambda path: path.write_text("remove"), lambda path: path.unlink()),
            (
                lambda path: path.write_text("original"),
                lambda path: (path.unlink(), path.write_text("replacement")),
            ),
            (
                lambda path: path.write_text("file"),
                lambda path: (path.unlink(), path.mkdir()),
            ),
        )
        for position, (initializer, mutator) in enumerate(cases):
            with self.subTest(position=position):
                run_mutation(initializer, mutator)

    def test_migration_like_file_added_after_discovery_fails_closed(self):
        path = self.db / "009_after_discovery.SQL.bak"
        result = authority._audit_migration_files_at(
            self.db,
            self.manifest_path,
            _post_inventory=lambda: path.write_text("SELECT 1;"),
        )
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("authority_inventory_changed", {item.code for item in result.diagnostics})

    def test_nested_symlink_directory_cannot_conceal_migration(self):
        external = self.root / "external"
        external.mkdir()
        (external / "009_concealed.sql").write_text("SELECT 1;")
        (self.db / "concealed").symlink_to(external, target_is_directory=True)
        result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("unexpected_symlink_object", {item.code for item in result.diagnostics})

    def test_manifest_replacement_after_discovery_fails_continuity(self):
        original = self.manifest_path.read_bytes()

        def replace_manifest():
            self.manifest_path.write_bytes(original + b" ")

        result = authority._audit_migration_files_at(
            self.db,
            self.manifest_path,
            _post_inventory=replace_manifest,
        )
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertIn("authority_inventory_changed", {item.code for item in result.diagnostics})

    def test_public_audit_contains_recursion_and_memory_failures(self):
        for failure in (RecursionError(), MemoryError()):
            with self.subTest(failure=type(failure).__name__), mock.patch.object(
                authority, "_scan_migration_tree", side_effect=failure
            ):
                result = self.file_audit()
                self.assertFalse(result.ok)
                self.assertIn(
                    result.status,
                    {authority.AuditStatus.MIGRATION_FILES_INVALID, authority.AuditStatus.AUTHORITY_UNAVAILABLE},
                )

    def test_missing_descriptor_relative_platform_support_fails_closed(self):
        with mock.patch.object(authority.os, "supports_dir_fd", set()):
            result = self.file_audit()
        self.assertEqual(result.status, authority.AuditStatus.AUTHORITY_UNAVAILABLE)


class MetadataAndLedgerTests(AuthorityFixture):
    def test_malformed_expected_identity_never_escapes_public_entry_point(self):
        malformed = (
            None,
            1,
            "database",
            [],
            {},
            HostileIdentity(),
            MissingIdentityAttributes(),
            authority.ExpectedIdentity("", "unit-test"),
            authority.ExpectedIdentity(" isolated_fixture", "unit-test"),
            authority.ExpectedIdentity("unknown", "unit-test"),
            authority.ExpectedIdentity("isolated_fixture", "unit-test\nforged"),
            authority.ExpectedIdentity([], "unit-test"),
        )
        for value in malformed:
            with self.subTest(value=type(value).__name__):
                result, source = self.public_snapshot(self.metadata(), value)
                self.assertEqual(result.status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)
                self.assertEqual(result.identity_assurance, "unproven")
                self.assertEqual(source.calls, 0)
                self.assertNotIn("secret", result.machine_report())

    def test_public_snapshot_uses_exact_manifest_verified_once(self):
        source = FixtureMetadataSource(self.metadata())
        verified = authority._result(authority.AuditStatus.MIGRATION_FILES_VERIFIED, self.manifest)
        observed = []

        def classify(metadata, expected_identity, manifest, *, terminal_migration=None):
            observed.append(manifest)
            return authority._result(
                authority.AuditStatus.SNAPSHOT_CONSISTENT,
                manifest,
                identity_assurance="unproven",
            )

        with mock.patch.object(
            authority,
            "_audit_migration_authority_at",
            return_value=(verified, self.manifest),
        ) as authority_audit, mock.patch.object(
            authority,
            "load_manifest",
            side_effect=AssertionError("second manifest load attempted"),
        ), mock.patch.object(
            authority,
            "audit_canonical_migration_files",
            side_effect=AssertionError("second authority audit attempted"),
        ), mock.patch.object(authority, "_audit_supplied_metadata", side_effect=classify):
            result = authority.audit_schema_metadata(source, self.identity)
        self.assertEqual(result.status, authority.AuditStatus.SNAPSHOT_CONSISTENT)
        authority_audit.assert_called_once_with(authority.CANONICAL_MIGRATION_DIR, authority.CANONICAL_MANIFEST)
        self.assertEqual(source.calls, 1)
        self.assertEqual(observed, [self.manifest])
        self.assertIs(observed[0], self.manifest)

    def test_public_snapshot_contains_continuity_and_classifier_failures(self):
        source = FixtureMetadataSource(self.metadata())
        continuity_failure = authority._result(
            authority.AuditStatus.MIGRATION_FILES_INVALID,
            self.manifest,
            (authority.Diagnostic("authority_inventory_changed", "migration authority changed"),),
        )
        with mock.patch.object(
            authority,
            "_audit_migration_authority_at",
            return_value=(continuity_failure, self.manifest),
        ):
            result = authority.audit_schema_metadata(source, self.identity)
        self.assertEqual(result.status, authority.AuditStatus.MIGRATION_FILES_INVALID)
        self.assertEqual(source.calls, 0)

        verified = authority._result(authority.AuditStatus.MIGRATION_FILES_VERIFIED, self.manifest)
        with mock.patch.object(
            authority,
            "_audit_migration_authority_at",
            return_value=(verified, self.manifest),
        ), mock.patch.object(
            authority,
            "_audit_supplied_metadata",
            side_effect=RuntimeError("password=secret /private/classifier"),
        ):
            result = authority.audit_schema_metadata(FixtureMetadataSource(self.metadata()), self.identity)
        self.assertEqual(result.status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        self.assertNotIn("secret", result.machine_report())
        self.assertNotIn("private", result.human_report())

    def test_only_consistent_snapshot_succeeds_and_identity_stays_unproven(self):
        result = self.snapshot(self.metadata())
        self.assertEqual(result.status, authority.AuditStatus.SNAPSHOT_CONSISTENT)
        self.assertTrue(result.ok)
        self.assertEqual(result.identity_assurance, "unproven")
        self.assertNotIn("database_verified", result.machine_report())

    def test_missing_or_malformed_declared_version_fails(self):
        for value in (None, 6, "unknown", ""):
            metadata = self.metadata()
            if value is None:
                metadata.pop("declared_version")
            else:
                metadata["declared_version"] = value
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        lower, higher = self.metadata(), self.metadata()
        lower["declared_version"], higher["declared_version"] = "006", "010"
        self.assertEqual(self.snapshot(lower).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        self.assertEqual(self.snapshot(higher).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        current = self.metadata(terminal_migration="010", ledger_state="present")
        self.assertEqual(
            self.snapshot(current, terminal_migration="010").status,
            authority.AuditStatus.SNAPSHOT_CONSISTENT,
        )

    def test_concurrency_and_unexplained_state_are_explicit_booleans(self):
        for field in ("concurrent_migration_activity", "unexplained_schema_objects"):
            for value in (None, "false", 0, True):
                metadata = self.metadata()
                if value is None:
                    metadata.pop(field)
                else:
                    metadata[field] = value
                with self.subTest(field=field, value=value):
                    self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)

    def test_identity_is_exact_nonempty_and_cannot_self_certify(self):
        mutations = (
            ("database_name", ""), ("database_name", "unknown"),
            ("environment", " "), ("environment", "unit-test\nforged: yes"),
        )
        for field, value in mutations:
            metadata = self.metadata()
            metadata["identity"][field] = value
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)
        for key in ("proven", "identity_proven", "verified"):
            metadata = self.metadata()
            metadata["identity"][key] = True
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)

    def test_incomplete_metadata_cannot_claim_verification(self):
        metadata = {"identity": {"database_name": "isolated_fixture", "environment": "unit-test"}}
        result = self.snapshot(metadata)
        self.assertFalse(result.ok)
        self.assertNotEqual(result.status, authority.AuditStatus.MIGRATION_FILES_VERIFIED)

    def test_deep_metadata_and_recursion_fail_closed(self):
        metadata = self.metadata()
        nested = []
        cursor = nested
        for _ in range(authority.MAX_JSON_DEPTH + 1):
            child = []
            cursor.append(child)
            cursor = child
        metadata["extra"] = nested
        self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        with mock.patch.object(authority, "_validate_plain_json", side_effect=RecursionError()):
            self.assertEqual(self.snapshot(self.metadata()).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)

    def test_custom_mapping_is_rejected_without_iteration(self):
        result = self.snapshot(RaisingMapping())
        self.assertEqual(result.status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)
        source = mock.Mock()
        source.inspect_read_only.return_value = RaisingMapping()
        verified = authority._result(authority.AuditStatus.MIGRATION_FILES_VERIFIED, self.manifest)
        with mock.patch.object(
            authority,
            "_audit_migration_authority_at",
            return_value=(verified, self.manifest),
        ):
            result = authority.audit_schema_metadata(source, self.identity)
        self.assertEqual(result.status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)

    def test_custom_collection_is_rejected_without_iteration(self):
        metadata = self.metadata()
        metadata["schema"]["tables"]["assets"]["columns"] = RaisingList()
        self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_AMBIGUOUS)

    def test_missing_required_snapshot_keys_fail_closed(self):
        cases = []
        for key in tuple(self.metadata()):
            metadata = self.metadata()
            del metadata[key]
            cases.append(metadata)
        for key in tuple(self.metadata()["identity"]):
            metadata = self.metadata()
            del metadata["identity"][key]
            cases.append(metadata)
        for key in tuple(self.metadata()["ledger"]):
            metadata = self.metadata()
            del metadata["ledger"][key]
            cases.append(metadata)
        for key in tuple(self.metadata()["schema"]):
            metadata = self.metadata()
            del metadata["schema"][key]
            cases.append(metadata)
        for key in tuple(self.metadata()["schema"]["tables"]["assets"]):
            metadata = self.metadata()
            del metadata["schema"]["tables"]["assets"][key]
            cases.append(metadata)
        for position, metadata in enumerate(cases):
            with self.subTest(position=position):
                self.assertNotEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_CONSISTENT)

    def test_unhashable_and_wrong_schema_values_fail_closed(self):
        mutations = []
        for collection in ("columns", "constraints", "indexes"):
            metadata = self.metadata()
            metadata["schema"]["tables"]["assets"][collection][0]["name"] = []
            mutations.append(metadata)
        metadata = self.metadata(ledger_state="present")
        metadata["ledger"]["entries"][0]["version"] = []
        mutations.append(metadata)
        table = self.metadata()
        table["schema"]["tables"] = []
        mutations.append(table)
        seed = self.metadata()
        seed["schema"]["canonical_data"] = []
        mutations.append(seed)
        for position, metadata in enumerate(mutations):
            with self.subTest(position=position):
                result = self.snapshot(metadata)
                self.assertFalse(result.ok)

    def test_unknown_keys_and_schema_object_classes_fail_closed(self):
        cases = []
        top = self.metadata()
        top["unexpected"] = True
        cases.append(top)
        for name in ("views", "triggers", "functions", "sequences", "policies", "extensions"):
            metadata = self.metadata()
            metadata["schema"][name] = {}
            cases.append(metadata)
        table = self.metadata()
        table["schema"]["tables"]["assets"]["triggers"] = []
        cases.append(table)
        for collection in ("columns", "constraints", "indexes"):
            metadata = self.metadata()
            metadata["schema"]["tables"]["assets"][collection][0]["unexpected"] = True
            cases.append(metadata)
        ledger = self.metadata()
        ledger["ledger"]["unexpected"] = True
        cases.append(ledger)
        identity = self.metadata()
        identity["identity"]["proven"] = True
        cases.append(identity)
        for position, metadata in enumerate(cases):
            with self.subTest(position=position):
                self.assertNotEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_CONSISTENT)

    def test_allowed_extras_cannot_bypass_exact_schema(self):
        metadata = self.metadata()
        metadata["schema"]["allowed_extras"]["tables"] = ["unauthorized"]
        metadata["schema"]["tables"]["unauthorized"] = {
            "columns": [], "constraints": [], "indexes": [],
        }
        self.assertNotEqual(self.snapshot(metadata).status, authority.AuditStatus.SNAPSHOT_CONSISTENT)

    def test_identity_rejects_padding_sentinels_and_unicode_controls(self):
        bad_values = (
            "", " isolated_fixture", "isolated_fixture ", "unknown", "UnSpEcIfIeD",
            "unverified", "default", "none", "null", "n/a", "na", "test",
            "database", "environment", "line\nfeed", "ascii\x01control",
            "c1\x85control", "line\u2028separator", "paragraph\u2029separator",
            "format\u200bcharacter",
        )
        for value in bad_values:
            with self.subTest(value=repr(value)):
                metadata = self.metadata()
                metadata["identity"]["database_name"] = value
                expected = authority.ExpectedIdentity(value, self.identity.environment)
                result = authority._audit_supplied_metadata(metadata, expected, self.manifest)
                self.assertEqual(result.status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)

    def test_identity_mismatch_and_self_certification_remain_unproven(self):
        metadata = self.metadata()
        metadata["identity"]["environment"] = "different"
        self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)
        metadata = self.metadata()
        metadata["identity"]["identity_proven"] = True
        self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.DATABASE_IDENTITY_UNPROVEN)

    def test_present_ledger_requires_exact_order_filename_and_checksum(self):
        valid = self.metadata(ledger_state="present")
        self.assertEqual(self.snapshot(valid).status, authority.AuditStatus.SNAPSHOT_CONSISTENT)
        mutations = []
        filename = copy.deepcopy(valid)
        filename["ledger"]["entries"][0]["filename"] = "001_other.sql"
        mutations.append(filename)
        order = copy.deepcopy(valid)
        order["ledger"]["entries"][0], order["ledger"]["entries"][1] = order["ledger"]["entries"][1], order["ledger"]["entries"][0]
        mutations.append(order)
        duplicate = copy.deepcopy(valid)
        duplicate["ledger"]["entries"][1] = copy.deepcopy(duplicate["ledger"]["entries"][0])
        mutations.append(duplicate)
        missing = copy.deepcopy(valid)
        missing["ledger"]["entries"].pop()
        mutations.append(missing)
        checksum = copy.deepcopy(valid)
        checksum["ledger"]["entries"][0]["sha256"] = "0" * 64
        mutations.append(checksum)
        for metadata in mutations:
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.LEDGER_INCONSISTENT)
        later = copy.deepcopy(valid)
        later["ledger"]["entries"].append({"order": 8, "version": "010", "filename": "010.sql", "sha256": "0" * 64})
        self.assertEqual(self.snapshot(later).status, authority.AuditStatus.LEDGER_INCONSISTENT)

    def test_malformed_ledger_entries_never_escape(self):
        values = (None, "006", [], {}, {"order": 1}, {"order": [], "version": "001", "filename": "x", "sha256": "0" * 64})
        for value in values:
            metadata = self.metadata(ledger_state="present")
            metadata["ledger"]["entries"] = value if isinstance(value, list) else [value]
            with self.subTest(value=repr(value)):
                self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.LEDGER_INCONSISTENT)

    def test_ledger_state_is_explicit(self):
        for ledger in (None, {}, {"state": "unknown", "entries": []}, {"state": "absent", "entries": [{}]}):
            metadata = self.metadata()
            metadata["ledger"] = ledger
            self.assertEqual(self.snapshot(metadata).status, authority.AuditStatus.LEDGER_INCONSISTENT)

    def test_metadata_source_exception_is_generic_and_untrusted(self):
        source = mock.Mock()
        source.inspect_read_only.side_effect = RuntimeError("postgres://user:secret@host/db /private/file")
        with mock.patch.object(
            authority,
            "_audit_migration_authority_at",
            return_value=(authority._result(authority.AuditStatus.MIGRATION_FILES_VERIFIED, self.manifest), self.manifest),
        ):
            result = authority.audit_schema_metadata(source, self.identity)
        self.assertEqual(result.status, authority.AuditStatus.AUTHORITY_UNAVAILABLE)
        self.assertNotIn("secret", result.human_report())
        self.assertNotIn("private", result.machine_report())


class RedactionAndStatusTests(unittest.TestCase):
    def test_unc_extended_unc_device_and_multiple_paths_are_redacted(self):
        text = (
            r"\\server\share\secret.txt \\?\UNC\server\share\extended.txt "
            r"\\.\PhysicalDrive0 \\?\C:\device\secret.txt C:\private\file.txt "
            "/secret /another/path password=one token=two"
        )
        sanitized = authority.sanitize_line(text)
        for unsafe in (
            "server",
            "share",
            "PhysicalDrive0",
            "device",
            "C:\\private",
            "/secret",
            "/another/path",
            "one",
            "two",
        ):
            self.assertNotIn(unsafe, sanitized)
        self.assertGreaterEqual(sanitized.count("[REDACTED_PATH]"), 6)
        self.assertNotIn("\n", sanitized)

    def test_exception_unc_path_and_oversized_diagnostic_are_bounded(self):
        message = (
            r"\\server\share\exception.txt password='two words' "
            + "x" * (authority.MAX_REPORT_TEXT_CHARS + 100)
            + "\nforged"
        )
        result = authority.AuditResult(
            authority.AuditStatus.MIGRATION_FILES_INVALID,
            ("001",),
            ("007",),
            "009",
            (authority.Diagnostic("bounded", message),),
        )
        machine = result.machine_report()
        human = result.human_report()
        self.assertEqual(machine, result.machine_report())
        self.assertEqual(human, result.human_report())
        self.assertIn("[TRUNCATED]", machine)
        self.assertNotIn("server", machine)
        self.assertNotIn("two words", machine)
        self.assertNotIn("\nforged", human)
        self.assertLess(len(machine), authority.MAX_REPORT_TEXT_CHARS + 1_000)
        exception_output = authority.redact_value(
            RuntimeError(r"\\server\share\exception.txt secret=value")
        )
        self.assertNotIn("server", exception_output)
        self.assertNotIn("value", exception_output)

    def test_recursive_or_excessive_diagnostic_structures_are_rejected(self):
        recursive = []
        recursive.append(recursive)
        with self.assertRaises(TypeError):
            authority.AuditResult(
                authority.AuditStatus.MIGRATION_FILES_INVALID,
                (),
                (),
                "009",
                (recursive,),
            )
        with self.assertRaises(TypeError):
            authority.AuditResult(
                authority.AuditStatus.MIGRATION_FILES_INVALID,
                (),
                (),
                "009",
                ((authority.Diagnostic("nested", "value"),),),
            )
        with self.assertRaises(TypeError):
            authority.AuditResult(
                authority.AuditStatus.MIGRATION_FILES_INVALID,
                (),
                (),
                "009",
                tuple(
                    authority.Diagnostic("bounded", str(position))
                    for position in range(authority.MAX_REPORT_DIAGNOSTICS + 1)
                ),
            )

    def test_hostile_containers_and_string_conversion_are_contained(self):
        self.assertEqual(authority.redact_value(RaisingMapping()), "[REDACTED_UNAVAILABLE]")
        self.assertEqual(authority.redact_value(RaisingList()), "[REDACTED_UNAVAILABLE]")

        hostile = mock.Mock()
        hostile.__str__ = mock.Mock(side_effect=RuntimeError("password=exposed"))
        self.assertEqual(authority.sanitize_line(hostile), "[UNAVAILABLE]")

    def test_recursive_redaction_and_single_line_safety(self):
        payload = {
            "list": [{"api-key": "abc"}, "Authorization: Bearer token123"],
            "tuple": ("password=one user=two passphrase=three",),
            "set": {"token=four", "safe"},
            "url": "postgresql://name:p%40ss@host/db?api_key=five&user=six",
            "path": "/private/secret/file\nforged: yes",
        }
        result = authority.redact_value(payload)
        encoded = json.dumps(result, sort_keys=True)
        for secret in ("abc", "token123", "one", "two", "three", "four", "p%40ss", "five", "six", "/private/secret"):
            self.assertNotIn(secret, encoded)
        self.assertNotIn("\n", result["path"])
        self.assertIn("[REDACTED_URL]", result["url"])

    def test_redacts_single_component_paths_quoted_secrets_and_unicode(self):
        text = (
            '/secret secret="two words" password=one token=two '
            "api_key=three passphrase='four words' c1\x85next\u2028line\u2029paragraph\u200bformat"
        )
        sanitized = authority.sanitize_line(text)
        for unsafe in ("/secret", "two words", "one", "two", "three", "four words", "\x85", "\u2028", "\u2029", "\u200b"):
            self.assertNotIn(unsafe, sanitized)
        self.assertNotIn("\n", sanitized)
        self.assertGreaterEqual(sanitized.count("[REDACTED]"), 5)

    def test_exception_and_nested_multiple_secrets_are_sanitized(self):
        value = {
            "errors": [RuntimeError("/only secret=value password='two words'")],
            "nested": ({"credential": "raw"}, {"authorization": "Bearer raw-token"}),
        }
        encoded = json.dumps(authority.redact_value(value), sort_keys=True)
        for unsafe in ("/only", "value", "two words", "raw-token"):
            self.assertNotIn(unsafe, encoded)

    def test_reports_are_deterministic_versioned_and_status_cannot_conflict(self):
        result = authority.AuditResult(
            authority.AuditStatus.MIGRATION_FILES_VERIFIED,
            ("001",), ("007",), "009",
            (authority.Diagnostic("safe", "token=secret\nforged"),),
        )
        self.assertTrue(result.ok)
        self.assertEqual(result.machine_report(), result.machine_report())
        self.assertEqual(result.human_report(), result.human_report())
        self.assertEqual(json.loads(result.machine_report())["format_version"], 1)
        self.assertNotIn("secret", result.machine_report())
        self.assertNotIn("\nforged", result.human_report())
        with self.assertRaises(TypeError):
            authority.AuditResult("migration_files_verified", (), (), "009")
        with self.assertRaises(TypeError):
            authority.AuditResult(authority.AuditStatus.MIGRATION_FILES_INVALID, (), (), "009", ok=True)

    def test_unsafe_or_contradictory_result_fields_are_rejected(self):
        with self.assertRaises(TypeError):
            authority.AuditResult(
                authority.AuditStatus.SNAPSHOT_CONSISTENT, (), (), "009",
                identity_assurance="not_applicable",
            )
        with self.assertRaises(TypeError):
            authority.AuditResult(
                authority.AuditStatus.MIGRATION_FILES_VERIFIED, (), (), "009",
                identity_assurance="unsafe\nforged",
            )
        with self.assertRaises(TypeError):
            authority.AuditResult(
                authority.AuditStatus.MIGRATION_FILES_INVALID, ("bad\nversion",), (), "009",
            )


class IntegrationSafetyTests(unittest.TestCase):
    def test_mutation_actions_remain_rejected(self):
        for action in ("apply", "migrate", "baseline", "bootstrap", "repair", "write", "other"):
            with self.assertRaises(authority.MutationForbiddenError):
                authority.reject_mutation(action)
        authority.reject_mutation("audit")

    def test_production_module_has_no_mutating_dependencies_or_sql(self):
        source = Path(authority.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imports = {
            alias.name.split(".")[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        } | {
            (node.module or "").split(".")[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom)
        }
        self.assertTrue(imports.isdisjoint({"subprocess", "socket", "urllib", "requests", "docker", "psycopg2", "sqlalchemy"}))
        self.assertNotIn("CREATE TABLE", source.upper())
        self.assertNotIn("ALTER TABLE", source.upper())
        os_calls = {
            node.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Attribute)
            and isinstance(node.value, ast.Name)
            and node.value.id == "os"
        }
        self.assertTrue(
            os_calls.isdisjoint(
                {"remove", "unlink", "rename", "replace", "mkdir", "makedirs", "rmdir", "removedirs", "write"}
            )
        )
        self.assertNotIn("O_WRONLY", source)
        self.assertNotIn("O_RDWR", source)
        self.assertNotIn("O_CREAT", source)
        self.assertNotIn("O_TRUNC", source)

    def test_actual_api_and_wsgi_imports_do_not_invoke_verifier(self):
        dangerous = mock.Mock(side_effect=AssertionError("verifier invoked during startup"))
        old_path = list(sys.path)
        module_names = (
            "propertymanager_api", "wsgi", "db", "meter_schedule", "assets_api", "auth",
            "decimal_utils", "errors", "mapping_proposals",
        )
        saved = {name: sys.modules.pop(name) for name in module_names if name in sys.modules}
        try:
            sys.path.insert(0, str(API_DIR))
            with tempfile.TemporaryDirectory(prefix="pm-import-") as temp, mock.patch.dict(
                os.environ,
                {"PROPERTYMANAGER_DB_ENV_FILE": str(Path(temp) / "missing.env"), "PROPERTYMANAGER_AUTH_DISABLED": "1"},
                clear=False,
            ), mock.patch.object(authority, "main", dangerous), mock.patch.object(
                authority, "audit_canonical_migration_files", dangerous
            ), mock.patch.object(authority, "audit_schema_metadata", dangerous):
                api_spec = importlib.util.spec_from_file_location("propertymanager_api", API_DIR / "propertymanager_api.py")
                assert api_spec and api_spec.loader
                api_module = importlib.util.module_from_spec(api_spec)
                sys.modules["propertymanager_api"] = api_module
                api_spec.loader.exec_module(api_module)
                wsgi_spec = importlib.util.spec_from_file_location("wsgi", API_DIR / "wsgi.py")
                assert wsgi_spec and wsgi_spec.loader
                wsgi_module = importlib.util.module_from_spec(wsgi_spec)
                wsgi_spec.loader.exec_module(wsgi_module)
                self.assertIs(wsgi_module.application, api_module.app)
                dangerous.assert_not_called()
        finally:
            sys.path[:] = old_path
            for name in module_names:
                sys.modules.pop(name, None)
            sys.modules.update(saved)


if __name__ == "__main__":
    unittest.main()
