-- DEV-only pet species: dog, cat, bird, reptile, or a typed other.
-- species_code stays pet and production stays companion. Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 011.

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
    ADD COLUMN pet_species text,
    ADD COLUMN pet_species_other text;

ALTER TABLE ranchos.livestock_animals
    ADD CONSTRAINT livestock_animals_pet_species_text CHECK (
        (
            species_code <> 'pet'
            AND pet_species IS NULL
            AND pet_species_other IS NULL
        )
        OR (
            species_code = 'pet'
            AND pet_species IS NULL
            AND pet_species_other IS NULL
        )
        OR (
            species_code = 'pet'
            AND pet_species IN ('dog', 'cat', 'bird', 'reptile')
            AND pet_species_other IS NULL
        )
        OR (
            species_code = 'pet'
            AND pet_species = 'other'
            AND pet_species_other IS NOT NULL
            AND pet_species_other <> ''
            AND char_length(pet_species_other) <= 80
        )
    );

COMMIT;
