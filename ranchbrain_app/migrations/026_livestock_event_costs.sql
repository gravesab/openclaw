-- DEV-only cost linked to one routine lifecycle event or one care event.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 025.

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
    ADD COLUMN lifecycle_event_id uuid;

ALTER TABLE ranchos.livestock_cost_attributions
    ADD COLUMN care_event_id uuid;

-- Both columns were just added and every existing row is NULL. NOT VALID skips the
-- validation scan, which row security would refuse without a tenant setting; the keys
-- are still enforced for every new or updated row.
ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_lifecycle_event_matches_tenant
    FOREIGN KEY (tenant_id, lifecycle_event_id)
    REFERENCES ranchos.livestock_lifecycle_events (tenant_id, id)
    NOT VALID;

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_care_event_matches_tenant
    FOREIGN KEY (tenant_id, care_event_id)
    REFERENCES ranchos.livestock_care_events (tenant_id, id)
    NOT VALID;

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_one_source_check
    CHECK (
        num_nonnulls(lifecycle_event_id, care_event_id, feed_type) <= 1
    );

COMMIT;
