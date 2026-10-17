-- DEV-only animal retirement, so a pet or live stock animal can be retired
-- without an identifier. Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 010.

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

CREATE TABLE ranchos.livestock_animal_retirements (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    reason text NOT NULL CHECK (reason IN (
        'rehomed', 'deceased', 'lost', 'processed', 'sold',
        'replaced', 'invalid', 'duplicate'
    )),
    retired_at timestamptz NOT NULL,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, animal_id),
    CONSTRAINT livestock_animal_retirements_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT livestock_animal_retirements_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

ALTER TABLE ranchos.livestock_animal_retirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_animal_retirements FORCE ROW LEVEL SECURITY;

CREATE POLICY livestock_animal_retirements_tenant_isolation ON ranchos.livestock_animal_retirements
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

REVOKE ALL ON ranchos.livestock_animal_retirements FROM PUBLIC;
GRANT SELECT, INSERT ON ranchos.livestock_animal_retirements TO ranchos_dev_runtime;
ALTER TABLE ranchos.livestock_animal_retirements OWNER TO ranchos_dev_migrator;

COMMIT;
