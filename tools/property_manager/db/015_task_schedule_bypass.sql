-- Task bypass: skip a task to its next scheduled occurrence or reschedule it
-- without recording a completion. Every schedule change is kept as an event.
BEGIN;

-- Civil date before which meter due flags are held back (date reschedules of
-- meter-scheduled tasks). Cleared by the next skip, hour reschedule, or completion.
ALTER TABLE propertymanager.maintenance_tasks
    ADD COLUMN deferred_until date;

CREATE TABLE propertymanager.maintenance_task_schedule_events (
    id uuid PRIMARY KEY,
    task_id uuid NOT NULL REFERENCES propertymanager.maintenance_tasks(id) ON DELETE CASCADE,
    action text NOT NULL,
    previous_next_due timestamptz,
    new_next_due timestamptz,
    previous_next_due_meter_value numeric(14, 3),
    new_next_due_meter_value numeric(14, 3),
    previous_deferred_until date,
    new_deferred_until date,
    note text,
    operator_identity text,
    integration_identity text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT maintenance_task_schedule_events_action_check
        CHECK (action IN ('skip', 'reschedule')),
    CONSTRAINT maintenance_task_schedule_events_note_length_check
        CHECK (note IS NULL OR char_length(note) <= 2000)
);
CREATE INDEX maintenance_task_schedule_events_task_created_idx
    ON propertymanager.maintenance_task_schedule_events (task_id, created_at DESC);

-- Written last inside the same transaction so the ledger reports 015 only
-- when the migration committed.
INSERT INTO propertymanager.schema_migrations (version)
VALUES ('015')
ON CONFLICT (version) DO NOTHING;

COMMIT;
