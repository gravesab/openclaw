from pathlib import Path
import unittest


MIGRATION = Path(__file__).parents[1] / "migrations" / "005_finance_persistence_foundation.sql"
RLS_PROOF = Path(__file__).parent / "rls" / "two_tenant_finance_isolation.sql"
LIVESTOCK_CONFIRMATIONS = Path(__file__).parents[1] / "migrations" / "006_livestock_confirmation_challenges.sql"

FINANCE_TABLES = (
    "finance_accounts",
    "finance_source_artifacts",
    "finance_source_activities",
    "finance_journal_entries",
    "finance_journal_lines",
    "finance_interpretations",
    "finance_splits",
    "finance_idempotency",
    "finance_mutation_audit",
)

RUNTIME_COUNT_TABLES = (
    "finance_accounts",
    "finance_source_artifacts",
    "finance_source_activities",
    "finance_journal_entries",
    "finance_journal_lines",
    "finance_interpretations",
    "finance_splits",
    "finance_idempotency",
)


class FinanceMigrationContractTests(unittest.TestCase):
    def test_migration_declares_unapplied_dev_only_never_production(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        header = "\n".join(sql.splitlines()[:3])
        self.assertIn("Unapplied DEV-only", header)
        self.assertIn("Never apply this file to Production", header)
        self.assertIn("ranchos_dev_migrator", header)
        self.assertIn("after 001", header)

    def test_migration_fails_closed_unless_current_user_is_dev_migrator(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertLess(sql.index("current_user <> 'ranchos_dev_migrator'"), sql.index("CREATE TABLE"))
        self.assertIn("this DEV migration must run as ranchos_dev_migrator", sql)
        self.assertNotIn("CREATE SCHEMA", sql)
        self.assertNotIn("CREATE OR REPLACE FUNCTION ranchos.require_uuid_setting", sql)

    def test_migration_rejects_runtime_bypassrls(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("rolbypassrls", sql)
        self.assertIn("WHERE rolname = 'ranchos_dev_runtime'", sql)
        self.assertIn("ranchos_dev_runtime must not have BYPASSRLS", sql)
        self.assertLess(sql.index("ranchos_dev_runtime must not have BYPASSRLS"), sql.index("CREATE TABLE"))

    def test_future_livestock_confirmation_challenges_must_not_use_005(self):
        self.assertFalse(LIVESTOCK_CONFIRMATIONS.exists())
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("005_finance_persistence_foundation", str(MIGRATION))
        self.assertNotIn("livestock_confirmations", sql)
        self.assertNotIn("confirmation-challenges", sql)

    def test_source_artifacts_are_metadata_only(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("CREATE TABLE ranchos.finance_source_artifacts", sql)
        self.assertIn("original_filename", sql)
        self.assertIn("content_digest", sql)
        self.assertIn("byte_size integer NOT NULL CHECK (byte_size >= 0)", sql)
        self.assertNotIn("bytea", sql.lower())
        self.assertNotIn("file_body", sql)
        self.assertNotIn("contents", sql)

    def test_domain_rows_are_immutable_with_named_support_tables(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertNotIn("updated_at", sql)
        self.assertIn("CREATE TABLE ranchos.finance_idempotency", sql)
        self.assertIn("PRIMARY KEY (tenant_id, scope, identity)", sql)
        self.assertIn("ranchos.finance.account-create", sql)
        self.assertIn("ranchos.finance.source-artifact-record", sql)
        self.assertIn("ranchos.finance.source-activity-record", sql)
        self.assertIn("ranchos.finance.interpretation-post", sql)
        self.assertIn("ranchos.finance.interpretation-reverse", sql)
        self.assertIn("ranchos.finance.interpretation-supersede", sql)
        self.assertIn("CHECK (scope = operation)", sql)
        self.assertIn("outcome IN ('reserved', 'committed')", sql)
        self.assertIn("finance_idempotency_finalize_only", sql)
        self.assertIn("committed idempotency is immutable", sql)
        self.assertIn("CREATE TABLE ranchos.finance_mutation_audit", sql)
        self.assertIn("GRANT INSERT ON ranchos.finance_mutation_audit TO ranchos_dev_runtime", sql)
        self.assertNotIn("GRANT SELECT ON ranchos.finance_mutation_audit", sql)
        self.assertIn("GRANT SELECT, INSERT, UPDATE ON ranchos.finance_idempotency TO ranchos_dev_runtime", sql)
        domain_grant = "GRANT SELECT, INSERT ON ranchos.finance_accounts, ranchos.finance_source_artifacts"
        self.assertIn(domain_grant, sql)
        self.assertNotIn("GRANT SELECT, INSERT, UPDATE, DELETE ON ranchos.finance_accounts", sql)
        self.assertNotIn("GRANT UPDATE ON ranchos.finance_accounts", sql)
        self.assertNotIn("GRANT DELETE ON ranchos.finance_accounts", sql)

    def test_every_finance_table_forces_rls_ownership_and_tenant_policy(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        for table in FINANCE_TABLES:
            self.assertIn(f"ALTER TABLE ranchos.{table} ENABLE ROW LEVEL SECURITY", sql)
            self.assertIn(f"ALTER TABLE ranchos.{table} FORCE ROW LEVEL SECURITY", sql)
            self.assertIn(f"ALTER TABLE ranchos.{table} OWNER TO ranchos_dev_migrator", sql)
            self.assertIn(f"CREATE POLICY {table}_tenant_isolation ON ranchos.{table}", sql)
        self.assertGreaterEqual(sql.count("ranchos.require_uuid_setting('ranchos.tenant_id')"), 18)
        self.assertIn("WITH CHECK", sql)
        self.assertIn("relforcerowsecurity", sql)
        self.assertIn("must be owned by ranchos_dev_migrator", sql)
        self.assertIn("must enable and force RLS", sql)

    def test_disposable_rls_proof_is_rollback_only_two_tenant_and_two_owners(self):
        sql = RLS_PROOF.read_text(encoding="utf-8")
        self.assertIn("Rollback-only", sql)
        self.assertIn("ROLLBACK", sql)
        self.assertIn("SET LOCAL ROLE ranchos_dev_runtime", sql)
        self.assertIn("RESET ROLE", sql)
        self.assertIn("'owner'", sql)
        self.assertIn("00000000-0000-0000-0000-000000000013", sql)
        self.assertIn("ranchos.finance.account-create", sql)
        self.assertIn("result_account_id", sql)
        self.assertNotIn("bytea", sql.lower())
        for table in RUNTIME_COUNT_TABLES:
            self.assertIn(f"count(*) FROM ranchos.{table}", sql)
        self.assertIn("count(*) FROM ranchos.finance_mutation_audit", sql)
        self.assertIn("runtime selected finance mutation audit", sql)
        self.assertIn("migrator under FORCE RLS can see cross-tenant finance audit", sql)
        self.assertIn("Tenant A cross-tenant finance account write was accepted", sql)
        self.assertIn("Tenant A cross-tenant finance source write was accepted", sql)
        self.assertIn("Tenant A cross-tenant finance interpretation write was accepted", sql)
        self.assertIn("Tenant A cross-tenant finance reverse was accepted", sql)
        self.assertIn("Tenant A cross-tenant finance supersede was accepted", sql)
        self.assertIn("zero-line journal interpretation was accepted", sql)
        self.assertIn("one-line journal interpretation was accepted", sql)
        self.assertIn("unrepresentative journal interpretation was accepted", sql)
        self.assertIn("unbound reversal journal was accepted", sql)
        self.assertIn("non-inverted reversal journal was accepted", sql)
        self.assertIn("supersede without reversal was accepted", sql)
        self.assertIn("runtime updated a finance domain row", sql)
        self.assertIn("runtime deleted a finance domain row", sql)
        self.assertIn("missing SET LOCAL ranchos.tenant_id was accepted", sql)
        self.assertIn("malformed SET LOCAL ranchos.tenant_id was accepted", sql)
        self.assertIn("ranchos_dev_runtime must not have BYPASSRLS", sql)
        self.assertLess(sql.index("SET LOCAL ROLE ranchos_dev_runtime"), sql.index("RESET ROLE"))
        self.assertLess(sql.index("RESET ROLE"), sql.rindex("count(*) FROM ranchos.finance_mutation_audit"))

    def test_migration_enforces_posted_immutability_completeness_and_paired_supersession(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("age(interpretation.xmin)", sql)
        self.assertIn("Posted lines and splits may be inserted only in the same PostgreSQL", sql)
        self.assertIn("posted journal lines are immutable", sql)
        self.assertIn("posted splits are immutable", sql)
        self.assertIn("finance_journal_lines_posted_immutable", sql)
        self.assertIn("finance_splits_posted_immutable", sql)
        self.assertIn("interpretation journal must have at least two balanced lines", sql)
        self.assertIn("finance_interpretations_journal_complete", sql)
        self.assertIn("superseding interpretation requires a paired reversal", sql)
        self.assertIn("finance_interpretations_paired_supersession", sql)
        self.assertIn("journal must represent the supplied splits and source activity", sql)
        self.assertIn("finance_interpretations_split_derived", sql)
        self.assertIn("reversal journal must invert the original lines", sql)
        self.assertIn("reversal journal must bind the original journal", sql)
        self.assertIn("finance_interpretations_reversal_bound", sql)
        self.assertIn("finance_interpretations_root_activity_unique", sql)
        self.assertIn("WHERE reverses_id IS NULL AND supersedes_id IS NULL", sql)
        self.assertIn("USING ERRCODE = '23514'", sql)
        self.assertIn("DEFERRABLE INITIALLY DEFERRED", sql)
