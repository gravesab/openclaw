-- DEV-only herd assignment. An animal has one open assignment.
-- A move sets ended_at on the previous row and inserts the new one.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 018.

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

CREATE TABLE ranchos.livestock_herds (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    name text NOT NULL CHECK (name <> '' AND char_length(name) <= 80),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_herds_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE UNIQUE INDEX livestock_herds_name_unique
    ON ranchos.livestock_herds (tenant_id, lower(name));

CREATE TABLE ranchos.livestock_herd_assignments (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    herd_id uuid NOT NULL,
    started_at timestamptz NOT NULL,
    ended_at timestamptz,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_herd_assignments_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT livestock_herd_assignments_herd_matches_tenant
        FOREIGN KEY (tenant_id, herd_id) REFERENCES ranchos.livestock_herds (tenant_id, id),
    CONSTRAINT livestock_herd_assignments_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT livestock_herd_assignments_end_after_start CHECK (
        ended_at IS NULL OR ended_at >= started_at
    )
);

CREATE UNIQUE INDEX livestock_herd_assignments_one_open
    ON ranchos.livestock_herd_assignments (tenant_id, animal_id)
    WHERE ended_at IS NULL;

ALTER TABLE ranchos.livestock_herds ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_herds FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_herd_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_herd_assignments FORCE ROW LEVEL SECURITY;

CREATE POLICY livestock_herds_tenant_isolation ON ranchos.livestock_herds
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_herd_assignments_tenant_isolation ON ranchos.livestock_herd_assignments
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

REVOKE ALL ON ranchos.livestock_herds FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_herd_assignments FROM PUBLIC;
GRANT SELECT, INSERT ON ranchos.livestock_herds TO ranchos_dev_runtime;
GRANT SELECT, INSERT ON ranchos.livestock_herd_assignments TO ranchos_dev_runtime;
GRANT UPDATE (ended_at) ON ranchos.livestock_herd_assignments TO ranchos_dev_runtime;
ALTER TABLE ranchos.livestock_herds OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_herd_assignments OWNER TO ranchos_dev_migrator;

COMMIT;
