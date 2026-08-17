-- PropertyManager action journal and reversible task completions.
-- Human/device attribution is captured for iPhone, iPad, and macOS clients.

BEGIN;

ALTER TABLE propertymanager.maintenance_completions
    ADD COLUMN IF NOT EXISTS operator_identity text,
    ADD COLUMN IF NOT EXISTS device_install_id text,
    ADD COLUMN IF NOT EXISTS device_label text,
    ADD COLUMN IF NOT EXISTS app_environment text,
    ADD COLUMN IF NOT EXISTS previous_last_done timestamptz,
    ADD COLUMN IF NOT EXISTS previous_next_due timestamptz,
    ADD COLUMN IF NOT EXISTS previous_last_done_meter_value numeric(14, 3),
    ADD COLUMN IF NOT EXISTS previous_next_due_meter_value numeric(14, 3),
    ADD COLUMN IF NOT EXISTS previous_result_notes text,
    ADD COLUMN IF NOT EXISTS acknowledged_at timestamptz,
    ADD COLUMN IF NOT EXISTS acknowledged_by text,
    ADD COLUMN IF NOT EXISTS acknowledged_device_install_id text,
    ADD COLUMN IF NOT EXISTS acknowledged_device_label text,
    ADD COLUMN IF NOT EXISTS acknowledged_app_environment text,
    ADD COLUMN IF NOT EXISTS undone_at timestamptz,
    ADD COLUMN IF NOT EXISTS undone_by text,
    ADD COLUMN IF NOT EXISTS undone_device_install_id text,
    ADD COLUMN IF NOT EXISTS undone_device_label text,
    ADD COLUMN IF NOT EXISTS undone_app_environment text;

ALTER TABLE propertymanager.maintenance_completions
    DROP CONSTRAINT IF EXISTS maintenance_completions_app_environment_check;

ALTER TABLE propertymanager.maintenance_completions
    ADD CONSTRAINT maintenance_completions_app_environment_check
        CHECK (
            app_environment IS NULL
            OR app_environment IN ('development', 'production')
        );

CREATE TABLE IF NOT EXISTS propertymanager.action_journal (
    id uuid PRIMARY KEY,
    action text NOT NULL,
    actor_identity text NOT NULL,
    device_install_id text,
    device_label text,
    app_environment text,
    task_id uuid REFERENCES propertymanager.maintenance_tasks(id) ON DELETE SET NULL,
    completion_id uuid REFERENCES propertymanager.maintenance_completions(id) ON DELETE SET NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    before_state jsonb,
    after_state jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    reversal_of uuid REFERENCES propertymanager.action_journal(id) ON DELETE SET NULL,
    CONSTRAINT action_journal_environment_check
        CHECK (
            app_environment IS NULL
            OR app_environment IN ('development', 'production')
        ),
    CONSTRAINT action_journal_before_state_check
        CHECK (before_state IS NULL OR jsonb_typeof(before_state) = 'object'),
    CONSTRAINT action_journal_after_state_check
        CHECK (after_state IS NULL OR jsonb_typeof(after_state) = 'object'),
    CONSTRAINT action_journal_metadata_check
        CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS action_journal_task_time_idx
    ON propertymanager.action_journal (task_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS action_journal_completion_time_idx
    ON propertymanager.action_journal (completion_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS action_journal_actor_time_idx
    ON propertymanager.action_journal (actor_identity, occurred_at DESC);

COMMIT;
