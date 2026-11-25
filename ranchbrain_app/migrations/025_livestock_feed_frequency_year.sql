-- DEV-only semi-annual and annual feed frequencies.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 024.

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
    WHERE conrelid = 'ranchos.livestock_input_consumption'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%quarterly%'
      AND pg_get_constraintdef(oid) NOT ILIKE '%semi_annual%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'consumption frequency check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_input_consumption DROP CONSTRAINT %I', cons);

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.livestock_cost_attributions'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%quarterly%'
      AND pg_get_constraintdef(oid) NOT ILIKE '%semi_annual%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'cost frequency check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_cost_attributions DROP CONSTRAINT %I', cons);
END;
$$;

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_frequency_check
    CHECK (frequency_code IN ('daily', 'weekly', 'monthly', 'quarterly', 'semi_annual', 'annual'));

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_frequency_check
    CHECK (
        frequency_code IS NULL
        OR frequency_code IN ('daily', 'weekly', 'monthly', 'quarterly', 'semi_annual', 'annual')
    );

COMMIT;
