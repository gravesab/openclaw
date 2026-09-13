from pathlib import Path
import unittest


MIGRATION = Path(__file__).parents[1] / "migrations" / "003_livestock_identifier_idempotency_outcomes.sql"
FOUNDATION = Path(__file__).parents[1] / "migrations" / "002_livestock_read_model_foundation.sql"


class LivestockIdentifierMigrationContractTests(unittest.TestCase):
    def test_migration_declares_unapplied_dev_only_after_001_and_002(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        header = "\n".join(sql.splitlines()[:3])
        self.assertIn("Unapplied DEV-only", header)
        self.assertIn("Never apply this file to Production", header)
        self.assertIn("ranchos_dev_migrator", header)
        self.assertIn("after 001 and 002", header)

    def test_migration_fails_closed_without_migrator_runtime_or_foundations(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertLess(sql.index("current_user <> 'ranchos_dev_migrator'"), sql.index("ALTER TABLE"))
        self.assertIn("this DEV migration must run as ranchos_dev_migrator", sql)
        self.assertIn("ranchos_dev_migrator and ranchos_dev_runtime must be provisioned before this migration", sql)
        self.assertIn("ranchos_dev_runtime must not have BYPASSRLS", sql)
        self.assertIn("001 tenancy foundation is required before this migration", sql)
        self.assertIn("002 livestock foundation is required before this migration", sql)
        self.assertIn("require_uuid_setting", sql)
        self.assertIn("result_animal_id", sql)
        self.assertIn("livestock_idempotency_reserved_has_no_animal", sql)
        self.assertNotIn("CREATE SCHEMA", sql)
        self.assertNotIn("CREATE OR REPLACE FUNCTION ranchos.require_uuid_setting", sql)
        self.assertNotIn("CREATE TABLE ranchos.livestock_idempotency", sql)
        self.assertNotIn("CREATE TABLE ranchos.animal_identifiers", sql)
        self.assertNotIn("CREATE TABLE ranchos.animal_identifier_retirements", sql)

    def test_result_references_are_tenant_safe_and_operation_exact(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("ADD COLUMN result_identifier_id uuid", sql)
        self.assertIn("ADD COLUMN result_retirement_id uuid", sql)
        self.assertIn("livestock_idempotency_committed_identifier_matches_tenant", sql)
        self.assertIn("FOREIGN KEY (tenant_id, result_identifier_id)", sql)
        self.assertIn("REFERENCES ranchos.animal_identifiers (tenant_id, id)", sql)
        self.assertIn("livestock_idempotency_committed_retirement_matches_tenant", sql)
        self.assertIn("FOREIGN KEY (tenant_id, result_retirement_id)", sql)
        self.assertIn("REFERENCES ranchos.animal_identifier_retirements (tenant_id, id)", sql)
        self.assertIn("DROP CONSTRAINT livestock_idempotency_reserved_has_no_animal", sql)
        self.assertIn("livestock_idempotency_result_matches_operation", sql)
        self.assertIn("outcome = 'reserved'", sql)
        self.assertIn("operation = 'ranchos.livestock.animal-create'", sql)
        self.assertIn("operation = 'ranchos.livestock.identifier-assign'", sql)
        self.assertIn("operation = 'ranchos.livestock.identifier-retire'", sql)
        self.assertIn("result_animal_id IS NOT NULL", sql)
        self.assertIn("result_identifier_id IS NOT NULL", sql)
        self.assertIn("result_retirement_id IS NOT NULL", sql)
        self.assertNotIn("operation = 'ranchos.livestock.lifecycle-record'", sql)
        self.assertNotIn("operation = 'ranchos.livestock.lifecycle-correct'", sql)
        self.assertNotIn("'animal_create'", sql)
        self.assertNotIn("'identifier_assign'", sql)
        self.assertNotIn("'identifier_retire'", sql)

    def test_finalize_keeps_identity_digest_and_committed_rows_immutable(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("CREATE OR REPLACE FUNCTION ranchos.livestock_idempotency_enforce_finalize_only()", sql)
        self.assertIn("idempotency identity is immutable", sql)
        self.assertIn("committed idempotency is immutable", sql)
        self.assertIn("OLD.key_digest IS DISTINCT FROM NEW.key_digest", sql)
        self.assertIn("OLD.scope IS DISTINCT FROM NEW.scope", sql)
        self.assertIn("OLD.operation IS DISTINCT FROM NEW.operation", sql)
        self.assertIn("OLD.identity IS DISTINCT FROM NEW.identity", sql)
        self.assertIn("OLD.transaction_id IS DISTINCT FROM NEW.transaction_id", sql)
        self.assertIn("OLD.outcome <> 'reserved' OR NEW.outcome <> 'committed'", sql)
        self.assertIn("ELSE", sql)
        self.assertIn("idempotency finalize is invalid", sql)

    def test_rls_ownership_grants_and_matrix_ids_stay_aligned(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("ALTER TABLE ranchos.livestock_idempotency ENABLE ROW LEVEL SECURITY", sql)
        self.assertIn("ALTER TABLE ranchos.livestock_idempotency FORCE ROW LEVEL SECURITY", sql)
        self.assertIn("ALTER TABLE ranchos.livestock_idempotency OWNER TO ranchos_dev_migrator", sql)
        self.assertIn("GRANT SELECT, INSERT, UPDATE ON ranchos.livestock_idempotency TO ranchos_dev_runtime", sql)
        self.assertNotIn("GRANT SELECT ON ranchos.livestock_mutation_audit", sql)
        self.assertNotIn("BYPASSRLS", sql.split("ranchos_dev_runtime must not have BYPASSRLS", 1)[1])
        self.assertIn("livestock_idempotency_tenant_isolation", FOUNDATION.read_text(encoding="utf-8"))
        self.assertIn("CHECK (scope = operation)", FOUNDATION.read_text(encoding="utf-8"))
        self.assertIn("PRIMARY KEY (tenant_id, scope, identity)", FOUNDATION.read_text(encoding="utf-8"))

    def test_contract_rejects_outcome_scanning_and_scope_encoding(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertNotIn("PRIMARY KEY (tenant_id, scope, key_digest)", sql)
        self.assertNotIn("PRIMARY KEY (tenant_id, scope, identity)", sql)
        self.assertNotIn("scope ||", sql)
        self.assertNotIn("identity ||", sql)
        self.assertNotIn("encode(", sql)
        self.assertNotIn("SELECT id FROM ranchos.livestock_animals", sql)
        self.assertNotIn("SELECT id FROM ranchos.animal_identifiers", sql)
        self.assertNotIn("SELECT id FROM ranchos.animal_identifier_retirements", sql)
        self.assertNotIn("FROM ranchos.livestock_animals", sql)
        self.assertNotIn("FROM ranchos.animal_identifiers", sql)
        self.assertNotIn("FROM ranchos.animal_identifier_retirements", sql)


if __name__ == "__main__":
    unittest.main()
