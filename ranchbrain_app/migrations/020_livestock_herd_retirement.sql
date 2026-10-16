-- DEV-only: a herd can be retired and then left out of the assignment picker.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 019.

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

ALTER TABLE ranchos.livestock_herds
    ADD COLUMN retired_at timestamptz;

GRANT UPDATE (retired_at) ON ranchos.livestock_herds TO ranchos_dev_runtime;

COMMIT;
