-- PropertyManager parts: quantity + vendor/notes on part rows
-- Apply: docker exec -i postgres psql -U openclaw -d openclaw < tools/property_manager/db/003_part_quantity.sql

BEGIN;

ALTER TABLE propertymanager.maintenance_task_parts
    ADD COLUMN IF NOT EXISTS quantity numeric(12, 3) NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS vendor text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS notes text NOT NULL DEFAULT '';

COMMIT;
