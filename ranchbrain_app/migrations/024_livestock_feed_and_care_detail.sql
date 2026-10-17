-- DEV-only species feed choices, amount units, and optional shot or medicine detail.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 023.

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
      AND pg_get_constraintdef(oid) ILIKE '%dry_food%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'feed type check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_input_consumption DROP CONSTRAINT %I', cons);

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.livestock_input_consumption'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%scoop%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'feed unit check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_input_consumption DROP CONSTRAINT %I', cons);

    SELECT conname INTO cons
    FROM pg_constraint
    WHERE conrelid = 'ranchos.livestock_cost_attributions'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%dry_food%';
    IF cons IS NULL THEN
        RAISE EXCEPTION 'cost feed type check was not found';
    END IF;
    EXECUTE format('ALTER TABLE ranchos.livestock_cost_attributions DROP CONSTRAINT %I', cons);
END;
$$;

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_input_type_check
    CHECK (input_type IN (
        'feed', 'hay', 'mineral', 'supplement', 'dry_food', 'wet_food',
        'pasture', 'grass_hay', 'alfalfa_hay', 'corn', 'corn_silage', 'oats', 'prepared_meal',
        'browse', 'scratch', 'oyster_shell', 'grit', 'seed', 'pellets', 'insects', 'greens'
    ));

ALTER TABLE ranchos.livestock_input_consumption
    ADD CONSTRAINT livestock_input_consumption_unit_code_check
    CHECK (unit_code IN ('lb', 'kg', 'bale', 'bag', 'scoop', 'cup', 'each'));

ALTER TABLE ranchos.livestock_cost_attributions
    ADD CONSTRAINT livestock_cost_attributions_feed_type_check
    CHECK (
        feed_type IS NULL
        OR feed_type IN (
            'feed', 'hay', 'mineral', 'supplement', 'dry_food', 'wet_food',
            'pasture', 'grass_hay', 'alfalfa_hay', 'corn', 'corn_silage', 'oats', 'prepared_meal',
            'browse', 'scratch', 'oyster_shell', 'grit', 'seed', 'pellets', 'insects', 'greens'
        )
    );

ALTER TABLE ranchos.livestock_care_events
    ADD COLUMN item_name text;

ALTER TABLE ranchos.livestock_care_events
    ADD COLUMN item_kind text;

ALTER TABLE ranchos.livestock_care_events
    ADD CONSTRAINT livestock_care_events_item_name_check
    CHECK (item_name IS NULL OR char_length(item_name) BETWEEN 1 AND 80);

ALTER TABLE ranchos.livestock_care_events
    ADD CONSTRAINT livestock_care_events_item_kind_check
    CHECK (item_kind IS NULL OR char_length(item_kind) BETWEEN 1 AND 80);

COMMIT;
