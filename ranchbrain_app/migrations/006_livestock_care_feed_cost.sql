-- DEV-only care, feed consumption, and operational cost records.
-- Never apply this file to Production.
-- Apply only on the isolated livestock DEV database as ranchos_dev_migrator after 004.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    IF current_user <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'this DEV migration must run as ranchos_dev_migrator';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
END;
$$;

CREATE TABLE ranchos.livestock_care_events (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    event_type text NOT NULL CHECK (event_type IN (
        'observation', 'treatment', 'surgery', 'vaccination', 'medication_administration'
    )),
    occurred_at timestamptz NOT NULL,
    confirmed_at timestamptz,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_care_events_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT livestock_care_events_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT livestock_care_events_high_impact_confirmed CHECK (
        event_type NOT IN ('surgery', 'vaccination', 'medication_administration')
        OR confirmed_at IS NOT NULL
    )
);

CREATE TABLE ranchos.livestock_input_consumption (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    input_type text NOT NULL CHECK (input_type IN ('feed', 'hay', 'mineral', 'supplement')),
    quantity numeric NOT NULL CHECK (quantity > 0),
    unit_code text NOT NULL CHECK (unit_code IN ('lb', 'kg', 'bale', 'bag')),
    observed_at timestamptz NOT NULL,
    supplier_reference text CHECK (supplier_reference IS NULL OR supplier_reference <> ''),
    batch_reference text CHECK (batch_reference IS NULL OR batch_reference <> ''),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_input_consumption_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT livestock_input_consumption_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE TABLE ranchos.livestock_cost_attributions (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL,
    animal_id uuid NOT NULL,
    amount numeric NOT NULL CHECK (amount > 0),
    currency_code text NOT NULL CHECK (currency_code = 'USD'),
    basis_code text NOT NULL CHECK (basis_code = 'per_animal'),
    finance_reference text CHECK (finance_reference IS NULL OR finance_reference <> ''),
    confirmed_at timestamptz NOT NULL,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT livestock_cost_attributions_animal_matches_tenant
        FOREIGN KEY (tenant_id, animal_id) REFERENCES ranchos.livestock_animals (tenant_id, id),
    CONSTRAINT livestock_cost_attributions_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id) REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

ALTER TABLE ranchos.livestock_care_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_care_events FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_input_consumption ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_input_consumption FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_cost_attributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.livestock_cost_attributions FORCE ROW LEVEL SECURITY;

CREATE POLICY livestock_care_events_tenant_isolation ON ranchos.livestock_care_events
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_input_consumption_tenant_isolation ON ranchos.livestock_input_consumption
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY livestock_cost_attributions_tenant_isolation ON ranchos.livestock_cost_attributions
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

REVOKE ALL ON ranchos.livestock_care_events FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_input_consumption FROM PUBLIC;
REVOKE ALL ON ranchos.livestock_cost_attributions FROM PUBLIC;
GRANT SELECT, INSERT ON ranchos.livestock_care_events, ranchos.livestock_input_consumption,
    ranchos.livestock_cost_attributions TO ranchos_dev_runtime;
ALTER TABLE ranchos.livestock_care_events OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_input_consumption OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.livestock_cost_attributions OWNER TO ranchos_dev_migrator;

COMMIT;
