-- Pseudo assets: display-only groups (e.g. Mowers). Members attach via host_asset_id.
-- Pseudo rows are always roots (no host of their own).
BEGIN;

ALTER TABLE propertymanager.assets
    ADD COLUMN is_pseudo boolean NOT NULL DEFAULT false;

ALTER TABLE propertymanager.assets
    ADD CONSTRAINT assets_pseudo_root_check
        CHECK (NOT is_pseudo OR host_asset_id IS NULL);

-- Written last inside the same transaction so the ledger reports 018 only
-- when the migration committed.
INSERT INTO propertymanager.schema_migrations (version)
VALUES ('018')
ON CONFLICT (version) DO NOTHING;

COMMIT;
