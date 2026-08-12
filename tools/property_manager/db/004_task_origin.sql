-- PropertyManager tasks: manufacturer handbook vs owner-added origin
-- Apply: docker exec -i postgres psql -U openclaw -d openclaw < tools/property_manager/db/004_task_origin.sql

BEGIN;

ALTER TABLE propertymanager.maintenance_tasks
    ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'owner';

UPDATE propertymanager.maintenance_tasks
SET origin = 'manufacturer'
WHERE coalesce(trim(source_manual_name), '') <> ''
  AND origin = 'owner';

ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_origin_check;

ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_origin_check
    CHECK (origin IN ('manufacturer', 'owner'));

COMMIT;
