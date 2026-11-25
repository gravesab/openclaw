from pathlib import Path
import unittest


MIGRATION = Path(__file__).parents[1] / "migrations" / "032_livestock_care_dosage.sql"


class LivestockCareDosageMigrationContractTests(unittest.TestCase):
    def test_migration_is_dev_only_after_031_and_never_production(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        header = "\n".join(sql.splitlines()[:4])
        self.assertIn("DEV-only", header)
        self.assertIn("Never apply this file to Production", header)
        self.assertIn("ranchos_dev_migrator", header)
        self.assertIn("after 031", header)

    def test_migration_fails_closed_unless_current_user_is_dev_migrator(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertLess(sql.index("current_user <> 'ranchos_dev_migrator'"), sql.index("ALTER TABLE"))
        self.assertIn("this DEV migration must run as ranchos_dev_migrator", sql)
        self.assertIn("ranchos_dev_runtime must not have BYPASSRLS", sql)

    def test_dosage_is_optional_text_on_medicine_care_only(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        self.assertIn("ADD COLUMN dosage text", sql)
        self.assertIn("livestock_care_events_dosage_check", sql)
        self.assertIn("char_length(dosage) BETWEEN 1 AND 80", sql)
        self.assertIn("livestock_care_events_dosage_medicine_only", sql)
        self.assertIn("'vaccination'", sql)
        self.assertIn("'medication_administration'", sql)
        self.assertNotIn("GRANT ALL", sql)
