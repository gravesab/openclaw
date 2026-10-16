-- Asset host: an implement/attachment may be attached to at most one host asset.
-- Example: JD rototiller host_asset_id → John Deere 1025R.
BEGIN;

ALTER TABLE propertymanager.assets
    ADD COLUMN host_asset_id uuid
        REFERENCES propertymanager.assets(id) ON DELETE SET NULL;

ALTER TABLE propertymanager.assets
    ADD CONSTRAINT assets_host_asset_id_not_self_check
        CHECK (host_asset_id IS DISTINCT FROM id);

CREATE INDEX assets_host_asset_id_idx
    ON propertymanager.assets (host_asset_id)
    WHERE host_asset_id IS NOT NULL;

-- Written last inside the same transaction so the ledger reports 016 only
-- when the migration committed.
INSERT INTO propertymanager.schema_migrations (version)
VALUES ('016')
ON CONFLICT (version) DO NOTHING;

COMMIT;
