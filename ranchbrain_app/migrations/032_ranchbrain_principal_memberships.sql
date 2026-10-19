-- Unapplied DEV-only RanchBrain session membership list.
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator after 007.
-- This migration is 032. It requires 007 and grants the runtime role nothing
-- but EXECUTE on the function below: no table SELECT, INSERT, or policy change.

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
       OR to_regclass('ranchos.tenant_memberships') IS NULL
       OR to_regclass('ranchos.oidc_principal_links') IS NULL THEN
        RAISE EXCEPTION '001 tenancy foundation and 007 api membership link are required before this migration';
    END IF;
    IF to_regprocedure('ranchos.resolve_api_membership(text, text, uuid)') IS NULL THEN
        RAISE EXCEPTION '007 api membership link is required before this migration';
    END IF;
END;
$$;

-- Lists every membership row of the one user bound to (issuer, subject).
-- Unlike resolve_api_membership it takes no tenant id, so the session route
-- can resolve the caller's ranch from membership instead of the header.
-- Denials raise 42501 exactly like resolve_api_membership: missing or
-- revoked link, or a user that is not active, reveals nothing further.
-- Statuses ride along for the caller to evaluate; the function filters
-- nothing by status itself.
CREATE FUNCTION ranchos.list_principal_memberships(
    p_issuer text,
    p_subject text
) RETURNS TABLE (
    user_id uuid,
    tenant_id uuid,
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
BEGIN
    SELECT l.user_id, l.revoked_at, u.status
      INTO v_user_id, v_revoked, v_user_status
    FROM oidc_principal_links l
    JOIN users u ON u.id = l.user_id
    WHERE l.issuer = p_issuer AND l.subject = p_subject;

    IF NOT FOUND OR v_revoked IS NOT NULL OR v_user_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'api membership denied' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT u.id, t.id, m.role, u.status, t.status, m.status
    FROM users u
    JOIN tenant_memberships m ON m.user_id = u.id
    JOIN tenants t ON t.id = m.tenant_id
    WHERE u.id = v_user_id;
END;
$$;

ALTER FUNCTION ranchos.list_principal_memberships(text, text) OWNER TO ranchos_dev_migrator;
REVOKE ALL ON FUNCTION ranchos.list_principal_memberships(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ranchos.list_principal_memberships(text, text) TO ranchos_dev_runtime;

COMMIT;
