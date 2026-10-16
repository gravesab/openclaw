-- DEV-only: a cost line may be a negative correction. Zero is still rejected.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 017.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
    amount_check text;
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
    SELECT con.conname INTO amount_check
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = 'ranchos'
      AND rel.relname = 'livestock_cost_attributions'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) LIKE '%amount > (0)%';
    IF amount_check IS NULL THEN
        RAISE EXCEPTION 'cost amount check was not found';
    END IF;
    EXECUTE format(
        'ALTER TABLE ranchos.livestock_cost_attributions DROP CONSTRAINT %I',
        amount_check
    );
END;
$$;

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_amount_nonzero
    CHECK (amount <> 0);

COMMIT;
