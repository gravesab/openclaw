-- DEV-only dosage on vaccination and medication care records.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 031.

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

ALTER TABLE ranchos.livestock_care_events
    ADD COLUMN dosage text;

ALTER TABLE ranchos.livestock_care_events
    ADD CONSTRAINT livestock_care_events_dosage_check
    CHECK (dosage IS NULL OR char_length(dosage) BETWEEN 1 AND 80);

ALTER TABLE ranchos.livestock_care_events
    ADD CONSTRAINT livestock_care_events_dosage_medicine_only
    CHECK (
        dosage IS NULL
        OR event_type IN ('vaccination', 'medication_administration')
    );

COMMIT;
