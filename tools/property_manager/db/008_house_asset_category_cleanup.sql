-- Spa and Pool are House assets/groups, not top-level maintenance categories.
BEGIN;

UPDATE propertymanager.maintenance_tasks
SET category_name = 'House',
    updated_at = now()
WHERE lower(area) IN ('spa', 'pool')
   OR lower(category_name) IN ('spa', 'pool');

DELETE FROM propertymanager.maintenance_categories
WHERE lower(name) IN ('spa', 'pool');

COMMIT;
