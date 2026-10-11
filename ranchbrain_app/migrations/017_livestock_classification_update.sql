-- DEV-only: runtime may change production type and breed on an existing animal.
-- Species is not included in the grant. Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 016.

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

GRANT UPDATE (production_type_code, breed_code)
    ON ranchos.livestock_animals TO ranchos_dev_runtime;

COMMIT;
