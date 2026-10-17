-- DEV-only pet identifiers, deceased, and feed frequency.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 007.

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
    WHERE conrelid = 'ranchos.animal_identifiers'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%ear_tag%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'animal identifier type check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.animal_identifiers DROP CONSTRAINT %I', cons);

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.animal_identifier_retirements'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%replaced%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'identifier retirement reason check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.animal_identifier_retirements DROP CONSTRAINT %I', cons);

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.livestock_input_consumption'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%mineral%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'feed type check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_input_consumption DROP CONSTRAINT %I', cons);

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.livestock_input_consumption'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%bale%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'feed unit check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_input_consumption DROP CONSTRAINT %I', cons);
END;
$$;

ALTER TABLE ranchos.animal_identifiers
    ADD CONSTRAINT animal_identifiers_identifier_type_check
    CHECK (identifier_type IN ('ear_tag', 'rfid', 'brand', 'registry_number', 'license', 'other'));

ALTER TABLE ranchos.animal_identifier_retirements
    ADD CONSTRAINT animal_identifier_retirements_reason_check
    CHECK (reason IN ('replaced', 'lost', 'invalid', 'duplicate', 'deceased'));

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_input_type_check
    CHECK (input_type IN ('feed', 'hay', 'mineral', 'supplement', 'dry_food', 'wet_food'));

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_unit_code_check
    CHECK (unit_code IN ('lb', 'kg', 'bale', 'bag', 'scoop'));

ALTER TABLE ranchos.livestock_input_consumption
    ADD COLUMN frequency_code text;

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_frequency_check
    CHECK (frequency_code IN ('daily', 'weekly', 'monthly', 'quarterly'));

ALTER TABLE ranchos.livestock_cost_attributions
    ADD COLUMN frequency_code text;

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_frequency_check
    CHECK (frequency_code IS NULL OR frequency_code IN ('daily', 'weekly', 'monthly', 'quarterly'));

COMMIT;
