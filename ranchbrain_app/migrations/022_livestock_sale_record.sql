-- DEV-only: a livestock animal retired as sold can store a sale date and amount.
-- Historical sold rows may omit the sale. A new sold retirement records both.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 021.

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

ALTER TABLE ranchos.livestock_animal_retirements
    ADD COLUMN sale_amount numeric,
    ADD COLUMN sale_on date;

ALTER TABLE ranchos.livestock_animal_retirements
    ADD CONSTRAINT livestock_animal_retirements_sale_pair
    CHECK (
        (sale_amount IS NULL AND sale_on IS NULL)
        OR (
            reason = 'sold'
            AND sale_amount IS NOT NULL
            AND sale_on IS NOT NULL
            AND sale_amount >= 0
        )
    );

COMMIT;
