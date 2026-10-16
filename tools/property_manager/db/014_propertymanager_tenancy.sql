-- PropertyManager tenant ownership + row-level security (DEV ONLY, UNAPPLIED).
-- Never apply this file to Production. It must run only on an isolated
-- disposable DEV database as ranchos_dev_migrator, after ranchos tenancy
-- foundation (001_ranch_os_tenancy_foundation.sql) and PropertyManager
-- migrations 001 through 013. The PropertyManager tables must already be
-- owned by ranchos_dev_migrator (in tests: apply the earlier chain with
-- SET ROLE ranchos_dev_migrator; for any future live apply: transfer
-- ownership explicitly first - this file never takes ownership itself).
--
-- Required transaction settings (plain SET by the operator, not request state):
--   SET app.pm_tenancy_014_apply = 'apply-dev-only';
--   SET app.bootstrap_tenant_id = '<bootstrap ranch uuid>';
-- The bootstrap setting attaches pre-tenancy rows to Andrew's bootstrap ranch
-- only. It fills rows whose tenant_id IS NULL and nothing else, so the
-- backfill block is idempotent. Request handling must never consult it.
--
-- What this migration does, in order:
--   A. Adds nullable tenant_id to every tenant-owned PropertyManager table.
--   B. Backfills pre-tenancy rows to the explicit bootstrap tenant.
--   C. Sets tenant_id NOT NULL, adds tenant FKs and UNIQUE (tenant_id, id).
--   D. Re-scopes global uniqueness to (tenant_id, ...).
--   E. Replaces single-column foreign keys with composite (tenant_id, id) keys.
--   F. Adds per-table tenant_id indexes.
--   G. Enables and forces RLS, adds tenant-isolation policies, grants runtime.
--   H. Verifies owners, RLS, policies, NOT NULL, and the runtime role.
-- The whole file runs in one transaction: any failure rolls everything back.

BEGIN;

-- Guard 1: DEV migrator role only, runtime provisioned without BYPASSRLS.
DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    IF current_user <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'PM tenancy migration 014 must run as ranchos_dev_migrator';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ranchos_dev_migrator')
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ranchos_dev_runtime') THEN
        RAISE EXCEPTION 'ranchos_dev_migrator and ranchos_dev_runtime must be provisioned before migration 014';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
END;
$$;

-- Guard 2: explicit DEV-only apply setting. No default, no silent run.
DO $$
BEGIN
    IF current_setting('app.pm_tenancy_014_apply', true) IS DISTINCT FROM 'apply-dev-only' THEN
        RAISE EXCEPTION 'migration 014 refuses to run without SET app.pm_tenancy_014_apply = ''apply-dev-only''';
    END IF;
END;
$$;

-- Guard 3: shared ranchos tenancy foundation must already exist. This file
-- reuses ranchos.tenants and ranchos.require_uuid_setting; it never forks them.
DO $$
BEGIN
    IF to_regclass('ranchos.tenants') IS NULL THEN
        RAISE EXCEPTION 'migration 014 requires ranchos.tenants (apply the ranchos tenancy foundation first)';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ranchos' AND p.proname = 'require_uuid_setting'
    ) THEN
        RAISE EXCEPTION 'migration 014 requires ranchos.require_uuid_setting';
    END IF;
END;
$$;

-- Guard 4: every tenant-owned table must already be migrator-owned, so the
-- runtime role can never own tenant tables after this migration.
DO $$
DECLARE
    table_name text;
    table_owner text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'maintenance_categories', 'maintenance_tasks', 'maintenance_completions',
        'maintenance_task_parts', 'maintenance_task_photos', 'assets',
        'asset_meter', 'asset_meter_reading', 'asset_task_mapping_proposals',
        'maintenance_proposals', 'asset_manual', 'asset_manual_version',
        'asset_manual_chunk', 'asset_manual_state_event',
        'maintenance_attachment_operations', 'maintenance_task_intake_events',
        'asset_manual_part'
    ]
    LOOP
        SELECT pg_get_userbyid(c.relowner) INTO table_owner
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'propertymanager' AND c.relkind = 'r' AND c.relname = table_name;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'migration 014 requires propertymanager.% (apply migrations 001-013 first)', table_name;
        END IF;
        IF table_owner <> 'ranchos_dev_migrator' THEN
            RAISE EXCEPTION 'propertymanager.% must be owned by ranchos_dev_migrator (transfer ownership explicitly first)', table_name;
        END IF;
    END LOOP;
END;
$$;

-- Phase A: add nullable tenant_id to all 17 tenant-owned tables.
ALTER TABLE propertymanager.maintenance_categories ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_tasks ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_completions ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_task_parts ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_task_photos ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.assets ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_meter ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_meter_reading ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_task_mapping_proposals ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_proposals ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_manual ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_manual_version ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_manual_chunk ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_manual_state_event ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_attachment_operations ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.maintenance_task_intake_events ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE propertymanager.asset_manual_part ADD COLUMN IF NOT EXISTS tenant_id uuid;

-- Phase B: explicit bootstrap attach. Only rows that predate tenancy
-- (tenant_id IS NULL) are filled, so re-running these UPDATEs is a no-op.
--
-- 011 grandfathered legacy Work Request rows behind a NOT VALID check; any
-- UPDATE to such a row re-validates it and fails. Drop that one check for
-- the backfill and re-add it below verbatim (still NOT VALID), so legacy
-- rows stay grandfathered exactly as 011 left them. Any other failure
-- still rolls the whole migration back.
ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_intake_kind_check;
DO $$
DECLARE
    raw text;
    bootstrap uuid;
    leftovers integer;
BEGIN
    raw := current_setting('app.bootstrap_tenant_id', true);
    IF raw IS NULL OR raw = '' THEN
        RAISE EXCEPTION 'migration 014 requires SET app.bootstrap_tenant_id to the bootstrap ranch uuid';
    END IF;
    BEGIN
        bootstrap := raw::uuid;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'app.bootstrap_tenant_id is not a UUID';
    END;
    -- The verification read below runs under forced RLS, so scope this
    -- migration transaction to the bootstrap tenant first. Transaction-local
    -- on purpose: a session-persistent setting would leak the bootstrap
    -- ranch onto whatever runs next on a reused connection.
    PERFORM set_config('ranchos.tenant_id', raw, true);
    IF NOT EXISTS (SELECT 1 FROM ranchos.tenants WHERE id = bootstrap AND status = 'active') THEN
        RAISE EXCEPTION 'app.bootstrap_tenant_id must reference an active ranchos.tenants row';
    END IF;
    UPDATE propertymanager.maintenance_categories SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_tasks SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_completions SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_task_parts SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_task_photos SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.assets SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_meter SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_meter_reading SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_task_mapping_proposals SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_proposals SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_manual SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_manual_version SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_manual_chunk SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_manual_state_event SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_attachment_operations SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.maintenance_task_intake_events SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    UPDATE propertymanager.asset_manual_part SET tenant_id = bootstrap WHERE tenant_id IS NULL;
    SELECT count(*) INTO leftovers FROM (
        SELECT tenant_id FROM propertymanager.maintenance_categories WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_tasks WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_completions WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_task_parts WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_task_photos WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.assets WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_meter WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_meter_reading WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_task_mapping_proposals WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_proposals WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_manual WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_manual_version WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_manual_chunk WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_manual_state_event WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_attachment_operations WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.maintenance_task_intake_events WHERE tenant_id IS NULL
        UNION ALL SELECT tenant_id FROM propertymanager.asset_manual_part WHERE tenant_id IS NULL
    ) still_null;
    IF leftovers <> 0 THEN
        RAISE EXCEPTION 'bootstrap backfill left % rows without tenant_id', leftovers;
    END IF;
END;
$$;

-- Restore 011's intake check verbatim, still NOT VALID: legacy rows stay
-- grandfathered, and every row created or changed after this point is
-- enforced exactly as before.
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_intake_kind_check
    CHECK (
        (kind = 'Work Request' AND intake_state IS NOT NULL AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL)
        OR (kind <> 'Work Request' AND intake_state IS NULL)
    ) NOT VALID;

-- Phase C: tenant_id becomes non-null, references the shared ranchos.tenants
-- table, and anchors UNIQUE (tenant_id, id) on every referenced parent.
ALTER TABLE propertymanager.maintenance_categories ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_tasks ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_completions ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_task_parts ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_task_photos ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.assets ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_meter ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_meter_reading ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_task_mapping_proposals ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_proposals ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_manual ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_manual_version ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_manual_chunk ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_manual_state_event ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_attachment_operations ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.maintenance_task_intake_events ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE propertymanager.asset_manual_part ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE propertymanager.maintenance_categories
    ADD CONSTRAINT maintenance_categories_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_completions
    ADD CONSTRAINT maintenance_completions_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_task_parts
    ADD CONSTRAINT maintenance_task_parts_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_task_photos
    ADD CONSTRAINT maintenance_task_photos_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.assets
    ADD CONSTRAINT assets_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_meter
    ADD CONSTRAINT asset_meter_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_meter_reading
    ADD CONSTRAINT asset_meter_reading_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_task_mapping_proposals
    ADD CONSTRAINT asset_task_mapping_proposals_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_proposals
    ADD CONSTRAINT maintenance_proposals_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_manual
    ADD CONSTRAINT asset_manual_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_manual_version
    ADD CONSTRAINT asset_manual_version_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_manual_chunk
    ADD CONSTRAINT asset_manual_chunk_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_manual_state_event
    ADD CONSTRAINT asset_manual_state_event_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_attachment_operations
    ADD CONSTRAINT maintenance_attachment_operations_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.maintenance_task_intake_events
    ADD CONSTRAINT maintenance_task_intake_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);
ALTER TABLE propertymanager.asset_manual_part
    ADD CONSTRAINT asset_manual_part_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES ranchos.tenants(id);

-- Composite-key targets: the five tables other tenant rows reference.
ALTER TABLE propertymanager.assets
    ADD CONSTRAINT assets_tenant_id_key UNIQUE (tenant_id, id);
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_tenant_id_key UNIQUE (tenant_id, id);
ALTER TABLE propertymanager.asset_meter_reading
    ADD CONSTRAINT asset_meter_reading_tenant_id_key UNIQUE (tenant_id, id);
ALTER TABLE propertymanager.asset_manual
    ADD CONSTRAINT asset_manual_tenant_id_key UNIQUE (tenant_id, id);
ALTER TABLE propertymanager.asset_manual_version
    ADD CONSTRAINT asset_manual_version_tenant_id_key UNIQUE (tenant_id, id);

-- Phase D: human-facing uniqueness becomes tenant-scoped. Global keys go
-- away so two ranches can each own a 'House' category or an asset tag.
ALTER TABLE propertymanager.maintenance_categories
    DROP CONSTRAINT IF EXISTS maintenance_categories_name_key;
ALTER TABLE propertymanager.maintenance_categories
    ADD CONSTRAINT maintenance_categories_tenant_name_key UNIQUE (tenant_id, name);
ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_area_item_unique;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_tenant_area_item_key UNIQUE (tenant_id, area, item);
ALTER TABLE propertymanager.assets
    DROP CONSTRAINT IF EXISTS assets_external_id_key;
ALTER TABLE propertymanager.assets
    ADD CONSTRAINT assets_tenant_external_id_key UNIQUE (tenant_id, external_id);
ALTER TABLE propertymanager.assets
    DROP CONSTRAINT IF EXISTS assets_qr_token_key;
ALTER TABLE propertymanager.assets
    ADD CONSTRAINT assets_tenant_qr_token_key UNIQUE (tenant_id, qr_token);
ALTER TABLE propertymanager.asset_manual
    DROP CONSTRAINT IF EXISTS asset_manual_asset_document_key_key;
ALTER TABLE propertymanager.asset_manual
    ADD CONSTRAINT asset_manual_tenant_asset_document_key UNIQUE (tenant_id, asset_id, document_key);
ALTER TABLE propertymanager.asset_manual_version
    DROP CONSTRAINT IF EXISTS asset_manual_version_manual_version_key;
ALTER TABLE propertymanager.asset_manual_version
    ADD CONSTRAINT asset_manual_version_tenant_manual_version_key UNIQUE (tenant_id, manual_id, version_number);
ALTER TABLE propertymanager.asset_manual_chunk
    DROP CONSTRAINT IF EXISTS asset_manual_chunk_version_ordinal_key;
ALTER TABLE propertymanager.asset_manual_chunk
    ADD CONSTRAINT asset_manual_chunk_tenant_version_ordinal_key UNIQUE (tenant_id, manual_version_id, chunk_ordinal);
ALTER TABLE propertymanager.asset_manual_part
    DROP CONSTRAINT IF EXISTS asset_manual_part_version_reference_key;
ALTER TABLE propertymanager.asset_manual_part
    ADD CONSTRAINT asset_manual_part_tenant_version_reference_key UNIQUE (tenant_id, manual_version_id, reference_number);

-- Idempotency and single-active indexes keep their names and predicates and
-- gain a leading tenant_id.
DROP INDEX IF EXISTS propertymanager.asset_meter_reading_idempotency_idx;
CREATE UNIQUE INDEX asset_meter_reading_idempotency_idx
    ON propertymanager.asset_meter_reading (tenant_id, asset_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL AND status = 'accepted';
DROP INDEX IF EXISTS propertymanager.asset_task_mapping_proposals_task_asset_pending_idx;
CREATE UNIQUE INDEX asset_task_mapping_proposals_task_asset_pending_idx
    ON propertymanager.asset_task_mapping_proposals (tenant_id, ranchbrain_task_ref, proposed_asset_id)
    WHERE status = 'pending';
DROP INDEX IF EXISTS propertymanager.maintenance_proposals_idempotency_idx;
CREATE UNIQUE INDEX maintenance_proposals_idempotency_idx
    ON propertymanager.maintenance_proposals (tenant_id, integration_identity, idempotency_key);
DROP INDEX IF EXISTS propertymanager.maintenance_tasks_work_request_idempotency_idx;
CREATE UNIQUE INDEX maintenance_tasks_work_request_idempotency_idx
    ON propertymanager.maintenance_tasks (tenant_id, submitted_by, intake_idempotency_key)
    WHERE kind = 'Work Request';
DROP INDEX IF EXISTS propertymanager.maintenance_attachment_operations_allocation_idempotency_idx;
CREATE UNIQUE INDEX maintenance_attachment_operations_allocation_idempotency_idx
    ON propertymanager.maintenance_attachment_operations (tenant_id, created_by, allocation_idempotency_key)
    WHERE allocation_idempotency_key IS NOT NULL;
DROP INDEX IF EXISTS propertymanager.asset_manual_version_one_active_idx;
CREATE UNIQUE INDEX asset_manual_version_one_active_idx
    ON propertymanager.asset_manual_version (tenant_id, manual_id) WHERE lifecycle_status = 'active';

-- Phase E: every child foreign key becomes composite (tenant_id, parent_id)
-- so a task, meter, manual, or photo cannot point at another ranch's parent.
-- Original ON DELETE actions are preserved.
ALTER TABLE propertymanager.maintenance_completions
    DROP CONSTRAINT IF EXISTS maintenance_completions_task_id_fkey;
ALTER TABLE propertymanager.maintenance_completions
    ADD CONSTRAINT maintenance_completions_task_id_tenant_fkey
    FOREIGN KEY (tenant_id, task_id) REFERENCES propertymanager.maintenance_tasks (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.maintenance_completions
    DROP CONSTRAINT IF EXISTS maintenance_completions_meter_reading_id_fkey;
ALTER TABLE propertymanager.maintenance_completions
    ADD CONSTRAINT maintenance_completions_meter_reading_id_tenant_fkey
    FOREIGN KEY (tenant_id, meter_reading_id) REFERENCES propertymanager.asset_meter_reading (tenant_id, id) ON DELETE SET NULL;
ALTER TABLE propertymanager.maintenance_task_parts
    DROP CONSTRAINT IF EXISTS maintenance_task_parts_task_id_fkey;
ALTER TABLE propertymanager.maintenance_task_parts
    ADD CONSTRAINT maintenance_task_parts_task_id_tenant_fkey
    FOREIGN KEY (tenant_id, task_id) REFERENCES propertymanager.maintenance_tasks (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.maintenance_task_photos
    DROP CONSTRAINT IF EXISTS maintenance_task_photos_task_id_fkey;
ALTER TABLE propertymanager.maintenance_task_photos
    ADD CONSTRAINT maintenance_task_photos_task_id_tenant_fkey
    FOREIGN KEY (tenant_id, task_id) REFERENCES propertymanager.maintenance_tasks (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.maintenance_task_intake_events
    DROP CONSTRAINT IF EXISTS maintenance_task_intake_events_task_id_fkey;
ALTER TABLE propertymanager.maintenance_task_intake_events
    ADD CONSTRAINT maintenance_task_intake_events_task_id_tenant_fkey
    FOREIGN KEY (tenant_id, task_id) REFERENCES propertymanager.maintenance_tasks (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_asset_id_fkey;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_asset_id_tenant_fkey
    FOREIGN KEY (tenant_id, asset_id) REFERENCES propertymanager.assets (tenant_id, id) ON DELETE SET NULL;
ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_converted_task_fkey;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_converted_task_id_tenant_fkey
    FOREIGN KEY (tenant_id, converted_task_id) REFERENCES propertymanager.maintenance_tasks (tenant_id, id) ON DELETE SET NULL;
ALTER TABLE propertymanager.asset_meter
    DROP CONSTRAINT IF EXISTS asset_meter_asset_id_fkey;
ALTER TABLE propertymanager.asset_meter
    ADD CONSTRAINT asset_meter_asset_id_tenant_fkey
    FOREIGN KEY (tenant_id, asset_id) REFERENCES propertymanager.assets (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.asset_meter_reading
    DROP CONSTRAINT IF EXISTS asset_meter_reading_asset_id_fkey;
ALTER TABLE propertymanager.asset_meter_reading
    ADD CONSTRAINT asset_meter_reading_asset_id_tenant_fkey
    FOREIGN KEY (tenant_id, asset_id) REFERENCES propertymanager.assets (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.asset_meter_reading
    DROP CONSTRAINT IF EXISTS asset_meter_reading_previous_reading_id_fkey;
ALTER TABLE propertymanager.asset_meter_reading
    ADD CONSTRAINT asset_meter_reading_previous_reading_id_tenant_fkey
    FOREIGN KEY (tenant_id, previous_reading_id) REFERENCES propertymanager.asset_meter_reading (tenant_id, id) ON DELETE SET NULL;
ALTER TABLE propertymanager.asset_meter_reading
    DROP CONSTRAINT IF EXISTS asset_meter_reading_corrects_reading_id_fkey;
ALTER TABLE propertymanager.asset_meter_reading
    ADD CONSTRAINT asset_meter_reading_corrects_reading_id_tenant_fkey
    FOREIGN KEY (tenant_id, corrects_reading_id) REFERENCES propertymanager.asset_meter_reading (tenant_id, id) ON DELETE SET NULL;
ALTER TABLE propertymanager.asset_task_mapping_proposals
    DROP CONSTRAINT IF EXISTS asset_task_mapping_proposals_task_id_fkey;
ALTER TABLE propertymanager.asset_task_mapping_proposals
    ADD CONSTRAINT asset_task_mapping_proposals_task_id_tenant_fkey
    FOREIGN KEY (tenant_id, task_id) REFERENCES propertymanager.maintenance_tasks (tenant_id, id) ON DELETE SET NULL;
ALTER TABLE propertymanager.asset_task_mapping_proposals
    DROP CONSTRAINT IF EXISTS asset_task_mapping_proposals_proposed_asset_id_fkey;
ALTER TABLE propertymanager.asset_task_mapping_proposals
    ADD CONSTRAINT asset_task_mapping_proposals_proposed_asset_id_tenant_fkey
    FOREIGN KEY (tenant_id, proposed_asset_id) REFERENCES propertymanager.assets (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE propertymanager.asset_manual
    DROP CONSTRAINT IF EXISTS asset_manual_asset_id_fkey;
ALTER TABLE propertymanager.asset_manual
    ADD CONSTRAINT asset_manual_asset_id_tenant_fkey
    FOREIGN KEY (tenant_id, asset_id) REFERENCES propertymanager.assets (tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE propertymanager.asset_manual_version
    DROP CONSTRAINT IF EXISTS asset_manual_version_manual_id_fkey;
ALTER TABLE propertymanager.asset_manual_version
    ADD CONSTRAINT asset_manual_version_manual_id_tenant_fkey
    FOREIGN KEY (tenant_id, manual_id) REFERENCES propertymanager.asset_manual (tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE propertymanager.asset_manual_version
    DROP CONSTRAINT IF EXISTS asset_manual_version_supersedes_version_id_fkey;
ALTER TABLE propertymanager.asset_manual_version
    ADD CONSTRAINT asset_manual_version_supersedes_version_id_tenant_fkey
    FOREIGN KEY (tenant_id, supersedes_version_id) REFERENCES propertymanager.asset_manual_version (tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE propertymanager.asset_manual_chunk
    DROP CONSTRAINT IF EXISTS asset_manual_chunk_manual_version_id_fkey;
ALTER TABLE propertymanager.asset_manual_chunk
    ADD CONSTRAINT asset_manual_chunk_manual_version_id_tenant_fkey
    FOREIGN KEY (tenant_id, manual_version_id) REFERENCES propertymanager.asset_manual_version (tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE propertymanager.asset_manual_state_event
    DROP CONSTRAINT IF EXISTS asset_manual_state_event_manual_version_id_fkey;
ALTER TABLE propertymanager.asset_manual_state_event
    ADD CONSTRAINT asset_manual_state_event_manual_version_id_tenant_fkey
    FOREIGN KEY (tenant_id, manual_version_id) REFERENCES propertymanager.asset_manual_version (tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE propertymanager.asset_manual_part
    DROP CONSTRAINT IF EXISTS asset_manual_part_manual_version_id_fkey;
ALTER TABLE propertymanager.asset_manual_part
    ADD CONSTRAINT asset_manual_part_manual_version_id_tenant_fkey
    FOREIGN KEY (tenant_id, manual_version_id) REFERENCES propertymanager.asset_manual_version (tenant_id, id) ON DELETE RESTRICT;

-- Phase F: per-table tenant_id indexes for RLS-friendly scans.
CREATE INDEX IF NOT EXISTS maintenance_categories_tenant_id_idx ON propertymanager.maintenance_categories (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_tasks_tenant_id_idx ON propertymanager.maintenance_tasks (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_completions_tenant_id_idx ON propertymanager.maintenance_completions (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_task_parts_tenant_id_idx ON propertymanager.maintenance_task_parts (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_task_photos_tenant_id_idx ON propertymanager.maintenance_task_photos (tenant_id);
CREATE INDEX IF NOT EXISTS assets_tenant_id_idx ON propertymanager.assets (tenant_id);
CREATE INDEX IF NOT EXISTS asset_meter_tenant_id_idx ON propertymanager.asset_meter (tenant_id);
CREATE INDEX IF NOT EXISTS asset_meter_reading_tenant_id_idx ON propertymanager.asset_meter_reading (tenant_id);
CREATE INDEX IF NOT EXISTS asset_task_mapping_proposals_tenant_id_idx ON propertymanager.asset_task_mapping_proposals (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_proposals_tenant_id_idx ON propertymanager.maintenance_proposals (tenant_id);
CREATE INDEX IF NOT EXISTS asset_manual_tenant_id_idx ON propertymanager.asset_manual (tenant_id);
CREATE INDEX IF NOT EXISTS asset_manual_version_tenant_id_idx ON propertymanager.asset_manual_version (tenant_id);
CREATE INDEX IF NOT EXISTS asset_manual_chunk_tenant_id_idx ON propertymanager.asset_manual_chunk (tenant_id);
CREATE INDEX IF NOT EXISTS asset_manual_state_event_tenant_id_idx ON propertymanager.asset_manual_state_event (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_attachment_operations_tenant_id_idx ON propertymanager.maintenance_attachment_operations (tenant_id);
CREATE INDEX IF NOT EXISTS maintenance_task_intake_events_tenant_id_idx ON propertymanager.maintenance_task_intake_events (tenant_id);
CREATE INDEX IF NOT EXISTS asset_manual_part_tenant_id_idx ON propertymanager.asset_manual_part (tenant_id);

-- Phase G: enable and force RLS everywhere, one tenant-isolation policy per
-- table (USING and WITH CHECK against the shared setting reader), and
-- least-privilege grants for the runtime role. Existing grants are left
-- alone so the running single-operator API keeps working until its own slice.
ALTER TABLE propertymanager.maintenance_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_categories FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_tasks FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_completions ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_completions FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_task_parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_task_parts FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_task_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_task_photos FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.assets FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_meter ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_meter FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_meter_reading ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_meter_reading FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_task_mapping_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_task_mapping_proposals FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_proposals FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_version FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_chunk ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_chunk FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_state_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_state_event FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_attachment_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_attachment_operations FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_task_intake_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.maintenance_task_intake_events FORCE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_part ENABLE ROW LEVEL SECURITY;
ALTER TABLE propertymanager.asset_manual_part FORCE ROW LEVEL SECURITY;

CREATE POLICY maintenance_categories_tenant_isolation ON propertymanager.maintenance_categories
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_tasks_tenant_isolation ON propertymanager.maintenance_tasks
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_completions_tenant_isolation ON propertymanager.maintenance_completions
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_task_parts_tenant_isolation ON propertymanager.maintenance_task_parts
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_task_photos_tenant_isolation ON propertymanager.maintenance_task_photos
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY assets_tenant_isolation ON propertymanager.assets
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_meter_tenant_isolation ON propertymanager.asset_meter
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_meter_reading_tenant_isolation ON propertymanager.asset_meter_reading
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_task_mapping_proposals_tenant_isolation ON propertymanager.asset_task_mapping_proposals
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_proposals_tenant_isolation ON propertymanager.maintenance_proposals
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_manual_tenant_isolation ON propertymanager.asset_manual
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_manual_version_tenant_isolation ON propertymanager.asset_manual_version
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_manual_chunk_tenant_isolation ON propertymanager.asset_manual_chunk
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_manual_state_event_tenant_isolation ON propertymanager.asset_manual_state_event
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_attachment_operations_tenant_isolation ON propertymanager.maintenance_attachment_operations
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY maintenance_task_intake_events_tenant_isolation ON propertymanager.maintenance_task_intake_events
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY asset_manual_part_tenant_isolation ON propertymanager.asset_manual_part
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

GRANT USAGE ON SCHEMA propertymanager TO ranchos_dev_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON
    propertymanager.maintenance_categories,
    propertymanager.maintenance_tasks,
    propertymanager.maintenance_completions,
    propertymanager.maintenance_task_parts,
    propertymanager.maintenance_task_photos,
    propertymanager.assets,
    propertymanager.asset_meter,
    propertymanager.asset_meter_reading,
    propertymanager.asset_task_mapping_proposals,
    propertymanager.maintenance_proposals,
    propertymanager.asset_manual,
    propertymanager.asset_manual_version,
    propertymanager.asset_manual_chunk,
    propertymanager.asset_manual_state_event,
    propertymanager.maintenance_attachment_operations,
    propertymanager.maintenance_task_intake_events,
    propertymanager.asset_manual_part
    TO ranchos_dev_runtime;

-- Phase H: verify everything. Any failure rolls the whole migration back.
DO $$
DECLARE
    table_name text;
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
    tenant_nullable boolean;
    policy_count integer;
    runtime_bypasses_rls boolean;
    stale_fk_count integer;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'maintenance_categories', 'maintenance_tasks', 'maintenance_completions',
        'maintenance_task_parts', 'maintenance_task_photos', 'assets',
        'asset_meter', 'asset_meter_reading', 'asset_task_mapping_proposals',
        'maintenance_proposals', 'asset_manual', 'asset_manual_version',
        'asset_manual_chunk', 'asset_manual_state_event',
        'maintenance_attachment_operations', 'maintenance_task_intake_events',
        'asset_manual_part'
    ]
    LOOP
        SELECT pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity
        INTO table_owner, rls_enabled, rls_forced
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'propertymanager' AND c.relkind = 'r' AND c.relname = table_name;
        IF NOT FOUND OR table_owner <> 'ranchos_dev_migrator' THEN
            RAISE EXCEPTION 'tenant-scoped table % must be owned by ranchos_dev_migrator', table_name;
        END IF;
        IF NOT rls_enabled OR NOT rls_forced THEN
            RAISE EXCEPTION 'tenant-scoped table % must enable and force RLS', table_name;
        END IF;
        SELECT a.attnotnull INTO tenant_nullable
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'propertymanager' AND c.relname = table_name AND a.attname = 'tenant_id';
        IF tenant_nullable IS DISTINCT FROM true THEN
            RAISE EXCEPTION '%.tenant_id must be NOT NULL', table_name;
        END IF;
        SELECT count(*) INTO policy_count
        FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'propertymanager' AND c.relname = table_name;
        IF policy_count < 1 THEN
            RAISE EXCEPTION 'tenant-scoped table % must have a tenant-isolation policy', table_name;
        END IF;
    END LOOP;
    -- No single-column child foreign key may survive: every relationship must
    -- carry tenant_id. (tenant_id -> ranchos.tenants single-column keys are
    -- the only allowed exception.)
    SELECT count(*) INTO stale_fk_count
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'propertymanager'
      AND c.contype = 'f'
      AND array_length(c.conkey, 1) = 1
      AND c.conname NOT LIKE '%_tenant_id_fkey';
    IF stale_fk_count <> 0 THEN
        RAISE EXCEPTION '% single-column foreign keys survived tenancy migration 014', stale_fk_count;
    END IF;
    -- The four pre-tenancy global uniqueness constraints must be gone.
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'propertymanager' AND c.conname IN (
            'maintenance_categories_name_key', 'maintenance_tasks_area_item_unique',
            'assets_external_id_key', 'assets_qr_token_key'
        )
    ) THEN
        RAISE EXCEPTION 'global uniqueness constraints survived tenancy migration 014';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
END;
$$;

COMMIT;
