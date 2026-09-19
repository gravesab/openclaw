-- Date an asset was first placed into service. This is a civil date, not a timestamp.
BEGIN;

ALTER TABLE propertymanager.assets
    ADD COLUMN placed_in_service_date date;

COMMIT;
