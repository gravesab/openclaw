-- PropertyManager rich task model
-- Non-destructive extension of propertymanager schema for Mac/iPhone clients.
-- Apply: docker exec -i postgres psql -U openclaw -d openclaw < tools/property_manager/db/002_rich_task_model.sql

BEGIN;

ALTER TABLE propertymanager.maintenance_tasks
    ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'Scheduled',
    ADD COLUMN IF NOT EXISTS manufacturer text,
    ADD COLUMN IF NOT EXISTS source_manual_name text,
    ADD COLUMN IF NOT EXISTS completion_history jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS tools_required jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_kind_check;

ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_kind_check
    CHECK (kind IN ('Scheduled', 'Work Request'));

CREATE TABLE IF NOT EXISTS propertymanager.maintenance_task_parts (
    id uuid PRIMARY KEY,
    task_id uuid NOT NULL REFERENCES propertymanager.maintenance_tasks(id) ON DELETE CASCADE,
    name text NOT NULL DEFAULT '',
    oem_part_number text NOT NULL DEFAULT '',
    part_number text NOT NULL DEFAULT '',
    buy_url text NOT NULL DEFAULT '',
    cost numeric(10, 2) NOT NULL DEFAULT 0,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS maintenance_task_parts_task_id_idx
    ON propertymanager.maintenance_task_parts (task_id, sort_order);

CREATE TABLE IF NOT EXISTS propertymanager.maintenance_task_photos (
    id uuid PRIMARY KEY,
    task_id uuid NOT NULL REFERENCES propertymanager.maintenance_tasks(id) ON DELETE CASCADE,
    file_name text NOT NULL,
    storage_path text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS maintenance_task_photos_task_id_idx
    ON propertymanager.maintenance_task_photos (task_id, created_at);

INSERT INTO propertymanager.maintenance_categories
(id, name, icon, color_name, is_built_in, sort_order)
VALUES
('00000000-0000-0000-0000-000000000008', 'Property', 'map.fill', 'brown', true, 80)
ON CONFLICT (name) DO NOTHING;

COMMIT;
