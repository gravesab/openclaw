-- DEV-only structured parts extracted from an asset manual.
-- Diagram reference numbers are not assumed to be orderable OEM numbers.
BEGIN;

CREATE TABLE propertymanager.asset_manual_part (
    id uuid PRIMARY KEY,
    manual_version_id uuid NOT NULL REFERENCES propertymanager.asset_manual_version(id) ON DELETE RESTRICT,
    reference_number varchar(64) NOT NULL CHECK (btrim(reference_number) <> ''),
    oem_part_number varchar(255) NOT NULL,
    name varchar(300) NOT NULL CHECK (btrim(name) <> ''),
    quantity integer NOT NULL CHECK (quantity > 0),
    source_page_number integer NOT NULL CHECK (source_page_number > 0),
    source_excerpt varchar(500) NOT NULL CHECK (btrim(source_excerpt) <> ''),
    provenance jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(provenance) = 'object' AND octet_length(provenance::text) <= 4096),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT asset_manual_part_version_reference_key UNIQUE (manual_version_id, reference_number)
);

CREATE INDEX asset_manual_part_version_idx
    ON propertymanager.asset_manual_part (manual_version_id, reference_number);

COMMIT;
