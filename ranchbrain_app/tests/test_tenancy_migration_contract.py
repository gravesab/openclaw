from pathlib import Path


MIGRATION = Path(__file__).parents[1] / "migrations" / "001_ranch_os_tenancy_foundation.sql"


def test_tenancy_migration_requires_separate_runtime_and_migrator_roles():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "ranchos_dev_migrator" in sql
    assert "ranchos_dev_runtime" in sql
    assert "must be provisioned before this migration" in sql


def test_every_tenant_owned_table_enables_and_forces_rls_with_read_and_write_policy():
    sql = MIGRATION.read_text(encoding="utf-8")
    for table in ("tenants", "tenant_memberships", "ranchbrain_memories"):
        assert f"ALTER TABLE ranchos.{table} ENABLE ROW LEVEL SECURITY" in sql
        assert f"ALTER TABLE ranchos.{table} FORCE ROW LEVEL SECURITY" in sql
    assert sql.count("ranchos.require_uuid_setting('ranchos.tenant_id')") >= 6
    assert "WITH CHECK" in sql


def test_migration_has_tenant_aware_memory_key_and_creator_relationship():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "PRIMARY KEY (tenant_id, id)" in sql
    assert "FOREIGN KEY (tenant_id, created_by_user_id)" in sql
    assert "REFERENCES ranchos.tenant_memberships (tenant_id, user_id)" in sql


def test_migration_declares_unapplied_dev_only_never_production():
    sql = MIGRATION.read_text(encoding="utf-8")
    header = "\n".join(sql.splitlines()[:3])
    assert "Unapplied DEV-only" in header
    assert "Never apply this file to Production" in header
    assert "ranchos_dev_migrator" in header


def test_migration_fails_closed_unless_current_user_is_dev_migrator():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert sql.index("current_user <> 'ranchos_dev_migrator'") < sql.index("CREATE SCHEMA")
    assert "this DEV migration must run as ranchos_dev_migrator" in sql


def test_migration_rejects_runtime_bypassrls():
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "rolbypassrls" in sql
    assert "WHERE rolname = 'ranchos_dev_runtime'" in sql
    assert "ranchos_dev_runtime must not have BYPASSRLS" in sql
    assert sql.index("ranchos_dev_runtime must not have BYPASSRLS") < sql.index("CREATE SCHEMA")


def test_migration_assigns_and_asserts_migrator_ownership_and_forced_rls():
    sql = MIGRATION.read_text(encoding="utf-8")
    for table in ("tenants", "users", "tenant_memberships", "ranchbrain_memories"):
        assert f"ALTER TABLE ranchos.{table} OWNER TO ranchos_dev_migrator" in sql
    assert "relforcerowsecurity" in sql
    assert "must be owned by ranchos_dev_migrator" in sql
    assert "must enable and force RLS" in sql
