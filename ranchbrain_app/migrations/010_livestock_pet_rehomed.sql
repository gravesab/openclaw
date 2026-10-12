-- DEV-only retirement reasons: pets use rehomed, deceased, or lost.
-- Livestock uses deceased, processed, or sold.
-- Older reason values stay allowed so existing rows still satisfy the check.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 009.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
    cons text;
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

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.animal_identifier_retirements'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%deceased%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'retirement reason check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.animal_identifier_retirements DROP CONSTRAINT %I', cons);
END;
$$;

ALTER TABLE ranchos.animal_identifier_retirements
    ADD CONSTRAINT animal_identifier_retirements_reason_check
    CHECK (reason IN ('replaced', 'lost', 'invalid', 'duplicate', 'deceased', 'rehomed', 'processed', 'sold'));

COMMIT;
