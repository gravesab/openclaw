-- DEV-only typed and mixed pet breeds. Catalog breed_code stays null for pets.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 006.

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
    ADD COLUMN pet_breed text,
    ADD COLUMN pet_mix_one text,
    ADD COLUMN pet_mix_two text;

ALTER TABLE ranchos.livestock_animals
    ADD CONSTRAINT livestock_animals_pet_breed_text CHECK (
        (
            species_code <> 'pet'
            AND pet_breed IS NULL
            AND pet_mix_one IS NULL
            AND pet_mix_two IS NULL
        )
        OR (
            species_code = 'pet'
            AND pet_breed IS NULL
            AND pet_mix_one IS NULL
            AND pet_mix_two IS NULL
        )
        OR (
            species_code = 'pet'
            AND pet_breed IS NOT NULL
            AND pet_breed <> ''
            AND pet_breed <> 'mixed'
            AND char_length(pet_breed) <= 80
            AND pet_mix_one IS NULL
            AND pet_mix_two IS NULL
        )
        OR (
            species_code = 'pet'
            AND pet_breed = 'mixed'
            AND pet_mix_one IS NOT NULL
            AND pet_mix_one <> ''
            AND char_length(pet_mix_one) <= 80
            AND pet_mix_two IS NOT NULL
            AND pet_mix_two <> ''
            AND char_length(pet_mix_two) <= 80
        )
    );

COMMIT;
