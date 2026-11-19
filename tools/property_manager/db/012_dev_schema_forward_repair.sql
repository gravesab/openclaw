-- DEV forward repair from the observed snapshot-009 shape to canonical 012.
-- This migration is also safe after the canonical 010/011 chain. Historical
-- migrations remain immutable; operators apply only this file to drifted DEV.
BEGIN;

SELECT pg_advisory_xact_lock(hashtext('propertymanager:012_dev_schema_forward_repair'));

DO $$
DECLARE
    byte_size_type text;
    sha256_type text;
    invalid_sha256 boolean;
BEGIN
    IF to_regclass('propertymanager.maintenance_tasks') IS NULL
       OR to_regclass('propertymanager.maintenance_task_parts') IS NULL
       OR to_regclass('propertymanager.maintenance_task_photos') IS NULL
       OR to_regclass('propertymanager.assets') IS NULL
       OR to_regclass('propertymanager.maintenance_proposals') IS NULL THEN
        RAISE EXCEPTION 'migration 012 requires the complete snapshot-009 PropertyManager base';
    END IF;

    IF (
        SELECT count(*)
        FROM information_schema.tables
        WHERE table_schema = 'propertymanager'
          AND table_name IN (
              'asset_manual', 'asset_manual_version',
              'asset_manual_chunk', 'asset_manual_state_event'
          )
    ) NOT IN (0, 4) THEN
        RAISE EXCEPTION 'migration 012 refuses a partial handbook schema';
    END IF;

    SELECT format_type(a.atttypid, NULL)
    INTO byte_size_type
    FROM pg_attribute a
    WHERE a.attrelid = 'propertymanager.maintenance_task_photos'::regclass
      AND a.attname = 'byte_size'
      AND a.attnum > 0
      AND NOT a.attisdropped;

    SELECT format_type(a.atttypid, NULL)
    INTO sha256_type
    FROM pg_attribute a
    WHERE a.attrelid = 'propertymanager.maintenance_task_photos'::regclass
      AND a.attname = 'sha256'
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF byte_size_type IS NOT NULL AND byte_size_type NOT IN ('integer', 'bigint') THEN
        RAISE EXCEPTION 'migration 012 refuses unsupported photo byte_size type %', byte_size_type;
    END IF;
    IF sha256_type IS NOT NULL AND sha256_type NOT IN ('text', 'bytea') THEN
        RAISE EXCEPTION 'migration 012 refuses unsupported photo sha256 type %', sha256_type;
    END IF;

    IF byte_size_type IS NOT NULL AND EXISTS (
        SELECT 1
        FROM propertymanager.maintenance_task_photos
        WHERE byte_size < 0
           OR (byte_size_type = 'bigint' AND byte_size > 2147483647)
    ) THEN
        RAISE EXCEPTION 'migration 012 refuses photo byte_size outside canonical integer range';
    END IF;

    IF sha256_type = 'bytea' THEN
        EXECUTE
            'SELECT EXISTS (
                SELECT 1 FROM propertymanager.maintenance_task_photos
                WHERE sha256 IS NOT NULL AND octet_length(sha256) <> 32
            )'
        INTO invalid_sha256;
        IF invalid_sha256 THEN
            RAISE EXCEPTION 'migration 012 refuses malformed binary photo sha256';
        END IF;
    ELSIF sha256_type = 'text' THEN
        EXECUTE
            'SELECT EXISTS (
                SELECT 1 FROM propertymanager.maintenance_task_photos
                WHERE sha256 IS NOT NULL AND sha256 !~ ''^[0-9a-f]{64}$''
            )'
        INTO invalid_sha256;
        IF invalid_sha256 THEN
            RAISE EXCEPTION 'migration 012 refuses malformed text photo sha256';
        END IF;
    END IF;
END
$$;

-- Canonical 010 handbook structures, repeated here because the observed DEV
-- database stopped at 009. IF NOT EXISTS keeps the normal 011-to-012 path safe.
CREATE TABLE IF NOT EXISTS propertymanager.asset_manual (
    id uuid PRIMARY KEY,
    asset_id uuid NOT NULL REFERENCES propertymanager.assets(id) ON DELETE RESTRICT,
    document_key varchar(100) NOT NULL CHECK (btrim(document_key) <> ''),
    title varchar(300) NOT NULL CHECK (btrim(title) <> ''),
    document_type varchar(40) NOT NULL
        CHECK (document_type IN ('operator_manual', 'service_manual', 'parts_manual', 'safety_manual', 'other')),
    manufacturer varchar(200),
    model_number varchar(200),
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by varchar(255) NOT NULL CHECK (btrim(created_by) <> ''),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT asset_manual_asset_document_key_key UNIQUE (asset_id, document_key)
);
CREATE INDEX IF NOT EXISTS asset_manual_asset_id_idx
    ON propertymanager.asset_manual (asset_id);

CREATE TABLE IF NOT EXISTS propertymanager.asset_manual_version (
    id uuid PRIMARY KEY,
    manual_id uuid NOT NULL REFERENCES propertymanager.asset_manual(id) ON DELETE RESTRICT,
    version_number integer NOT NULL CHECK (version_number > 0),
    source_kind varchar(16) NOT NULL CHECK (source_kind IN ('pdf', 'url')),
    source_locator varchar(4096) NOT NULL CHECK (btrim(source_locator) <> ''),
    source_display_name varchar(255) NOT NULL CHECK (btrim(source_display_name) <> ''),
    source_sha256 varchar(64) NOT NULL CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
    mime_type varchar(127) NOT NULL CHECK (btrim(mime_type) <> ''),
    source_retrieved_at timestamptz,
    ingestion_status varchar(32) NOT NULL CHECK (ingestion_status IN ('pending', 'processing', 'extracted', 'failed')),
    review_status varchar(32) NOT NULL CHECK (review_status IN ('pending', 'approved', 'rejected')),
    lifecycle_status varchar(32) NOT NULL CHECK (lifecycle_status IN ('draft', 'active', 'superseded', 'removed')),
    supersedes_version_id uuid REFERENCES propertymanager.asset_manual_version(id) ON DELETE RESTRICT,
    extractor_name varchar(100),
    extractor_version varchar(64),
    provenance jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(provenance) = 'object' AND octet_length(provenance::text) <= 65536),
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by varchar(255) NOT NULL CHECK (btrim(created_by) <> ''),
    reviewed_at timestamptz,
    reviewed_by varchar(255),
    activated_at timestamptz,
    activated_by varchar(255),
    superseded_at timestamptz,
    superseded_by varchar(255),
    removed_at timestamptz,
    removed_by varchar(255),
    CONSTRAINT asset_manual_version_manual_version_key UNIQUE (manual_id, version_number),
    CONSTRAINT asset_manual_version_active_requires_approval_check CHECK (
        lifecycle_status <> 'active' OR (
            ingestion_status = 'extracted' AND review_status = 'approved'
            AND reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL AND btrim(reviewed_by) <> ''
            AND activated_at IS NOT NULL AND activated_by IS NOT NULL AND btrim(activated_by) <> ''
        )
    ),
    CONSTRAINT asset_manual_version_review_audit_check CHECK (
        review_status = 'pending' OR (
            reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL AND btrim(reviewed_by) <> ''
        )
    ),
    CONSTRAINT asset_manual_version_superseded_audit_check CHECK (
        lifecycle_status <> 'superseded' OR (
            superseded_at IS NOT NULL AND superseded_by IS NOT NULL AND btrim(superseded_by) <> ''
        )
    ),
    CONSTRAINT asset_manual_version_removed_audit_check CHECK (
        lifecycle_status <> 'removed' OR (
            removed_at IS NOT NULL AND removed_by IS NOT NULL AND btrim(removed_by) <> ''
        )
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS asset_manual_version_one_active_idx
    ON propertymanager.asset_manual_version (manual_id) WHERE lifecycle_status = 'active';
CREATE INDEX IF NOT EXISTS asset_manual_version_state_idx
    ON propertymanager.asset_manual_version (manual_id, lifecycle_status);
CREATE INDEX IF NOT EXISTS asset_manual_version_sha_idx
    ON propertymanager.asset_manual_version (source_sha256);

CREATE TABLE IF NOT EXISTS propertymanager.asset_manual_chunk (
    id uuid PRIMARY KEY,
    manual_version_id uuid NOT NULL REFERENCES propertymanager.asset_manual_version(id) ON DELETE RESTRICT,
    chunk_ordinal integer NOT NULL CHECK (chunk_ordinal >= 0),
    page_number integer CHECK (page_number > 0),
    section_heading varchar(500),
    content varchar(32000) NOT NULL CHECK (btrim(content) <> ''),
    content_sha256 varchar(64) NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    extraction_metadata jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(extraction_metadata) = 'object' AND octet_length(extraction_metadata::text) <= 32768),
    created_at timestamptz NOT NULL DEFAULT now(),
    search_vector tsvector GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(section_heading, '') || ' ' || content)
    ) STORED,
    CONSTRAINT asset_manual_chunk_version_ordinal_key UNIQUE (manual_version_id, chunk_ordinal)
);
CREATE INDEX IF NOT EXISTS asset_manual_chunk_version_idx
    ON propertymanager.asset_manual_chunk (manual_version_id);
CREATE INDEX IF NOT EXISTS asset_manual_chunk_search_idx
    ON propertymanager.asset_manual_chunk USING gin (search_vector);

CREATE TABLE IF NOT EXISTS propertymanager.asset_manual_state_event (
    id uuid PRIMARY KEY,
    manual_version_id uuid NOT NULL REFERENCES propertymanager.asset_manual_version(id) ON DELETE RESTRICT,
    event_type varchar(40) NOT NULL CHECK (event_type IN (
        'ingestion_started', 'ingestion_extracted', 'ingestion_failed', 'review_approved',
        'review_rejected', 'activated', 'superseded', 'removed'
    )),
    from_state jsonb CHECK (
        jsonb_typeof(from_state) = 'object' AND octet_length(from_state::text) <= 4096
    ),
    to_state jsonb NOT NULL CHECK (
        jsonb_typeof(to_state) = 'object' AND octet_length(to_state::text) <= 4096
    ),
    actor_id varchar(255) NOT NULL CHECK (btrim(actor_id) <> ''),
    reason varchar(1000),
    occurred_at timestamptz NOT NULL DEFAULT now()
);

-- Canonical 011 intake structures. Existing legacy Work Request rows are not
-- rewritten: their original values and unknown submitter provenance survive.
ALTER TABLE propertymanager.maintenance_tasks
    ADD COLUMN IF NOT EXISTS intake_state text,
    ADD COLUMN IF NOT EXISTS submitted_by text,
    ADD COLUMN IF NOT EXISTS submitted_at timestamptz,
    ADD COLUMN IF NOT EXISTS triaged_by text,
    ADD COLUMN IF NOT EXISTS triaged_at timestamptz,
    ADD COLUMN IF NOT EXISTS triage_reason text,
    ADD COLUMN IF NOT EXISTS converted_task_id uuid,
    ADD COLUMN IF NOT EXISTS intake_idempotency_key text,
    ALTER COLUMN last_done DROP NOT NULL;

ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_intake_state_check;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_intake_state_check
    CHECK (intake_state IS NULL OR intake_state IN ('submitted', 'triaged', 'converted', 'closed'));
ALTER TABLE propertymanager.maintenance_tasks
    DROP CONSTRAINT IF EXISTS maintenance_tasks_intake_kind_check;
ALTER TABLE propertymanager.maintenance_tasks
    ADD CONSTRAINT maintenance_tasks_intake_kind_check
    CHECK (
        (kind = 'Work Request' AND intake_state IS NOT NULL AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL)
        OR (kind <> 'Work Request' AND intake_state IS NULL)
    ) NOT VALID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'propertymanager.maintenance_tasks'::regclass
          AND conname = 'maintenance_tasks_converted_task_fkey'
    ) THEN
        ALTER TABLE propertymanager.maintenance_tasks
            ADD CONSTRAINT maintenance_tasks_converted_task_fkey
            FOREIGN KEY (converted_task_id)
            REFERENCES propertymanager.maintenance_tasks(id) ON DELETE SET NULL;
    END IF;
END
$$;

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

-- The observed DEV table has legacy inline-photo fields in a different ordinal
-- order than canonical 011. Add every preservation column, then rebuild the
-- table transactionally so both starting shapes converge without losing data.
ALTER TABLE propertymanager.maintenance_task_photos
    ADD COLUMN IF NOT EXISTS original_file_name text,
    ADD COLUMN IF NOT EXISTS content_type text,
    ADD COLUMN IF NOT EXISTS byte_size integer,
    ADD COLUMN IF NOT EXISTS sha256 text,
    ADD COLUMN IF NOT EXISTS content bytea,
    ADD COLUMN IF NOT EXISTS sanitized_at timestamptz;

CREATE TABLE propertymanager.maintenance_task_photos_012_new (
    id uuid NOT NULL,
    task_id uuid NOT NULL,
    file_name text NOT NULL,
    storage_path text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    original_file_name text,
    content_type text,
    byte_size integer,
    sha256 text,
    content bytea,
    sanitized_at timestamptz
);

DO $$
DECLARE
    sha256_type text;
    sha256_expression text;
BEGIN
    SELECT format_type(a.atttypid, NULL)
    INTO sha256_type
    FROM pg_attribute a
    WHERE a.attrelid = 'propertymanager.maintenance_task_photos'::regclass
      AND a.attname = 'sha256'
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF sha256_type = 'bytea' THEN
        sha256_expression :=
            'CASE WHEN sha256 IS NULL THEN NULL ELSE encode(sha256, ''hex'') END';
    ELSIF sha256_type = 'text' THEN
        sha256_expression := 'sha256';
    ELSE
        RAISE EXCEPTION 'migration 012 refuses unsupported photo sha256 type %', sha256_type;
    END IF;

    EXECUTE format(
        $copy$
        INSERT INTO propertymanager.maintenance_task_photos_012_new (
            id, task_id, file_name, storage_path, created_at, original_file_name,
            content_type, byte_size, sha256, content, sanitized_at
        )
        SELECT
            id, task_id, file_name, storage_path, created_at, original_file_name,
            content_type, byte_size::integer, %s, content, sanitized_at
        FROM propertymanager.maintenance_task_photos
        $copy$,
        sha256_expression
    );
END
$$;

DROP TABLE propertymanager.maintenance_task_photos;
ALTER TABLE propertymanager.maintenance_task_photos_012_new
    RENAME TO maintenance_task_photos;
ALTER TABLE propertymanager.maintenance_task_photos
    ADD CONSTRAINT maintenance_task_photos_pkey PRIMARY KEY (id),
    ADD CONSTRAINT maintenance_task_photos_task_id_fkey
        FOREIGN KEY (task_id) REFERENCES propertymanager.maintenance_tasks(id) ON DELETE CASCADE,
    ADD CONSTRAINT maintenance_task_photos_byte_size_check
        CHECK (byte_size IS NULL OR byte_size >= 0);
CREATE INDEX maintenance_task_photos_task_id_idx
    ON propertymanager.maintenance_task_photos (task_id, created_at);
CREATE UNIQUE INDEX maintenance_task_photos_task_file_name_uidx
    ON propertymanager.maintenance_task_photos (task_id, file_name);

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

INSERT INTO propertymanager.maintenance_categories
    (id, name, icon, color_name, is_built_in, sort_order)
VALUES
    ('00000000-0000-0000-0000-000000000008', 'Property', 'map.fill', 'brown', true, 80)
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS propertymanager.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

DO $$
DECLARE
    required_tables integer;
    intake_columns integer;
    canonical_photo_columns integer;
BEGIN
    SELECT count(*) INTO required_tables
    FROM information_schema.tables
    WHERE table_schema = 'propertymanager'
      AND table_name IN (
          'asset_manual', 'asset_manual_version', 'asset_manual_chunk',
          'asset_manual_state_event', 'maintenance_attachment_operations',
          'maintenance_task_intake_events', 'maintenance_task_photos',
          'schema_migrations'
      );

    SELECT count(*) INTO intake_columns
    FROM information_schema.columns
    WHERE table_schema = 'propertymanager'
      AND table_name = 'maintenance_tasks'
      AND column_name IN (
          'intake_state', 'submitted_by', 'submitted_at', 'triaged_by',
          'triaged_at', 'triage_reason', 'converted_task_id',
          'intake_idempotency_key'
      );

    SELECT count(*) INTO canonical_photo_columns
    FROM information_schema.columns
    WHERE table_schema = 'propertymanager'
      AND table_name = 'maintenance_task_photos'
      AND (
          (column_name = 'byte_size' AND data_type = 'integer')
          OR (column_name = 'sha256' AND data_type = 'text')
      );

    IF required_tables <> 8 OR intake_columns <> 8 OR canonical_photo_columns <> 2 THEN
        RAISE EXCEPTION 'migration 012 required-object validation failed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM propertymanager.maintenance_task_photos
        WHERE byte_size < 0
           OR (sha256 IS NOT NULL AND sha256 !~ '^[0-9a-f]{64}$')
    ) THEN
        RAISE EXCEPTION 'migration 012 canonical photo validation failed';
    END IF;
END
$$;

-- Written last inside the same transaction: health may report 012 only when
-- the complete forward repair committed atomically.
INSERT INTO propertymanager.schema_migrations (version)
VALUES ('012')
ON CONFLICT (version) DO NOTHING;

COMMIT;
