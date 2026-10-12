-- DEV-only species: dairy cow. Dairy stays a production type.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 014.

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

ALTER TABLE ranchos.livestock_animals
    DROP CONSTRAINT livestock_animals_species_code_check;

ALTER TABLE ranchos.livestock_animals
    ADD CONSTRAINT livestock_animals_species_code_check CHECK (
        species_code IN (
            'chicken', 'goat', 'bison', 'cattle', 'dairy_cow', 'sheep', 'pig', 'horse', 'pet'
        )
    );

ALTER TABLE ranchos.livestock_animals
    DROP CONSTRAINT livestock_animals_production_type_matches_species;

ALTER TABLE ranchos.livestock_animals
    ADD CONSTRAINT livestock_animals_production_type_matches_species CHECK (
        (species_code = 'cattle' AND production_type_code IN ('beef', 'dairy', 'breeding', 'for_sale', 'personal_meat')) OR
        (species_code = 'dairy_cow' AND production_type_code IN ('beef', 'dairy', 'breeding', 'for_sale', 'personal_meat')) OR
        (species_code = 'bison' AND production_type_code IN ('beef', 'breeding', 'for_sale', 'personal_meat')) OR
        (species_code = 'goat' AND production_type_code IN ('beef', 'dairy', 'breeding', 'for_sale', 'personal_meat')) OR
        (species_code = 'sheep' AND production_type_code IN ('breeding', 'companion', 'for_sale', 'personal_meat')) OR
        (species_code = 'chicken' AND production_type_code IN ('layer', 'broiler', 'breeding', 'for_sale', 'personal_meat')) OR
        (species_code = 'pig' AND production_type_code IN ('breeding', 'companion', 'for_sale', 'personal_meat')) OR
        (species_code = 'horse' AND production_type_code IN ('breeding', 'companion', 'for_sale', 'personal_meat')) OR
        (species_code = 'pet' AND production_type_code IN ('companion'))
    );

COMMIT;
