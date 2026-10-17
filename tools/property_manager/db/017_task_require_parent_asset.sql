-- Every maintenance task must belong to a parent asset.
-- Orphan rows (NULL asset_id) are removed; the column becomes NOT NULL.
BEGIN;

DELETE FROM propertymanager.maintenance_tasks
WHERE asset_id IS NULL;

ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_asset_id_fkey;

ALTER TABLE propertymanager.maintenance_tasks
    ALTER COLUMN asset_id SET NOT NULL;

ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_asset_id_fkey
        FOREIGN KEY (asset_id)
        REFERENCES propertymanager.assets(id)
        ON DELETE CASCADE;

INSERT INTO propertymanager.schema_migrations (version)
VALUES ('017')
ON CONFLICT (version) DO NOTHING;

COMMIT;
