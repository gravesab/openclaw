-- Date an asset was first placed into service. This is a civil date, not a timestamp.
BEGIN;

ALTER TABLE propertymanager.assets
    ADD COLUMN placed_in_service_date date;

-- Written last inside the same transaction so the ledger reports 014 only
-- when the migration committed.
INSERT INTO propertymanager.schema_migrations (version)
VALUES ('014')
ON CONFLICT (version) DO NOTHING;

COMMIT;
