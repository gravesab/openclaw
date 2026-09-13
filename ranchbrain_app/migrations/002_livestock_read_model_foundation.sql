-- Unapplied DEV-only Ranch OS livestock persistence foundation contract.
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator after 001.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    IF current_user <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'this DEV migration must run as ranchos_dev_migrator';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ranchos_dev_migrator')
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ranchos_dev_runtime') THEN
        RAISE EXCEPTION 'ranchos_dev_migrator and ranchos_dev_runtime must be provisioned before this migration';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
END;
$$;

CREATE TABLE ranchos.livestock_animals (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL,
    display_name text NOT NULL CHECK (display_name <> ''),
    species_code text NOT NULL CHECK (species_code IN (
        'chicken', 'goat', 'bison', 'cattle', 'sheep', 'pig', 'horse', 'pet'
    )),
    production_type_code text NOT NULL,
    breed_code text,
    status text NOT NULL CHECK (status = 'active'),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_animals_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT livestock_animals_production_type_matches_species CHECK (
        (species_code = 'cattle' AND production_type_code IN ('beef', 'dairy', 'breeding')) OR
        (species_code = 'bison' AND production_type_code IN ('beef', 'breeding')) OR
        (species_code = 'goat' AND production_type_code IN ('beef', 'dairy', 'breeding')) OR
        (species_code = 'sheep' AND production_type_code IN ('breeding', 'companion')) OR
        (species_code = 'chicken' AND production_type_code IN ('layer', 'broiler', 'breeding')) OR
        (species_code = 'pig' AND production_type_code IN ('breeding', 'companion')) OR
        (species_code = 'horse' AND production_type_code IN ('breeding', 'companion')) OR
        (species_code = 'pet' AND production_type_code IN ('companion'))
    ),
    CONSTRAINT livestock_animals_breed_matches_species CHECK (
        breed_code IS NULL OR
        (species_code = 'cattle' AND breed_code IN ('angus', 'hereford')) OR
        (species_code = 'bison' AND breed_code = 'american_bison') OR
        (species_code = 'goat' AND breed_code = 'boer') OR
        (species_code = 'sheep' AND breed_code = 'dorper') OR
        (species_code = 'chicken' AND breed_code = 'rhode_island_red') OR
        (species_code = 'pig' AND breed_code = 'yorkshire') OR
        (species_code = 'horse' AND breed_code = 'quarter_horse')
    ),
    CONSTRAINT livestock_animals_pet_has_no_breed CHECK (
        species_code <> 'pet' OR breed_code IS NULL
    )
);

CREATE TABLE ranchos.animal_identifiers (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    identifier_type text NOT NULL CHECK (identifier_type IN (
        'ear_tag', 'rfid', 'brand', 'registry_number'
    )),
    normalized_value text NOT NULL CHECK (normalized_value <> ''),
    effective_at timestamptz NOT NULL,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT animal_identifiers_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT animal_identifiers_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE TABLE ranchos.animal_identifier_retirements (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    identifier_id uuid NOT NULL,
    reason text NOT NULL CHECK (reason IN ('replaced', 'lost', 'invalid', 'duplicate')),
    retired_at timestamptz NOT NULL,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, identifier_id),
    CONSTRAINT animal_identifier_retirements_identifier_matches_tenant
        FOREIGN KEY (tenant_id, identifier_id) REFERENCES ranchos.animal_identifiers (tenant_id, id),
    CONSTRAINT animal_identifier_retirements_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE TABLE ranchos.livestock_lifecycle_events (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    event_type text NOT NULL CHECK (event_type IN ('intake', 'tagged', 'weight_recorded')),
    occurred_at timestamptz NOT NULL,
    supersedes_event_id uuid,
    correction_reason text CHECK (correction_reason IN (
        'incorrect_time', 'incorrect_value', 'duplicate_entry'
    )),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_lifecycle_events_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT livestock_lifecycle_events_supersedes_matches_tenant
        FOREIGN KEY (tenant_id, supersedes_event_id)
        REFERENCES ranchos.livestock_lifecycle_events (tenant_id, id),
    CONSTRAINT livestock_lifecycle_events_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT livestock_lifecycle_events_correction_shape CHECK (
        (supersedes_event_id IS NULL AND correction_reason IS NULL)
        OR (supersedes_event_id IS NOT NULL AND correction_reason IS NOT NULL)
    )
);

CREATE UNIQUE INDEX livestock_lifecycle_events_supersedes_unique
    ON ranchos.livestock_lifecycle_events (tenant_id, supersedes_event_id)
    WHERE supersedes_event_id IS NOT NULL;

CREATE TABLE ranchos.livestock_idempotency (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    scope text NOT NULL CHECK (scope <> ''),
    key_digest text NOT NULL CHECK (key_digest <> ''),
    operation text NOT NULL CHECK (operation IN (
        'animal_create', 'identifier_assign', 'identifier_retire',
        'lifecycle_record', 'lifecycle_correct'
    )),
    outcome text NOT NULL CHECK (outcome <> ''),
    transaction_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, scope, key_digest)
);

CREATE TABLE ranchos.livestock_confirmations (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL,
    actor_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    principal_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN (
        'animal_create', 'identifier_assign', 'identifier_retire',
        'lifecycle_record', 'lifecycle_correct'
    )),
    target_manifest text NOT NULL CHECK (target_manifest <> ''),
    command_digest text NOT NULL CHECK (command_digest <> ''),
    policy_version text NOT NULL CHECK (policy_version <> ''),
    validator_version text NOT NULL CHECK (validator_version <> ''),
    idempotency_identity text NOT NULL CHECK (idempotency_identity <> ''),
    issued_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_confirmations_actor_matches_tenant
        FOREIGN KEY (tenant_id, actor_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT livestock_confirmations_cf2_ttl CHECK (
        expires_at = issued_at + interval '2 minutes'
    )
);

CREATE TABLE ranchos.livestock_mutation_audit (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL,
    transaction_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN (
        'animal_create', 'identifier_assign', 'identifier_retire',
        'lifecycle_record', 'lifecycle_correct'
    )),
    targets text NOT NULL CHECK (targets <> ''),
    actor_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    principal_id uuid NOT NULL,
    correlation_id text NOT NULL CHECK (correlation_id <> ''),
    policy_version text NOT NULL CHECK (policy_version <> ''),
    validator_version text NOT NULL CHECK (validator_version <> ''),
    idempotency_outcome text NOT NULL CHECK (idempotency_outcome <> ''),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    confirmation_id uuid,
    result_metadata text NOT NULL CHECK (result_metadata <> ''),
    recorded_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_mutation_audit_actor_matches_tenant
        FOREIGN KEY (tenant_id, actor_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE INDEX livestock_animals_tenant_status_idx
    ON ranchos.livestock_animals (tenant_id, status, created_at DESC);
CREATE INDEX animal_identifiers_tenant_animal_idx
    ON ranchos.animal_identifiers (tenant_id, animal_id);
CREATE INDEX livestock_lifecycle_events_tenant_animal_occurred_idx
    ON ranchos.livestock_lifecycle_events (tenant_id, animal_id, occurred_at, id);

CREATE OR REPLACE FUNCTION ranchos.animal_identifiers_reject_active_collision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM ranchos.animal_identifiers assignment
        WHERE assignment.tenant_id = NEW.tenant_id
          AND assignment.identifier_type = NEW.identifier_type
          AND assignment.normalized_value = NEW.normalized_value
          AND assignment.id <> NEW.id
          AND NOT EXISTS (
              SELECT 1
              FROM ranchos.animal_identifier_retirements retirement
              WHERE retirement.tenant_id = assignment.tenant_id
                AND retirement.identifier_id = assignment.id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM ranchos.animal_identifier_retirements retirement
              WHERE retirement.tenant_id = NEW.tenant_id
                AND retirement.identifier_id = NEW.id
          )
    ) THEN
        RAISE EXCEPTION 'active identifier collision'
            USING ERRCODE = '23505';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER animal_identifiers_active_uniqueness
AFTER INSERT OR UPDATE ON ranchos.animal_identifiers
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE PROCEDURE ranchos.animal_identifiers_reject_active_collision();

CREATE OR REPLACE FUNCTION ranchos.animal_identifier_retirements_reject_reactivation_collision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    assignment ranchos.animal_identifiers%ROWTYPE;
BEGIN
    SELECT * INTO assignment
    FROM ranchos.animal_identifiers
    WHERE tenant_id = OLD.tenant_id AND id = OLD.identifier_id;
    IF NOT FOUND THEN
        RETURN OLD;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM ranchos.animal_identifiers other
        WHERE other.tenant_id = assignment.tenant_id
          AND other.identifier_type = assignment.identifier_type
          AND other.normalized_value = assignment.normalized_value
          AND other.id <> assignment.id
          AND NOT EXISTS (
              SELECT 1
              FROM ranchos.animal_identifier_retirements retirement
              WHERE retirement.tenant_id = other.tenant_id
                AND retirement.identifier_id = other.id
          )
    ) THEN
        RAISE EXCEPTION 'active identifier collision'
            USING ERRCODE = '23505';
    END IF;
    RETURN OLD;
END;
$$;

CREATE CONSTRAINT TRIGGER animal_identifier_retirements_reactivation_uniqueness
AFTER DELETE OR UPDATE ON ranchos.animal_identifier_retirements
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE PROCEDURE ranchos.animal_identifier_retirements_reject_reactivation_collision();

CREATE OR REPLACE FUNCTION ranchos.animal_identifier_retirements_reject_before_effective()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    assignment_effective timestamptz;
BEGIN
    SELECT effective_at INTO assignment_effective
    FROM ranchos.animal_identifiers
    WHERE tenant_id = NEW.tenant_id AND id = NEW.identifier_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'identifier retirement requires a tenant-owned assignment'
            USING ERRCODE = '23503';
    END IF;
    IF NEW.retired_at < assignment_effective THEN
        RAISE EXCEPTION 'identifier retirement cannot precede assignment'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER animal_identifier_retirements_before_effective
AFTER INSERT OR UPDATE ON ranchos.animal_identifier_retirements
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE PROCEDURE ranchos.animal_identifier_retirements_reject_before_effective();

CREATE OR REPLACE FUNCTION ranchos.livestock_lifecycle_events_reject_invalid_supersession()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    target ranchos.livestock_lifecycle_events%ROWTYPE;
BEGIN
    IF NEW.supersedes_event_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT * INTO target
    FROM ranchos.livestock_lifecycle_events
    WHERE tenant_id = NEW.tenant_id AND id = NEW.supersedes_event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'lifecycle correction target is missing'
            USING ERRCODE = '23503';
    END IF;
    IF target.animal_id <> NEW.animal_id OR target.event_type <> NEW.event_type THEN
        RAISE EXCEPTION 'lifecycle correction must supersede one matching event'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER livestock_lifecycle_events_same_type_supersession
AFTER INSERT OR UPDATE ON ranchos.livestock_lifecycle_events
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE PROCEDURE ranchos.livestock_lifecycle_events_reject_invalid_supersession();

CREATE OR REPLACE FUNCTION ranchos.livestock_confirmations_enforce_trusted_consume()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'confirmation is already consumed'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.consumed_at IS NOT NULL THEN
        IF CURRENT_TIMESTAMP > NEW.expires_at THEN
            RAISE EXCEPTION 'confirmation is expired'
                USING ERRCODE = '23514';
        END IF;
        NEW.consumed_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER livestock_confirmations_trusted_consume
BEFORE INSERT OR UPDATE ON ranchos.livestock_confirmations
FOR EACH ROW
EXECUTE PROCEDURE ranchos.livestock_confirmations_enforce_trusted_consume();

ALTER TABLE ranchos.livestock_animals ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_animals FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.animal_identifiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.animal_identifiers FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.animal_identifier_retirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.animal_identifier_retirements FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_lifecycle_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_lifecycle_events FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_idempotency FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_confirmations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_confirmations FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_mutation_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_mutation_audit FORCE ROW LEVEL SECURITY;

CREATE POLICY livestock_animals_tenant_isolation ON ranchos.livestock_animals
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY animal_identifiers_tenant_isolation ON ranchos.animal_identifiers
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY animal_identifier_retirements_tenant_isolation ON ranchos.animal_identifier_retirements
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_lifecycle_events_tenant_isolation ON ranchos.livestock_lifecycle_events
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_idempotency_tenant_isolation ON ranchos.livestock_idempotency
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_confirmations_tenant_isolation ON ranchos.livestock_confirmations
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_mutation_audit_tenant_isolation ON ranchos.livestock_mutation_audit
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

REVOKE ALL ON ranchos.livestock_animals FROM PUBLIC;
REVOKE ALL ON ranchos.animal_identifiers FROM PUBLIC;
REVOKE ALL ON ranchos.animal_identifier_retirements FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_lifecycle_events FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_idempotency FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_confirmations FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_mutation_audit FROM PUBLIC;

GRANT SELECT, INSERT ON ranchos.livestock_animals, ranchos.animal_identifiers,
    ranchos.animal_identifier_retirements, ranchos.livestock_lifecycle_events
    TO ranchos_dev_runtime;
GRANT SELECT, INSERT, UPDATE ON ranchos.livestock_idempotency,
    ranchos.livestock_confirmations TO ranchos_dev_runtime;
GRANT INSERT ON ranchos.livestock_mutation_audit TO ranchos_dev_runtime;

ALTER TABLE ranchos.livestock_animals OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.animal_identifiers OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.animal_identifier_retirements OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_lifecycle_events OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_idempotency OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_confirmations OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_mutation_audit OWNER TO ranchos_dev_migrator;

DO $$
DECLARE
    table_name text;
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'livestock_animals',
        'animal_identifiers',
        'animal_identifier_retirements',
        'livestock_lifecycle_events',
        'livestock_idempotency',
        'livestock_confirmations',
        'livestock_mutation_audit'
    ]
    LOOP
        SELECT pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity
        INTO table_owner, rls_enabled, rls_forced
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'ranchos' AND c.relkind = 'r' AND c.relname = table_name;
        IF NOT FOUND OR table_owner <> 'ranchos_dev_migrator' THEN
            RAISE EXCEPTION 'tenant-scoped table % must be owned by ranchos_dev_migrator', table_name;
        END IF;
        IF NOT rls_enabled OR NOT rls_forced THEN
            RAISE EXCEPTION 'tenant-scoped table % must enable and force RLS', table_name;
        END IF;
    END LOOP;
END;
$$;

COMMIT;
