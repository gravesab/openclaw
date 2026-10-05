-- DEV-only: a herd can store other information entered when it is created.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 020.

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
    ADD COLUMN notes text;

ALTER TABLE ranchos.livestock_herds
    ADD CONSTRAINT livestock_herds_notes_length
    CHECK (notes IS NULL OR char_length(notes) <= 2000);

COMMIT;
