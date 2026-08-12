-- Authenticated, human-reviewed queue for model-generated maintenance proposals.
-- This table is intentionally separate from authoritative maintenance_tasks.

BEGIN;

CREATE TABLE IF NOT EXISTS propertymanager.maintenance_proposals (
    id uuid PRIMARY KEY,
    proposal_version integer NOT NULL DEFAULT 1 CHECK (proposal_version > 0),
    operation_id text NOT NULL,
    schema_version text NOT NULL,
    source_evidence_ref text NOT NULL,
    provider text NOT NULL,
    model text NOT NULL,
    model_output jsonb NOT NULL,
    guardrail_actions jsonb NOT NULL DEFAULT '[]'::jsonb,
    validation_status text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    created_by text NOT NULL,
    integration_identity text NOT NULL,
    idempotency_key text NOT NULL,
    reviewed_by text,
    reviewed_at timestamptz,
    rejection_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT maintenance_proposals_validation_status_check
        CHECK (validation_status = 'valid'),
    CONSTRAINT maintenance_proposals_status_check
        CHECK (status IN ('pending', 'confirmed', 'rejected')),
    CONSTRAINT maintenance_proposals_model_output_object_check
        CHECK (jsonb_typeof(model_output) = 'object'),
    CONSTRAINT maintenance_proposals_guardrail_actions_array_check
        CHECK (jsonb_typeof(guardrail_actions) = 'array'),
    CONSTRAINT maintenance_proposals_review_check CHECK (
        (status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL)
        OR
        (status IN ('confirmed', 'rejected') AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS maintenance_proposals_idempotency_idx
    ON propertymanager.maintenance_proposals (integration_identity, idempotency_key);

CREATE INDEX IF NOT EXISTS maintenance_proposals_review_queue_idx
    ON propertymanager.maintenance_proposals (status, created_at DESC);

COMMIT;
