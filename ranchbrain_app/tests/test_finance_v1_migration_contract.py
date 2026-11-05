"""Static contract checks for migrations/005_finance_v1_foundation.sql."""

import re
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parents[1] / "migrations"
SQL = (MIGRATIONS / "005_finance_v1_foundation.sql").read_text()
TABLES = sorted(set(re.findall(r"CREATE TABLE ranchos\.(finance_\w+)", SQL)))


def test_single_005_and_dev_only_header():
    assert [p.name for p in MIGRATIONS.glob("005_*.sql")] == ["005_finance_v1_foundation.sql"]
    head = SQL[:800]
    assert "Never apply this file to Production" in head
    assert "ranchos_dev_migrator" in head and "ranchos_livestock_dev" in head


def test_expected_tables():
    assert TABLES == [
        "finance_accounts", "finance_audit_events", "finance_categories",
        "finance_domains", "finance_transactions", "finance_transfers",
    ]


def test_every_table_is_tenant_scoped_forced_rls_and_owned():
    for table in TABLES:
        body = SQL.split(f"CREATE TABLE ranchos.{table} (", 1)[1].split(");", 1)[0]
        assert "tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id)" in body, table
        assert "PRIMARY KEY (tenant_id, id)" in body, table
        assert f"ALTER TABLE ranchos.{table} ENABLE ROW LEVEL SECURITY;" in SQL, table
        assert f"ALTER TABLE ranchos.{table} FORCE ROW LEVEL SECURITY;" in SQL, table
        assert f"CREATE POLICY {table}_tenant_isolation ON ranchos.{table}" in SQL, table
        assert f"ALTER TABLE ranchos.{table} OWNER TO ranchos_dev_migrator;" in SQL, table
        assert f"'{table}'" in SQL.split("FOREACH table_name", 1)[1], table


def test_finance_foreign_keys_are_tenant_composite():
    for fk in re.findall(r"FOREIGN KEY \(([^)]*)\)\s+REFERENCES ranchos\.finance_", SQL):
        assert fk.startswith("tenant_id,"), fk


def test_amount_semantics_and_no_enums_or_direction_column():
    assert "CREATE TYPE" not in SQL
    assert not re.search(r"^\s+direction\s", SQL, re.M)
    assert "amount numeric(14,2) NOT NULL CHECK (amount <> 0)" in SQL


def test_runtime_grants_are_read_only_plus_append_only_audit():
    grants = re.findall(r"GRANT ([A-Z, ]+) ON (.+?) TO ranchos_dev_runtime;", SQL, re.S)
    assert ("SELECT", ) == tuple({g[0] for g in grants} - {"INSERT"})
    assert all("finance_audit_events" in target for priv, target in grants if priv == "INSERT")
    assert "BEFORE UPDATE OR DELETE ON ranchos.finance_audit_events" in SQL


def test_seed_domains_are_personal_ranch_zero_g():
    seed = SQL.split("FUNCTION ranchos.finance_seed_domains()", 1)[1]
    assert re.findall(r"'(personal|ranch|zero_g)', '", seed) == ["personal", "ranch", "zero_g"]
    assert "REVOKE ALL ON FUNCTION ranchos.finance_seed_domains() FROM PUBLIC" in SQL
