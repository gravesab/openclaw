-- DEV-only corrections for care, feed, and cost records.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 026.
-- The runtime role keeps INSERT and SELECT only: a correction is a new row that
-- supersedes the earlier row, which stays.

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
    ADD COLUMN supersedes_event_id uuid,
    ADD COLUMN correction_reason text;

ALTER TABLE ranchos.livestock_input_consumption
    ADD COLUMN supersedes_consumption_id uuid,
    ADD COLUMN correction_reason text;

ALTER TABLE ranchos.livestock_cost_attributions
    ADD COLUMN supersedes_cost_id uuid,
    ADD COLUMN correction_reason text;

-- Every new column is NULL on existing rows. NOT VALID skips the validation scan,
-- which row security refuses without a tenant setting; new rows are still checked.
ALTER TABLE ranchos.livestock_care_events
    ADD CONSTRAINT livestock_care_events_supersedes_matches_tenant
    FOREIGN KEY (tenant_id, supersedes_event_id)
    REFERENCES ranchos.livestock_care_events (tenant_id, id) NOT VALID,
    ADD CONSTRAINT livestock_care_events_correction_reason_check
    CHECK (correction_reason IN ('incorrect_time', 'incorrect_value', 'duplicate_entry')),
    ADD CONSTRAINT livestock_care_events_correction_shape
    CHECK ((supersedes_event_id IS NULL) = (correction_reason IS NULL));

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_supersedes_matches_tenant
    FOREIGN KEY (tenant_id, supersedes_consumption_id)
    REFERENCES ranchos.livestock_input_consumption (tenant_id, id) NOT VALID,
    ADD CONSTRAINT livestock_input_consumption_correction_reason_check
    CHECK (correction_reason IN ('incorrect_time', 'incorrect_value', 'duplicate_entry')),
    ADD CONSTRAINT livestock_input_consumption_correction_shape
    CHECK ((supersedes_consumption_id IS NULL) = (correction_reason IS NULL));

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_supersedes_matches_tenant
    FOREIGN KEY (tenant_id, supersedes_cost_id)
    REFERENCES ranchos.livestock_cost_attributions (tenant_id, id) NOT VALID,
    ADD CONSTRAINT livestock_cost_attributions_correction_reason_check
    CHECK (correction_reason IN ('incorrect_value', 'duplicate_entry')),
    ADD CONSTRAINT livestock_cost_attributions_correction_shape
    CHECK ((supersedes_cost_id IS NULL) = (correction_reason IS NULL));

CREATE UNIQUE INDEX livestock_care_events_supersedes_unique
    ON ranchos.livestock_care_events (tenant_id, supersedes_event_id)
    WHERE supersedes_event_id IS NOT NULL;

CREATE UNIQUE INDEX livestock_input_consumption_supersedes_unique
    ON ranchos.livestock_input_consumption (tenant_id, supersedes_consumption_id)
    WHERE supersedes_consumption_id IS NOT NULL;

CREATE UNIQUE INDEX livestock_cost_attributions_supersedes_unique
    ON ranchos.livestock_cost_attributions (tenant_id, supersedes_cost_id)
    WHERE supersedes_cost_id IS NOT NULL;

CREATE FUNCTION ranchos.livestock_record_correction_matches()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'ranchos', 'pg_temp'
AS $function$
DECLARE
    target_animal uuid;
    target_type text;
BEGIN
    IF TG_TABLE_NAME = 'livestock_care_events' THEN
        IF NEW.supersedes_event_id IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT animal_id, event_type INTO target_animal, target_type
        FROM ranchos.livestock_care_events
        WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_event_id;
        IF NOT FOUND OR target_animal <> NEW.animal_id OR target_type <> NEW.event_type THEN
            RAISE EXCEPTION 'care correction must supersede one matching care record'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'livestock_input_consumption' THEN
        IF NEW.supersedes_consumption_id IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT animal_id INTO target_animal
        FROM ranchos.livestock_input_consumption
        WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_consumption_id;
        IF NOT FOUND OR target_animal <> NEW.animal_id THEN
            RAISE EXCEPTION 'feed correction must supersede one feed record for this animal'
                USING ERRCODE = '23514';
        END IF;
    ELSIF TG_TABLE_NAME = 'livestock_cost_attributions' THEN
        IF NEW.supersedes_cost_id IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT animal_id INTO target_animal
        FROM ranchos.livestock_cost_attributions
        WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_cost_id;
        IF NOT FOUND OR target_animal <> NEW.animal_id THEN
            RAISE EXCEPTION 'cost correction must supersede one cost for this animal'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER livestock_care_events_correction_matches
    BEFORE INSERT ON ranchos.livestock_care_events
    FOR EACH ROW EXECUTE FUNCTION ranchos.livestock_record_correction_matches();

CREATE TRIGGER livestock_input_consumption_correction_matches
    BEFORE INSERT ON ranchos.livestock_input_consumption
    FOR EACH ROW EXECUTE FUNCTION ranchos.livestock_record_correction_matches();

CREATE TRIGGER livestock_cost_attributions_correction_matches
    BEFORE INSERT ON ranchos.livestock_cost_attributions
    FOR EACH ROW EXECUTE FUNCTION ranchos.livestock_record_correction_matches();

COMMIT;
