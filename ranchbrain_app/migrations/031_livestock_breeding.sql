-- DEV-only sire, dam, and current mate on livestock animals.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 030.

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
    ADD COLUMN sire_animal_id uuid,
    ADD COLUMN dam_animal_id uuid,
    ADD COLUMN bred_with_animal_id uuid;

ALTER TABLE ranchos.livestock_animals
    ADD CONSTRAINT livestock_animals_sire_matches_tenant
        FOREIGN KEY (tenant_id, sire_animal_id)
        REFERENCES ranchos.livestock_animals (tenant_id, id)
        NOT VALID,
    ADD CONSTRAINT livestock_animals_dam_matches_tenant
        FOREIGN KEY (tenant_id, dam_animal_id)
        REFERENCES ranchos.livestock_animals (tenant_id, id)
        NOT VALID,
    ADD CONSTRAINT livestock_animals_bred_with_matches_tenant
        FOREIGN KEY (tenant_id, bred_with_animal_id)
        REFERENCES ranchos.livestock_animals (tenant_id, id)
        NOT VALID,
    ADD CONSTRAINT livestock_animals_not_own_sire
        CHECK (sire_animal_id IS DISTINCT FROM id),
    ADD CONSTRAINT livestock_animals_not_own_dam
        CHECK (dam_animal_id IS DISTINCT FROM id),
    ADD CONSTRAINT livestock_animals_not_own_mate
        CHECK (bred_with_animal_id IS DISTINCT FROM id),
    ADD CONSTRAINT livestock_animals_sire_differs_from_dam
        CHECK (
            sire_animal_id IS NULL
            OR dam_animal_id IS NULL
            OR sire_animal_id IS DISTINCT FROM dam_animal_id
        ),
    ADD CONSTRAINT livestock_animals_pet_has_no_breeding
        CHECK (
            species_code <> 'pet'
            OR (
                sire_animal_id IS NULL
                AND dam_animal_id IS NULL
                AND bred_with_animal_id IS NULL
            )
        );

CREATE OR REPLACE FUNCTION ranchos.livestock_breeding_same_species()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    relative_species text;
BEGIN
    IF NEW.sire_animal_id IS NOT NULL THEN
        SELECT species_code INTO relative_species
        FROM ranchos.livestock_animals
        WHERE tenant_id = NEW.tenant_id AND id = NEW.sire_animal_id;
        IF relative_species IS DISTINCT FROM NEW.species_code THEN
            RAISE EXCEPTION 'sire must be the same species'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.dam_animal_id IS NOT NULL THEN
        SELECT species_code INTO relative_species
        FROM ranchos.livestock_animals
        WHERE tenant_id = NEW.tenant_id AND id = NEW.dam_animal_id;
        IF relative_species IS DISTINCT FROM NEW.species_code THEN
            RAISE EXCEPTION 'dam must be the same species'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.bred_with_animal_id IS NOT NULL THEN
        SELECT species_code INTO relative_species
        FROM ranchos.livestock_animals
        WHERE tenant_id = NEW.tenant_id AND id = NEW.bred_with_animal_id;
        IF relative_species IS DISTINCT FROM NEW.species_code THEN
            RAISE EXCEPTION 'mate must be the same species'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER livestock_animals_breeding_same_species
    BEFORE INSERT OR UPDATE OF sire_animal_id, dam_animal_id, bred_with_animal_id, species_code
    ON ranchos.livestock_animals
    FOR EACH ROW
    EXECUTE FUNCTION ranchos.livestock_breeding_same_species();

GRANT UPDATE (sire_animal_id, dam_animal_id, bred_with_animal_id)
    ON ranchos.livestock_animals TO ranchos_dev_runtime;

COMMIT;
