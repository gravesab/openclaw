-- Unapplied DEV-only Ranch OS livestock identifier idempotency outcome contract.
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator after 001 and 002.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
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
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'ranchos')
       OR NOT EXISTS (
           SELECT 1
           FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'ranchos' AND p.proname = 'require_uuid_setting'
       ) THEN
        RAISE EXCEPTION '001 tenancy foundation is required before this migration';
    END IF;
    IF to_regclass('ranchos.livestock_animals') IS NULL
       OR to_regclass('ranchos.animal_identifiers') IS NULL
       OR to_regclass('ranchos.animal_identifier_retirements') IS NULL
       OR to_regclass('ranchos.livestock_idempotency') IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM pg_attribute a
           JOIN pg_class c ON c.oid = a.attrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'ranchos'
             AND c.relname = 'livestock_idempotency'
             AND a.attname = 'result_animal_id'
             AND NOT a.attisdropped
       )
       OR NOT EXISTS (
           SELECT 1
           FROM pg_constraint
           WHERE conname = 'livestock_idempotency_reserved_has_no_animal'
             AND conrelid = 'ranchos.livestock_idempotency'::regclass
       ) THEN
        RAISE EXCEPTION '002 livestock foundation is required before this migration';
    END IF;
    SELECT pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity
    INTO table_owner, rls_enabled, rls_forced
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'ranchos' AND c.relkind = 'r' AND c.relname = 'livestock_idempotency';
    IF NOT FOUND OR table_owner <> 'ranchos_dev_migrator' OR NOT rls_enabled OR NOT rls_forced THEN
        RAISE EXCEPTION '002 livestock foundation is required before this migration';
    END IF;
END;
$$;

ALTER TABLE ranchos.livestock_idempotency
    DROP CONSTRAINT livestock_idempotency_reserved_has_no_animal;

ALTER TABLE ranchos.livestock_idempotency
    ADD COLUMN result_identifier_id uuid,
    ADD COLUMN result_retirement_id uuid,
    ADD CONSTRAINT livestock_idempotency_committed_identifier_matches_tenant
        FOREIGN KEY (tenant_id, result_identifier_id)
        REFERENCES ranchos.animal_identifiers (tenant_id, id)
        NOT VALID,
    ADD CONSTRAINT livestock_idempotency_committed_retirement_matches_tenant
        FOREIGN KEY (tenant_id, result_retirement_id)
        REFERENCES ranchos.animal_identifier_retirements (tenant_id, id)
        NOT VALID,
    ADD CONSTRAINT livestock_idempotency_result_matches_operation CHECK (
        (
            outcome = 'reserved'
            AND result_animal_id IS NULL
            AND result_identifier_id IS NULL
            AND result_retirement_id IS NULL
        ) OR (
            outcome = 'committed'
            AND operation = 'ranchos.livestock.animal-create'
            AND result_animal_id IS NOT NULL
            AND result_identifier_id IS NULL
            AND result_retirement_id IS NULL
        ) OR (
            outcome = 'committed'
            AND operation = 'ranchos.livestock.identifier-assign'
            AND result_animal_id IS NULL
            AND result_identifier_id IS NOT NULL
            AND result_retirement_id IS NULL
        ) OR (
            outcome = 'committed'
            AND operation = 'ranchos.livestock.identifier-retire'
            AND result_animal_id IS NULL
            AND result_identifier_id IS NULL
            AND result_retirement_id IS NOT NULL
        )
    ) NOT VALID;

CREATE OR REPLACE FUNCTION ranchos.livestock_idempotency_enforce_finalize_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF OLD.tenant_id IS DISTINCT FROM NEW.tenant_id
       OR OLD.scope IS DISTINCT FROM NEW.scope
       OR OLD.identity IS DISTINCT FROM NEW.identity
       OR OLD.key_digest IS DISTINCT FROM NEW.key_digest
       OR OLD.operation IS DISTINCT FROM NEW.operation
       OR OLD.transaction_id IS DISTINCT FROM NEW.transaction_id THEN
        RAISE EXCEPTION 'idempotency identity is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.outcome = 'committed' THEN
        RAISE EXCEPTION 'committed idempotency is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.outcome <> 'reserved' OR NEW.outcome <> 'committed' THEN
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.operation = 'ranchos.livestock.animal-create' THEN
        IF NEW.result_animal_id IS NULL
           OR NEW.result_identifier_id IS NOT NULL
           OR NEW.result_retirement_id IS NOT NULL THEN
            RAISE EXCEPTION 'idempotency finalize is invalid'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.operation = 'ranchos.livestock.identifier-assign' THEN
        IF NEW.result_identifier_id IS NULL
           OR NEW.result_animal_id IS NOT NULL
           OR NEW.result_retirement_id IS NOT NULL THEN
            RAISE EXCEPTION 'idempotency finalize is invalid'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.operation = 'ranchos.livestock.identifier-retire' THEN
        IF NEW.result_retirement_id IS NULL
           OR NEW.result_animal_id IS NOT NULL
           OR NEW.result_identifier_id IS NOT NULL THEN
            RAISE EXCEPTION 'idempotency finalize is invalid'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON ranchos.livestock_idempotency FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON ranchos.livestock_idempotency TO ranchos_dev_runtime;
ALTER TABLE ranchos.livestock_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_idempotency FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_idempotency OWNER TO ranchos_dev_migrator;

DO $$
DECLARE
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
    identifier_fk boolean;
    retirement_fk boolean;
    result_check boolean;
    dropped_animal_only_check boolean;
BEGIN
    SELECT pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity
    INTO table_owner, rls_enabled, rls_forced
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'ranchos' AND c.relkind = 'r' AND c.relname = 'livestock_idempotency';
    IF NOT FOUND OR table_owner <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'tenant-scoped table livestock_idempotency must be owned by ranchos_dev_migrator';
    END IF;
    IF NOT rls_enabled OR NOT rls_forced THEN
        RAISE EXCEPTION 'tenant-scoped table livestock_idempotency must enable and force RLS';
    END IF;
    SELECT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'livestock_idempotency_committed_identifier_matches_tenant'
          AND conrelid = 'ranchos.livestock_idempotency'::regclass
    ) INTO identifier_fk;
    SELECT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'livestock_idempotency_committed_retirement_matches_tenant'
          AND conrelid = 'ranchos.livestock_idempotency'::regclass
    ) INTO retirement_fk;
    SELECT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'livestock_idempotency_result_matches_operation'
          AND conrelid = 'ranchos.livestock_idempotency'::regclass
    ) INTO result_check;
    SELECT NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'livestock_idempotency_reserved_has_no_animal'
          AND conrelid = 'ranchos.livestock_idempotency'::regclass
    ) INTO dropped_animal_only_check;
    IF NOT identifier_fk OR NOT retirement_fk OR NOT result_check OR NOT dropped_animal_only_check THEN
        RAISE EXCEPTION 'identifier idempotency outcome contract is incomplete';
    END IF;
END;
$$;

COMMIT;
