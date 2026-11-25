-- DEV-only: a Weight recorded event can store the weight in pounds.
-- Older weight events may omit it. A new weight event records it.
-- Intake and Tagged do not store a weight.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 022.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    IF current_user <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'this DEV migration must run as ranchos_dev_migrator';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
END;
$$;

ALTER TABLE ranchos.livestock_lifecycle_events
    ADD COLUMN weight_pounds numeric;

ALTER TABLE ranchos.livestock_lifecycle_events
    ADD CONSTRAINT livestock_lifecycle_events_weight_shape
    CHECK (
        weight_pounds IS NULL
        OR (
            event_type = 'weight_recorded'
            AND weight_pounds > 0
        )
    );

COMMIT;
