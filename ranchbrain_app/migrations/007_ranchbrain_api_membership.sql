-- Unapplied DEV-only RanchBrain API membership link.
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator after 001.
-- 006 is reserved for livestock confirmation challenges. This migration is 007.

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
    IF to_regclass('ranchos.tenants') IS NULL
       OR to_regclass('ranchos.users') IS NULL
       OR to_regclass('ranchos.tenant_memberships') IS NULL THEN
        RAISE EXCEPTION '001 tenancy foundation is required before this migration';
    END IF;
END;
$$;

CREATE TABLE ranchos.oidc_principal_links (
    issuer text NOT NULL CHECK (issuer <> ''),
    subject text NOT NULL CHECK (subject <> ''),
    user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (issuer, subject)
);

ALTER TABLE ranchos.oidc_principal_links OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.oidc_principal_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.oidc_principal_links FORCE ROW LEVEL SECURITY;

-- Table owner is subject to FORCE RLS, so the SECURITY DEFINER function
-- (running as the migrator) needs an explicit allow. Runtime receives no
-- table privilege. Runtime can only EXECUTE the function below.
CREATE POLICY oidc_principal_links_migrator ON ranchos.oidc_principal_links
    TO ranchos_dev_migrator
    USING (true)
    WITH CHECK (true);

-- 001 forces RLS on the membership tables and the owner is subject to those policies.
-- These role-targeted policies let the SECURITY DEFINER function (migrator)
-- read one row. They do not apply to ranchos_dev_runtime.
CREATE POLICY users_migrator_api ON ranchos.users
    TO ranchos_dev_migrator USING (true) WITH CHECK (true);
CREATE POLICY tenants_migrator_api ON ranchos.tenants
    TO ranchos_dev_migrator USING (true) WITH CHECK (true);
CREATE POLICY memberships_migrator_api ON ranchos.tenant_memberships
    TO ranchos_dev_migrator USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE ranchos.oidc_principal_links FROM PUBLIC;
REVOKE ALL ON TABLE ranchos.oidc_principal_links FROM ranchos_dev_runtime;

CREATE FUNCTION ranchos.resolve_api_membership(
    p_issuer text,
    p_subject text,
    p_tenant_id uuid
) RETURNS TABLE (
    user_id uuid,
    role text,
    user_status text,
    tenant_status text,
    membership_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ranchos, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_revoked timestamptz;
    v_user_status text;
    v_tenant_status text;
    v_role text;
    v_membership_status text;
BEGIN
    SELECT l.user_id, l.revoked_at, u.status
      INTO v_user_id, v_revoked, v_user_status
    FROM oidc_principal_links l
    JOIN users u ON u.id = l.user_id
    WHERE l.issuer = p_issuer AND l.subject = p_subject;

    IF NOT FOUND OR v_revoked IS NOT NULL OR v_user_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'api membership denied' USING ERRCODE = '42501';
    END IF;

    SELECT t.status, m.role, m.status
      INTO v_tenant_status, v_role, v_membership_status
    FROM tenants t
    LEFT JOIN tenant_memberships m
      ON m.tenant_id = t.id AND m.user_id = v_user_id
    WHERE t.id = p_tenant_id;

    IF NOT FOUND
       OR v_tenant_status IS DISTINCT FROM 'active'
       OR v_role IS NULL
       OR v_membership_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'api membership denied' USING ERRCODE = '42501';
    END IF;

    user_id := v_user_id;
    role := v_role;
    user_status := v_user_status;
    tenant_status := v_tenant_status;
    membership_status := v_membership_status;
    RETURN NEXT;
END;
$$;

ALTER FUNCTION ranchos.resolve_api_membership(text, text, uuid) OWNER TO ranchos_dev_migrator;
REVOKE ALL ON FUNCTION ranchos.resolve_api_membership(text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ranchos.resolve_api_membership(text, text, uuid) TO ranchos_dev_runtime;

COMMIT;
