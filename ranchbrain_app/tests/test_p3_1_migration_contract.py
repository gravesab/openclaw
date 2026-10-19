"""Static contract for migration 007. No database."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "migrations" / "007_ranchbrain_api_membership.sql"
SQL = MIGRATION.read_text()


def test_migration_is_007_not_006():
    assert MIGRATION.name == "007_ranchbrain_api_membership.sql"
    assert list((ROOT / "migrations").glob("006_ranchbrain*")) == []
    assert "006_ranchbrain" not in SQL


def test_migration_is_migrator_only_and_runtime_cannot_bypass_rls():
    assert "current_user <> 'ranchos_dev_migrator'" in SQL
    assert "ranchos_dev_runtime must not have BYPASSRLS" in SQL
    assert "rolbypassrls" in SQL


def test_links_table_forces_rls_and_runtime_has_execute_only():
    assert "CREATE TABLE ranchos.oidc_principal_links" in SQL
    assert "ENABLE ROW LEVEL SECURITY" in SQL
    assert "FORCE ROW LEVEL SECURITY" in SQL
    assert "SECURITY DEFINER" in SQL
    assert "SET search_path = ranchos, pg_temp" in SQL
    assert "GRANT EXECUTE ON FUNCTION ranchos.resolve_api_membership(text, text, uuid) TO ranchos_dev_runtime" in SQL
    assert "REVOKE ALL ON FUNCTION ranchos.resolve_api_membership(text, text, uuid) FROM PUBLIC" in SQL
    assert "REVOKE ALL ON TABLE ranchos.oidc_principal_links FROM ranchos_dev_runtime" in SQL
    assert "GRANT SELECT" not in SQL
    assert "GRANT INSERT" not in SQL


def test_pyproject_pins_approved_verifier():
    text = (ROOT / "pyproject.toml").read_text()
    assert "google-auth==2.59.1" in text
    assert "cryptography==50.0.2" in text
