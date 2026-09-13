-- Unapplied DEV-only Ranch OS tenancy foundation contract.
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator.

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

CREATE SCHEMA IF NOT EXISTS ranchos;

CREATE OR REPLACE FUNCTION ranchos.require_uuid_setting(setting_name text)
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    setting_value text;
BEGIN
    setting_value := current_setting(setting_name, true);
    IF setting_value IS NULL OR setting_value = '' THEN
        RAISE EXCEPTION 'required Ranch OS setting % is missing', setting_name
            USING ERRCODE = '22023';
    END IF;
    RETURN setting_value::uuid;
EXCEPTION
    WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'required Ranch OS setting % is not a UUID', setting_name
            USING ERRCODE = '22023';
END;
$$;

CREATE TABLE ranchos.tenants (
    id uuid PRIMARY KEY,
    slug text NOT NULL UNIQUE,
    display_name text NOT NULL,
    status text NOT NULL CHECK (status IN ('active', 'suspended', 'archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ranchos.users (
    id uuid PRIMARY KEY,
    principal_id uuid NOT NULL UNIQUE,
    status text NOT NULL CHECK (status IN ('active', 'suspended', 'revoked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ranchos.tenant_memberships (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    user_id uuid NOT NULL REFERENCES ranchos.users(id),
    role text NOT NULL CHECK (role IN ('owner', 'manager', 'viewer')),
    status text NOT NULL CHECK (status IN ('active', 'suspended', 'revoked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id)
);

CREATE TABLE ranchos.ranchbrain_memories (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL,
    module text NOT NULL,
    category text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT ranchbrain_memories_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE INDEX tenant_memberships_user_tenant_idx
    ON ranchos.tenant_memberships (user_id, tenant_id);
CREATE INDEX ranchbrain_memories_tenant_created_idx
    ON ranchos.ranchbrain_memories (tenant_id, created_at DESC);

ALTER TABLE ranchos.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.tenants FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.users FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.tenant_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.tenant_memberships FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.ranchbrain_memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.ranchbrain_memories FORCE ROW LEVEL SECURITY;

CREATE POLICY tenants_tenant_isolation ON ranchos.tenants
    USING (id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY users_principal_isolation ON ranchos.users
    USING (principal_id = ranchos.require_uuid_setting('ranchos.principal_id'))
    WITH CHECK (principal_id = ranchos.require_uuid_setting('ranchos.principal_id'));
CREATE POLICY memberships_tenant_isolation ON ranchos.tenant_memberships
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY ranchbrain_memories_tenant_isolation ON ranchos.ranchbrain_memories
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

REVOKE ALL ON SCHEMA ranchos FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA ranchos FROM PUBLIC;
GRANT USAGE ON SCHEMA ranchos TO ranchos_dev_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ranchos.tenants, ranchos.users,
    ranchos.tenant_memberships, ranchos.ranchbrain_memories TO ranchos_dev_runtime;

ALTER TABLE ranchos.tenants OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.users OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.tenant_memberships OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.ranchbrain_memories OWNER TO ranchos_dev_migrator;

DO $$
DECLARE
    table_name text;
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['tenants', 'users', 'tenant_memberships', 'ranchbrain_memories']
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
