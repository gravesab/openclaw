from pathlib import Path
import unittest


MIGRATION = Path(__file__).parents[1] / "migrations" / "002_livestock_read_model_foundation.sql"
RLS_PROOF = Path(__file__).parent / "rls" / "two_tenant_livestock_isolation.sql"

LIVESTOCK_TABLES = (
    "livestock_animals",
    "animal_identifiers",
    "animal_identifier_retirements",
    "livestock_lifecycle_events",
    "livestock_idempotency",
    "livestock_confirmations",
    "livestock_mutation_audit",
)

RUNTIME_COUNT_TABLES = (
    "livestock_animals",
    "animal_identifiers",
    "animal_identifier_retirements",
    "livestock_lifecycle_events",
    "livestock_idempotency",
    "livestock_confirmations",
)


class LivestockMigrationContractTests(unittest.TestCase):
    def test_migration_declares_unapplied_dev_only_never_production(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        header = "\n".join(sql.splitlines()[:3])
        self.assertIn("Unapplied DEV-only", header)
        self.assertIn("Never apply this file to Production", header)
        self.assertIn("ranchos_dev_migrator", header)

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

    def test_catalog_is_pet_companion_create_immutable_and_rejects_stale_species(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("'pet'", sql)
        self.assertIn("(species_code = 'pet' AND production_type_code IN ('companion'))", sql)
        self.assertIn("livestock_animals_pet_has_no_breed", sql)
        self.assertIn("CHECK (status = 'active')", sql)
        self.assertNotIn("updated_at", sql)
        self.assertNotIn("'rabbit'", sql)
        self.assertNotIn("'other'", sql)
        self.assertNotIn("'archived'", sql)

    def test_identifier_assignments_are_immutable_with_separate_retirements(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("CREATE TABLE ranchos.animal_identifiers", sql)
        self.assertIn("CREATE TABLE ranchos.animal_identifier_retirements", sql)
        self.assertIn("identifier_type IN (\n        'ear_tag', 'rfid', 'brand', 'registry_number'\n    )", sql)
        self.assertIn("reason IN ('replaced', 'lost', 'invalid', 'duplicate')", sql)
        self.assertIn("UNIQUE (tenant_id, identifier_id)", sql)
        self.assertIn("CONSTRAINT TRIGGER animal_identifiers_active_uniqueness", sql)
        self.assertIn("CONSTRAINT TRIGGER animal_identifier_retirements_before_effective", sql)
        self.assertNotIn("WHERE retired_at IS NULL", sql)
        self.assertNotIn("vendor_label", sql)
        self.assertNotRegex(sql, r"identifier_type IN \([^)]*'tag'")
        assignment_block = sql.split("CREATE TABLE ranchos.animal_identifiers", 1)[1].split(
            "CREATE TABLE ranchos.animal_identifier_retirements", 1
        )[0]
        self.assertNotIn("retired_at", assignment_block)
        self.assertNotRegex(assignment_block, r"(?m)^\s+value\s+text\b")
        self.assertIn("normalized_value text", assignment_block)

    def test_lifecycle_uses_same_table_supersession_and_closed_correction_reasons(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("event_type IN ('intake', 'tagged', 'weight_recorded')", sql)
        self.assertIn("supersedes_event_id", sql)
        self.assertIn("correction_reason IN (\n        'incorrect_time', 'incorrect_value', 'duplicate_entry'\n    )", sql)
        self.assertIn("livestock_lifecycle_events_supersedes_unique", sql)
        self.assertIn("CONSTRAINT TRIGGER livestock_lifecycle_events_same_type_supersession", sql)

    def test_domain_rows_carry_provenance_and_named_support_tables(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        for column in (
            "provenance_source_type",
            "provenance_source_id",
            "provenance_source_version",
            "provenance_observed_at",
        ):
            self.assertGreaterEqual(sql.count(column), 4)
        self.assertIn("CREATE TABLE ranchos.livestock_idempotency", sql)
        self.assertIn("PRIMARY KEY (tenant_id, scope, identity)", sql)
        self.assertNotIn("PRIMARY KEY (tenant_id, scope, key_digest)", sql)
        self.assertIn("ranchos.livestock.animal-create", sql)
        self.assertIn("ranchos.livestock.identifier-assign", sql)
        self.assertIn("ranchos.livestock.identifier-retire", sql)
        self.assertIn("ranchos.livestock.lifecycle-record", sql)
        self.assertIn("ranchos.livestock.lifecycle-correct", sql)
        self.assertNotIn("'animal_create'", sql)
        self.assertIn("CHECK (scope = operation)", sql)
        self.assertIn("outcome IN ('reserved', 'committed')", sql)
        self.assertIn("result_animal_id", sql)
        self.assertIn("livestock_idempotency_committed_animal_matches_tenant", sql)
        self.assertIn("PRIMARY KEY (tenant_id, id)", sql)
        self.assertIn("REFERENCES ranchos.livestock_animals (tenant_id, id)", sql)
        self.assertIn("livestock_idempotency_finalize_only", sql)
        self.assertIn("committed idempotency is immutable", sql)
        self.assertIn("CREATE TABLE ranchos.livestock_confirmations", sql)
        self.assertIn("expires_at = issued_at + interval '2 minutes'", sql)
        self.assertIn("CURRENT_TIMESTAMP", sql)
        self.assertIn("CREATE TABLE ranchos.livestock_mutation_audit", sql)
        self.assertIn("GRANT INSERT ON ranchos.livestock_mutation_audit TO ranchos_dev_runtime", sql)
        self.assertNotIn("GRANT SELECT ON ranchos.livestock_mutation_audit", sql)
        self.assertNotIn("GRANT SELECT, INSERT, UPDATE, DELETE ON ranchos.livestock_mutation_audit", sql)

    def test_every_livestock_table_forces_rls_ownership_and_tenant_policy(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        for table in LIVESTOCK_TABLES:
            self.assertIn(f"ALTER TABLE ranchos.{table} ENABLE ROW LEVEL SECURITY", sql)
            self.assertIn(f"ALTER TABLE ranchos.{table} FORCE ROW LEVEL SECURITY", sql)
            self.assertIn(f"ALTER TABLE ranchos.{table} OWNER TO ranchos_dev_migrator", sql)
            self.assertIn(f"CREATE POLICY {table}_tenant_isolation ON ranchos.{table}", sql)
        self.assertGreaterEqual(sql.count("ranchos.require_uuid_setting('ranchos.tenant_id')"), 14)
        self.assertIn("WITH CHECK", sql)
        self.assertIn("relforcerowsecurity", sql)
        self.assertIn("must be owned by ranchos_dev_migrator", sql)
        self.assertIn("must enable and force RLS", sql)

    def test_disposable_rls_proof_is_rollback_only_two_tenant_and_uses_committed_fixtures(self):
        sql = RLS_PROOF.read_text(encoding="utf-8")
        self.assertIn("Rollback-only", sql)
        self.assertIn("ROLLBACK", sql)
        self.assertIn("SET LOCAL ROLE ranchos_dev_runtime", sql)
        self.assertIn("RESET ROLE", sql)
        self.assertIn("'ear_tag'", sql)
        self.assertIn("'pet'", sql)
        self.assertIn("'companion'", sql)
        self.assertIn("ranchos.livestock.animal-create", sql)
        self.assertIn("result_animal_id", sql)
        self.assertNotIn("'animal_create'", sql)
        self.assertNotIn("'tag'", sql)
        self.assertNotIn("vendor_label", sql)
        for table in RUNTIME_COUNT_TABLES:
            self.assertIn(f"count(*) FROM ranchos.{table}", sql)
        self.assertIn("count(*) FROM ranchos.livestock_mutation_audit", sql)
        self.assertIn("runtime selected livestock mutation audit", sql)
        self.assertIn("migrator under FORCE RLS can see cross-tenant livestock audit", sql)
        self.assertIn("Tenant A cross-tenant livestock assign was accepted", sql)
        self.assertIn("Tenant A cross-tenant livestock retire was accepted", sql)
        self.assertIn("Tenant A cross-tenant livestock correct was accepted", sql)
        self.assertIn("missing SET LOCAL ranchos.tenant_id was accepted", sql)
        self.assertIn("malformed SET LOCAL ranchos.tenant_id was accepted", sql)
        self.assertIn("ranchos_dev_runtime must not have BYPASSRLS", sql)
        self.assertLess(sql.index("SET LOCAL ROLE ranchos_dev_runtime"), sql.index("RESET ROLE"))
        self.assertLess(sql.index("RESET ROLE"), sql.rindex("count(*) FROM ranchos.livestock_mutation_audit"))
