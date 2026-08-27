-- DEV-only mobile work-request intake. Requests are not maintenance schedules.
BEGIN;

ALTER TABLE propertymanager.maintenance_tasks
    ADD COLUMN IF NOT EXISTS intake_state text,
    ADD COLUMN IF NOT EXISTS submitted_by text,
    ADD COLUMN IF NOT EXISTS submitted_at timestamptz,
    ADD COLUMN IF NOT EXISTS triaged_by text,
    ADD COLUMN IF NOT EXISTS triaged_at timestamptz,
    ADD COLUMN IF NOT EXISTS triage_reason text,
    ADD COLUMN IF NOT EXISTS converted_task_id uuid,
    ADD COLUMN IF NOT EXISTS intake_idempotency_key text;

ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_intake_state_check;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_intake_state_check
    CHECK (intake_state IS NULL OR intake_state IN ('submitted', 'triaged', 'converted', 'closed'));
ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_intake_kind_check;
ALTER TABLE propertymanager.maintenance_tasks
    -- Keep legacy Work Request rows readable after upgrade.  NOT VALID still
    -- enforces the invariant for every row created or changed after this point.
    ADD CONSTRAINT maintenance_tasks_intake_kind_check
    CHECK (
        (kind = 'Work Request' AND intake_state IS NOT NULL AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL)
        OR (kind <> 'Work Request' AND intake_state IS NULL)
    ) NOT VALID;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_converted_task_fkey
    FOREIGN KEY (converted_task_id) REFERENCES propertymanager.maintenance_tasks(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS maintenance_tasks_work_request_idempotency_idx
    ON propertymanager.maintenance_tasks (submitted_by, intake_idempotency_key)
    WHERE kind = 'Work Request';
CREATE INDEX IF NOT EXISTS maintenance_tasks_work_request_queue_idx
    ON propertymanager.maintenance_tasks (intake_state, submitted_at DESC)
    WHERE kind = 'Work Request';

ALTER TABLE propertymanager.maintenance_task_parts
    ADD COLUMN IF NOT EXISTS unit text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS provenance text NOT NULL DEFAULT 'maintenance';
ALTER TABLE propertymanager.maintenance_task_parts
    DROP CONSTRAINT IF EXISTS maintenance_task_parts_provenance_check;
ALTER TABLE propertymanager.maintenance_task_parts
    ADD CONSTRAINT maintenance_task_parts_provenance_check
    CHECK (provenance IN ('maintenance', 'request_draft'));

ALTER TABLE propertymanager.maintenance_task_photos
    ADD COLUMN IF NOT EXISTS content_type text,
    ADD COLUMN IF NOT EXISTS byte_size integer,
    ADD COLUMN IF NOT EXISTS sha256 text,
    ADD COLUMN IF NOT EXISTS sanitized_at timestamptz;

CREATE TABLE IF NOT EXISTS propertymanager.maintenance_attachment_operations (
    id uuid PRIMARY KEY,
    created_by text NOT NULL,
    content_type text NOT NULL,
    max_bytes integer NOT NULL,
    state text NOT NULL DEFAULT 'issued',
    storage_path text,
    byte_size integer,
    sha256 text,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    uploaded_at timestamptz,
    allocation_idempotency_key text,
    CONSTRAINT maintenance_attachment_operations_state_check
        CHECK (state IN ('issued', 'uploaded', 'attached', 'expired')),
    CONSTRAINT maintenance_attachment_operations_size_check CHECK (max_bytes > 0)
);
CREATE INDEX IF NOT EXISTS maintenance_attachment_operations_owner_state_idx
    ON propertymanager.maintenance_attachment_operations (created_by, state, expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS maintenance_attachment_operations_allocation_idempotency_idx
    ON propertymanager.maintenance_attachment_operations (created_by, allocation_idempotency_key)
    WHERE allocation_idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS propertymanager.maintenance_task_intake_events (
    id uuid PRIMARY KEY,
    task_id uuid NOT NULL REFERENCES propertymanager.maintenance_tasks(id) ON DELETE CASCADE,
    from_state text,
    to_state text NOT NULL,
    actor text NOT NULL,
    reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT maintenance_task_intake_events_state_check
        CHECK (to_state IN ('submitted', 'triaged', 'converted', 'closed'))
);
CREATE INDEX IF NOT EXISTS maintenance_task_intake_events_task_created_idx
    ON propertymanager.maintenance_task_intake_events (task_id, created_at);

COMMIT;
