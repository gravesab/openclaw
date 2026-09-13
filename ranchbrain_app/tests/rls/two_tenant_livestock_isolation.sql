-- Run only against a disposable DEV database after 001 and 002.
-- Rollback-only. Never apply to Production.
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
INSERT INTO ranchos.livestock_animals (
    tenant_id, id, display_name, species_code, production_type_code, breed_code, status,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000301', 'A animal', 'cattle', 'beef', 'angus', 'active',
     'fixture', 'animal-a', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'),
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000304', 'A pet', 'pet', 'companion', NULL, 'active',
     'fixture', 'animal-a-pet', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011');
INSERT INTO ranchos.animal_identifiers (
    tenant_id, id, animal_id, identifier_type, normalized_value, effective_at,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-000000000301', 'ear_tag', 'a-1', CURRENT_TIMESTAMP,
     'fixture', 'id-a-1', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'),
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000305', '00000000-0000-0000-0000-000000000301', 'rfid', 'a-rfid-1', CURRENT_TIMESTAMP,
     'fixture', 'id-a-2', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011');
INSERT INTO ranchos.animal_identifier_retirements (
    tenant_id, id, identifier_id, reason, retired_at,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000306', '00000000-0000-0000-0000-000000000305', 'replaced', CURRENT_TIMESTAMP,
    'fixture', 'retire-a-1', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.livestock_lifecycle_events (
    tenant_id, id, animal_id, event_type, occurred_at,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-000000000301', 'intake', CURRENT_TIMESTAMP,
    'fixture', 'event-a-1', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.livestock_idempotency (tenant_id, scope, key_digest, operation, outcome, transaction_id)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'livestock', 'digest-a', 'animal_create', 'committed', '00000000-0000-0000-0000-000000000307');
INSERT INTO ranchos.livestock_confirmations (
    tenant_id, id, actor_user_id, principal_id, operation, target_manifest, command_digest,
    policy_version, validator_version, idempotency_identity, issued_at, expires_at
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000308',
    '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001',
    'animal_create', 'animal-a', 'digest-a', 'policy-v1', 'validator-v1', 'digest-a',
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '2 minutes'
);
INSERT INTO ranchos.livestock_mutation_audit (
    tenant_id, id, transaction_id, operation, targets, actor_user_id, principal_id, correlation_id,
    policy_version, validator_version, idempotency_outcome, provenance_source_type, provenance_source_id,
    provenance_source_version, confirmation_id, result_metadata
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000309',
    '00000000-0000-0000-0000-000000000307', 'animal_create', 'animal-a',
    '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'corr-a',
    'policy-v1', 'validator-v1', 'committed', 'fixture', 'animal-a', 'fixture-v1',
    '00000000-0000-0000-0000-000000000308', 'created'
);

SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000b2';
INSERT INTO ranchos.tenants (id, slug, display_name, status)
VALUES ('00000000-0000-0000-0000-0000000000b2', 'tenant-b', 'Tenant B', 'active');
INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status)
VALUES ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000011', 'viewer', 'active');
INSERT INTO ranchos.livestock_animals (
    tenant_id, id, display_name, species_code, production_type_code, breed_code, status,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000401', 'B animal', 'pig', 'breeding', 'yorkshire', 'active',
    'fixture', 'animal-b', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.animal_identifiers (
    tenant_id, id, animal_id, identifier_type, normalized_value, effective_at,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000402', '00000000-0000-0000-0000-000000000401', 'ear_tag', 'b-1', CURRENT_TIMESTAMP,
    'fixture', 'id-b-1', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.livestock_lifecycle_events (
    tenant_id, id, animal_id, event_type, occurred_at,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000403', '00000000-0000-0000-0000-000000000401', 'intake', CURRENT_TIMESTAMP,
    'fixture', 'event-b-1', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.livestock_idempotency (tenant_id, scope, key_digest, operation, outcome, transaction_id)
VALUES ('00000000-0000-0000-0000-0000000000b2', 'livestock', 'digest-b', 'animal_create', 'committed', '00000000-0000-0000-0000-000000000404');
INSERT INTO ranchos.livestock_confirmations (
    tenant_id, id, actor_user_id, principal_id, operation, target_manifest, command_digest,
    policy_version, validator_version, idempotency_identity, issued_at, expires_at
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000405',
    '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001',
    'animal_create', 'animal-b', 'digest-b', 'policy-v1', 'validator-v1', 'digest-b',
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '2 minutes'
);
INSERT INTO ranchos.livestock_mutation_audit (
    tenant_id, id, transaction_id, operation, targets, actor_user_id, principal_id, correlation_id,
    policy_version, validator_version, idempotency_outcome, provenance_source_type, provenance_source_id,
    provenance_source_version, confirmation_id, result_metadata
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000406',
    '00000000-0000-0000-0000-000000000404', 'animal_create', 'animal-b',
    '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'corr-b',
    'policy-v1', 'validator-v1', 'committed', 'fixture', 'animal-b', 'fixture-v1',
    '00000000-0000-0000-0000-000000000405', 'created'
);

SET LOCAL ROLE ranchos_dev_runtime;
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000a1';
DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
    IF (SELECT count(*) FROM ranchos.livestock_animals) <> 2
       OR (SELECT count(*) FROM ranchos.animal_identifiers) <> 2
       OR (SELECT count(*) FROM ranchos.animal_identifier_retirements) <> 1
       OR (SELECT count(*) FROM ranchos.livestock_lifecycle_events) <> 1
       OR (SELECT count(*) FROM ranchos.livestock_idempotency) <> 1
       OR (SELECT count(*) FROM ranchos.livestock_confirmations) <> 1 THEN
        RAISE EXCEPTION 'Tenant A can see cross-tenant livestock facts';
    END IF;
    BEGIN
        PERFORM count(*) FROM ranchos.livestock_mutation_audit;
        RAISE EXCEPTION 'runtime selected livestock mutation audit';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.animal_identifiers (
            tenant_id, id, animal_id, identifier_type, normalized_value, effective_at,
            provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
            created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000407', '00000000-0000-0000-0000-000000000401', 'ear_tag', 'blocked', CURRENT_TIMESTAMP,
            'fixture', 'blocked-assign', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant livestock assign was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.animal_identifier_retirements (
            tenant_id, id, identifier_id, reason, retired_at,
            provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
            created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000408', '00000000-0000-0000-0000-000000000402', 'lost', CURRENT_TIMESTAMP,
            'fixture', 'blocked-retire', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant livestock retire was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.livestock_lifecycle_events (
            tenant_id, id, animal_id, event_type, occurred_at, supersedes_event_id, correction_reason,
            provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
            created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000409', '00000000-0000-0000-0000-000000000401', 'intake', CURRENT_TIMESTAMP,
            '00000000-0000-0000-0000-000000000403', 'incorrect_value',
            'fixture', 'blocked-correct', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant livestock correct was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END;
$$;

SET LOCAL ranchos.tenant_id = '';
DO $$
BEGIN
    PERFORM count(*) FROM ranchos.livestock_animals;
    RAISE EXCEPTION 'missing SET LOCAL ranchos.tenant_id was accepted';
EXCEPTION
    WHEN invalid_parameter_value THEN
        NULL;
END;
$$;

SET LOCAL ranchos.tenant_id = 'not-a-uuid';
DO $$
BEGIN
    PERFORM count(*) FROM ranchos.livestock_animals;
    RAISE EXCEPTION 'malformed SET LOCAL ranchos.tenant_id was accepted';
EXCEPTION
    WHEN invalid_parameter_value THEN
        NULL;
END;
$$;

RESET ROLE;
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000a1';
DO $$
BEGIN
    IF (SELECT count(*) FROM ranchos.livestock_mutation_audit) <> 1 THEN
        RAISE EXCEPTION 'migrator under FORCE RLS can see cross-tenant livestock audit';
    END IF;
END;
$$;
ROLLBACK;
