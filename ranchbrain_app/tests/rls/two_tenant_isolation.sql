-- Run only against a disposable DEV database after 001_ranch_os_tenancy_foundation.sql.
-- The caller must be permitted to SET ROLE ranchos_dev_runtime.
\set ON_ERROR_STOP on
BEGIN;

SET LOCAL ranchos.principal_id = '00000000-0000-0000-0000-000000000001';
SET LOCAL ranchos.environment = 'development';
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000a1';
INSERT INTO ranchos.tenants (id, slug, display_name, status)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'tenant-a', 'Tenant A', 'active');
INSERT INTO ranchos.users (id, principal_id, status)
VALUES ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'active');
INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status)
VALUES ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000011', 'viewer', 'active');
INSERT INTO ranchos.ranchbrain_memories (tenant_id, id, module, category, title, body, created_by_user_id)
VALUES ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000101', 'system', 'test', 'A', 'tenant A memory', '00000000-0000-0000-0000-000000000011');

SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000b2';
INSERT INTO ranchos.tenants (id, slug, display_name, status)
VALUES ('00000000-0000-0000-0000-0000000000b2', 'tenant-b', 'Tenant B', 'active');
INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status)
VALUES ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000011', 'viewer', 'active');
INSERT INTO ranchos.ranchbrain_memories (tenant_id, id, module, category, title, body, created_by_user_id)
VALUES ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000202', 'system', 'test', 'B', 'tenant B memory', '00000000-0000-0000-0000-000000000011');

SET LOCAL ROLE ranchos_dev_runtime;
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000a1';
DO $$
BEGIN
    IF (SELECT count(*) FROM ranchos.ranchbrain_memories) <> 1 THEN
        RAISE EXCEPTION 'Tenant A can see a cross-tenant memory';
    END IF;
    BEGIN
        INSERT INTO ranchos.ranchbrain_memories (tenant_id, id, module, category, title, body, created_by_user_id)
        VALUES ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000203', 'system', 'test', 'blocked', 'blocked', '00000000-0000-0000-0000-000000000011');
        RAISE EXCEPTION 'Tenant A cross-tenant write was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END;
$$;
ROLLBACK;
