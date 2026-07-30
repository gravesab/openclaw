-- Store PropertyManager task photographs in PostgreSQL.
-- Metadata and bytes are kept together so every client sees the same durable photo.
BEGIN;

ALTER TABLE propertymanager.maintenance_task_photos
    ADD COLUMN IF NOT EXISTS original_file_name text,
    ADD COLUMN IF NOT EXISTS content_type text,
    ADD COLUMN IF NOT EXISTS byte_size bigint,
    ADD COLUMN IF NOT EXISTS sha256 bytea,
    ADD COLUMN IF NOT EXISTS content bytea;

ALTER TABLE propertymanager.maintenance_task_photos
    DROP CONSTRAINT IF EXISTS maintenance_task_photos_byte_size_check;

ALTER TABLE propertymanager.maintenance_task_photos
    ADD CONSTRAINT maintenance_task_photos_byte_size_check
    CHECK (byte_size IS NULL OR byte_size > 0);

CREATE UNIQUE INDEX IF NOT EXISTS maintenance_task_photos_task_file_name_uidx
    ON propertymanager.maintenance_task_photos (task_id, file_name);

COMMIT;
