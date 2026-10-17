-- DEV-only herd-targeted care and its cost. The record belongs to the herd.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 029.

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
    ALTER COLUMN animal_id DROP NOT NULL;
ALTER TABLE ranchos.livestock_care_events
    ADD COLUMN herd_id uuid;

ALTER TABLE ranchos.livestock_care_events
    ADD CONSTRAINT livestock_care_events_herd_matches_tenant
    FOREIGN KEY (tenant_id, herd_id)
    REFERENCES ranchos.livestock_herds (tenant_id, id)
    NOT VALID,
    ADD CONSTRAINT livestock_care_events_one_target
    CHECK (
        (animal_id IS NOT NULL AND herd_id IS NULL)
        OR (animal_id IS NULL AND herd_id IS NOT NULL)
    );

CREATE OR REPLACE FUNCTION ranchos.livestock_record_correction_matches()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    target_animal uuid;
    target_herd uuid;
    target_type text;
BEGIN
    IF TG_TABLE_NAME = 'livestock_care_events' THEN
        IF NEW.supersedes_event_id IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT animal_id, herd_id, event_type INTO target_animal, target_herd, target_type
        FROM ranchos.livestock_care_events
        WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_event_id;
        IF NOT FOUND
           OR target_animal IS DISTINCT FROM NEW.animal_id
           OR target_herd IS DISTINCT FROM NEW.herd_id
           OR target_type <> NEW.event_type THEN
            RAISE EXCEPTION 'care correction must supersede one matching care record'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'livestock_input_consumption' THEN
        IF NEW.supersedes_consumption_id IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT animal_id, herd_id INTO target_animal, target_herd
        FROM ranchos.livestock_input_consumption
        WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_consumption_id;
        IF NOT FOUND
           OR target_animal IS DISTINCT FROM NEW.animal_id
           OR target_herd IS DISTINCT FROM NEW.herd_id THEN
            RAISE EXCEPTION 'feed correction must supersede one feed record for this animal or herd'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'livestock_cost_attributions' THEN
        IF NEW.supersedes_cost_id IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT animal_id, herd_id INTO target_animal, target_herd
        FROM ranchos.livestock_cost_attributions
        WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_cost_id;
        IF NOT FOUND
           OR target_animal IS DISTINCT FROM NEW.animal_id
           OR target_herd IS DISTINCT FROM NEW.herd_id THEN
            RAISE EXCEPTION 'cost correction must supersede one cost for this animal or herd'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
