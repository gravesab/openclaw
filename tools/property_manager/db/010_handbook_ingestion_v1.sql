-- PropertyManager Handbook Ingestion v1.1 (DEV only; MCP never applies migrations).
BEGIN;

CREATE TABLE propertymanager.asset_manual (
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

CREATE INDEX asset_manual_asset_id_idx ON propertymanager.asset_manual (asset_id);

CREATE TABLE propertymanager.asset_manual_version (
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

CREATE UNIQUE INDEX asset_manual_version_one_active_idx
    ON propertymanager.asset_manual_version (manual_id) WHERE lifecycle_status = 'active';
CREATE INDEX asset_manual_version_state_idx
    ON propertymanager.asset_manual_version (manual_id, lifecycle_status);
CREATE INDEX asset_manual_version_sha_idx ON propertymanager.asset_manual_version (source_sha256);

CREATE TABLE propertymanager.asset_manual_chunk (
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

CREATE INDEX asset_manual_chunk_version_idx ON propertymanager.asset_manual_chunk (manual_version_id);
CREATE INDEX asset_manual_chunk_search_idx ON propertymanager.asset_manual_chunk USING gin (search_vector);

CREATE TABLE propertymanager.asset_manual_state_event (
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

COMMIT;
