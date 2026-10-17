-- DEV-only feed cost linked to the feed record it was saved with.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 027.

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

ALTER TABLE ranchos.livestock_cost_attributions
    ADD COLUMN consumption_id uuid;

-- The column was just added and every existing row is NULL. NOT VALID skips the
-- validation scan, which row security would refuse without a tenant setting; the key
-- is still enforced for every new or updated row.
ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_consumption_matches_tenant
    FOREIGN KEY (tenant_id, consumption_id)
    REFERENCES ranchos.livestock_input_consumption (tenant_id, id)
    NOT VALID;

-- A linked feed cost still names its feed type; older feed costs keep only the type.
ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_consumption_is_feed_check
    CHECK (consumption_id IS NULL OR feed_type IS NOT NULL);

COMMIT;
