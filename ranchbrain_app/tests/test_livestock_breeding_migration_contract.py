from pathlib import Path
import unittest


MIGRATION = Path(__file__).parents[1] / "migrations" / "031_livestock_breeding.sql"


class LivestockBreedingMigrationContractTests(unittest.TestCase):
    def test_migration_is_dev_only_after_030_and_never_production(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        header = "\n".join(sql.splitlines()[:4])
        self.assertIn("DEV-only", header)
        self.assertIn("Never apply this file to Production", header)
        self.assertIn("ranchos_dev_migrator", header)
        self.assertIn("after 030", header)

    def test_migration_fails_closed_unless_current_user_is_dev_migrator(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertLess(sql.index("current_user <> 'ranchos_dev_migrator'"), sql.index("ALTER TABLE"))
        self.assertIn("this DEV migration must run as ranchos_dev_migrator", sql)
        self.assertIn("ranchos_dev_runtime must not have BYPASSRLS", sql)

    def test_breeding_columns_are_tenant_safe_and_runtime_can_update_only_those(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("ADD COLUMN sire_animal_id uuid", sql)
        self.assertIn("ADD COLUMN dam_animal_id uuid", sql)
        self.assertIn("ADD COLUMN bred_with_animal_id uuid", sql)
        self.assertIn("livestock_animals_sire_matches_tenant", sql)
        self.assertIn("livestock_animals_dam_matches_tenant", sql)
        self.assertIn("livestock_animals_bred_with_matches_tenant", sql)
        self.assertIn("FOREIGN KEY (tenant_id, sire_animal_id)", sql)
        self.assertIn("livestock_animals_not_own_sire", sql)
        self.assertIn("livestock_animals_sire_differs_from_dam", sql)
        self.assertIn("livestock_animals_pet_has_no_breeding", sql)
        self.assertIn("sire must be the same species", sql)
        self.assertIn("GRANT UPDATE (sire_animal_id, dam_animal_id, bred_with_animal_id)", sql)
        self.assertNotIn("GRANT UPDATE ON ranchos.livestock_animals", sql)
        self.assertNotIn("GRANT ALL", sql)
