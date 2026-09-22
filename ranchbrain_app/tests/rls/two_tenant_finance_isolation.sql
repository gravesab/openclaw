-- Run only against a disposable DEV database after 001 and 005.
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
VALUES ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000011', 'owner', 'active');
SET LOCAL ranchos.principal_id = '00000000-0000-0000-0000-000000000003';
INSERT INTO ranchos.users (id, principal_id, status)
VALUES ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000003', 'active');
SET LOCAL ranchos.principal_id = '00000000-0000-0000-0000-000000000001';
INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status)
VALUES ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000013', 'owner', 'active');
INSERT INTO ranchos.finance_accounts (
    tenant_id, id, name, account_type, institution,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'acct-checking-a', 'Checking A', 'asset', 'BancFirst',
     'fixture', 'acct-a', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'),
    ('00000000-0000-0000-0000-0000000000a1', 'acct-groceries-a', 'Groceries A', 'expense', NULL,
     'fixture', 'acct-a-exp', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000013');
INSERT INTO ranchos.finance_source_artifacts (
    tenant_id, id, kind, original_filename, content_digest, media_type, byte_size, parser_version,
    period_start, period_end, account_id,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'artifact-a', 'statement_csv', 'a.csv', 'digest-a', 'text/csv', 12, 'parser-v1',
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'acct-checking-a',
    'fixture', 'artifact-a', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_source_activities (
    tenant_id, id, source_account_id, source_artifact_id, posted_at, description, amount,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'activity-a', 'acct-checking-a', 'artifact-a', CURRENT_TIMESTAMP, 'Groceries', -42.00,
    'fixture', 'activity-a', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
), (
    '00000000-0000-0000-0000-0000000000a1', 'activity-zero', 'acct-checking-a', 'artifact-a', CURRENT_TIMESTAMP, 'Groceries', -42.00,
    'fixture', 'activity-zero', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
), (
    '00000000-0000-0000-0000-0000000000a1', 'activity-ok', 'acct-checking-a', 'artifact-a', CURRENT_TIMESTAMP, 'Groceries', -42.00,
    'fixture', 'activity-ok', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_entries (
    tenant_id, id, recorded_at, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'journal-a', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_lines (
    tenant_id, journal_entry_id, line_no, account_id, debit, credit
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'journal-a', 0, 'acct-groceries-a', 42.00, 0.00),
    ('00000000-0000-0000-0000-0000000000a1', 'journal-a', 1, 'acct-checking-a', 0.00, 42.00);
INSERT INTO ranchos.finance_interpretations (
    tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-a', 'activity-a', 'journal-a', '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_splits (
    tenant_id, interpretation_id, split_no, amount, destination_account_id,
    allocation_domain, allocation_target_type, allocation_target_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-a', 0, -42.00, 'acct-groceries-a',
    'household', 'none', NULL
);
INSERT INTO ranchos.finance_idempotency (
    tenant_id, scope, identity, key_digest, operation, outcome, transaction_id, result_account_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'ranchos.finance.account-create', 'idem-a', 'digest-a',
    'ranchos.finance.account-create', 'committed', '00000000-0000-0000-0000-000000000307',
    'acct-checking-a'
);
INSERT INTO ranchos.finance_mutation_audit (
    tenant_id, id, transaction_id, operation, targets, actor_user_id, principal_id, correlation_id,
    policy_version, validator_version, idempotency_outcome, provenance_source_type, provenance_source_id,
    provenance_source_version, result_metadata
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000309',
    '00000000-0000-0000-0000-000000000307', 'ranchos.finance.account-create', 'acct-checking-a',
    '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'corr-a',
    'policy-v1', 'validator-v1', 'committed', 'fixture', 'acct-a', 'fixture-v1', 'created'
);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

SET LOCAL ranchos.principal_id = '00000000-0000-0000-0000-000000000002';
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000b2';
INSERT INTO ranchos.tenants (id, slug, display_name, status)
VALUES ('00000000-0000-0000-0000-0000000000b2', 'tenant-b', 'Tenant B', 'active');
INSERT INTO ranchos.users (id, principal_id, status)
VALUES ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000002', 'active');
INSERT INTO ranchos.tenant_memberships (tenant_id, user_id, role, status)
VALUES ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000012', 'owner', 'active');
INSERT INTO ranchos.finance_accounts (
    tenant_id, id, name, account_type, institution,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'acct-checking-b', 'Checking B', 'asset', 'BancFirst',
    'fixture', 'acct-b', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000012'
);
INSERT INTO ranchos.finance_source_artifacts (
    tenant_id, id, kind, original_filename, content_digest, media_type, byte_size, parser_version,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'artifact-b', 'receipt', 'b.pdf', 'digest-b', 'application/pdf', 8, 'parser-v1',
    'fixture', 'artifact-b', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000012'
);
INSERT INTO ranchos.finance_source_activities (
    tenant_id, id, source_account_id, posted_at, description, amount,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'activity-b', 'acct-checking-b', CURRENT_TIMESTAMP, 'Feed', -18.00,
    'fixture', 'activity-b', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000012'
);
INSERT INTO ranchos.finance_accounts (
    tenant_id, id, name, account_type, institution,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'acct-feed-b', 'Feed B', 'expense', NULL,
    'fixture', 'acct-b-exp', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000012'
);
INSERT INTO ranchos.finance_journal_entries (
    tenant_id, id, recorded_at, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'journal-b', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000012'
);
INSERT INTO ranchos.finance_journal_lines (
    tenant_id, journal_entry_id, line_no, account_id, debit, credit
) VALUES
    ('00000000-0000-0000-0000-0000000000b2', 'journal-b', 0, 'acct-feed-b', 18.00, 0.00),
    ('00000000-0000-0000-0000-0000000000b2', 'journal-b', 1, 'acct-checking-b', 0.00, 18.00);
INSERT INTO ranchos.finance_interpretations (
    tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'interp-b', 'activity-b', 'journal-b', '00000000-0000-0000-0000-000000000012'
);
INSERT INTO ranchos.finance_splits (
    tenant_id, interpretation_id, split_no, amount, destination_account_id,
    allocation_domain, allocation_target_type, allocation_target_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'interp-b', 0, -18.00, 'acct-feed-b',
    'household', 'none', NULL
);
INSERT INTO ranchos.finance_idempotency (
    tenant_id, scope, identity, key_digest, operation, outcome, transaction_id, result_account_id
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', 'ranchos.finance.account-create', 'idem-b', 'digest-b',
    'ranchos.finance.account-create', 'committed', '00000000-0000-0000-0000-000000000404',
    'acct-checking-b'
);
INSERT INTO ranchos.finance_mutation_audit (
    tenant_id, id, transaction_id, operation, targets, actor_user_id, principal_id, correlation_id,
    policy_version, validator_version, idempotency_outcome, provenance_source_type, provenance_source_id,
    provenance_source_version, result_metadata
) VALUES (
    '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000406',
    '00000000-0000-0000-0000-000000000404', 'ranchos.finance.account-create', 'acct-checking-b',
    '00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000002', 'corr-b',
    'policy-v1', 'validator-v1', 'committed', 'fixture', 'acct-b', 'fixture-v1', 'created'
);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

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
    IF (SELECT count(*) FROM ranchos.finance_accounts) <> 2
       OR (SELECT count(*) FROM ranchos.finance_source_artifacts) <> 1
       OR (SELECT count(*) FROM ranchos.finance_source_activities) <> 3
       OR (SELECT count(*) FROM ranchos.finance_journal_entries) <> 1
       OR (SELECT count(*) FROM ranchos.finance_journal_lines) <> 2
       OR (SELECT count(*) FROM ranchos.finance_interpretations) <> 1
       OR (SELECT count(*) FROM ranchos.finance_splits) <> 1
       OR (SELECT count(*) FROM ranchos.finance_idempotency) <> 1 THEN
        RAISE EXCEPTION 'Tenant A can see cross-tenant finance facts';
    END IF;
    BEGIN
        PERFORM count(*) FROM ranchos.finance_mutation_audit;
        RAISE EXCEPTION 'runtime selected finance mutation audit';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.finance_accounts (
            tenant_id, id, name, account_type,
            provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
            created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', 'acct-blocked', 'Blocked', 'asset',
            'fixture', 'blocked-account', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant finance account write was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.finance_source_activities (
            tenant_id, id, source_account_id, posted_at, description, amount,
            provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
            created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', 'activity-blocked', 'acct-checking-b', CURRENT_TIMESTAMP, 'Blocked', -1.00,
            'fixture', 'blocked-activity', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant finance source write was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.finance_interpretations (
            tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', 'interp-blocked', 'activity-b', 'journal-b',
            '00000000-0000-0000-0000-000000000012'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant finance interpretation write was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.finance_interpretations (
            tenant_id, id, source_activity_id, journal_entry_id, reverses_id, created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', 'interp-reverse-blocked', 'activity-b', 'journal-b',
            'interp-b', '00000000-0000-0000-0000-000000000012'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant finance reverse was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        INSERT INTO ranchos.finance_interpretations (
            tenant_id, id, source_activity_id, journal_entry_id, supersedes_id, created_by_user_id
        ) VALUES (
            '00000000-0000-0000-0000-0000000000b2', 'interp-supersede-blocked', 'activity-b', 'journal-b',
            'interp-b', '00000000-0000-0000-0000-000000000012'
        );
        RAISE EXCEPTION 'Tenant A cross-tenant finance supersede was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        UPDATE ranchos.finance_accounts SET name = 'mutated' WHERE id = 'acct-checking-a';
        RAISE EXCEPTION 'runtime updated a finance domain row';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        DELETE FROM ranchos.finance_accounts WHERE id = 'acct-checking-a';
        RAISE EXCEPTION 'runtime deleted a finance domain row';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END;
$$;

SET LOCAL ranchos.tenant_id = '';
DO $$
BEGIN
    PERFORM count(*) FROM ranchos.finance_accounts;
    RAISE EXCEPTION 'missing SET LOCAL ranchos.tenant_id was accepted';
EXCEPTION
    WHEN invalid_parameter_value THEN
        NULL;
END;
$$;

SET LOCAL ranchos.tenant_id = 'not-a-uuid';
DO $$
BEGIN
    PERFORM count(*) FROM ranchos.finance_accounts;
    RAISE EXCEPTION 'malformed SET LOCAL ranchos.tenant_id was accepted';
EXCEPTION
    WHEN invalid_parameter_value THEN
        NULL;
END;
$$;

RESET ROLE;
SET LOCAL ranchos.principal_id = '00000000-0000-0000-0000-000000000001';
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000a1';
DO $$
BEGIN
    INSERT INTO ranchos.finance_journal_entries (
        tenant_id, id, recorded_at, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-zero', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_interpretations (
        tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-zero', 'activity-zero', 'journal-zero',
        '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_splits (
        tenant_id, interpretation_id, split_no, amount, destination_account_id,
        allocation_domain, allocation_target_type, allocation_target_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-zero', 0, -42.00, 'acct-groceries-a',
        'household', 'none', NULL
    );
    SET CONSTRAINTS ranchos.finance_interpretations_journal_complete IMMEDIATE;
    RAISE EXCEPTION 'zero-line journal interpretation was accepted';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END;
$$;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    INSERT INTO ranchos.finance_journal_entries (
        tenant_id, id, recorded_at, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-one', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_journal_lines (
        tenant_id, journal_entry_id, line_no, account_id, debit, credit
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-one', 0, 'acct-groceries-a', 42.00, 0.00
    );
    INSERT INTO ranchos.finance_interpretations (
        tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-one', 'activity-zero', 'journal-one',
        '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_splits (
        tenant_id, interpretation_id, split_no, amount, destination_account_id,
        allocation_domain, allocation_target_type, allocation_target_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-one', 0, -42.00, 'acct-groceries-a',
        'household', 'none', NULL
    );
    SET CONSTRAINTS ranchos.finance_interpretations_journal_complete IMMEDIATE;
    RAISE EXCEPTION 'one-line journal interpretation was accepted';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END;
$$;
SET CONSTRAINTS ALL DEFERRED;

INSERT INTO ranchos.finance_journal_entries (
    tenant_id, id, recorded_at, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'journal-ok', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_lines (
    tenant_id, journal_entry_id, line_no, account_id, debit, credit
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'journal-ok', 0, 'acct-groceries-a', 42.00, 0.00),
    ('00000000-0000-0000-0000-0000000000a1', 'journal-ok', 1, 'acct-checking-a', 0.00, 42.00);
INSERT INTO ranchos.finance_interpretations (
    tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-ok', 'activity-ok', 'journal-ok',
    '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_splits (
    tenant_id, interpretation_id, split_no, amount, destination_account_id,
    allocation_domain, allocation_target_type, allocation_target_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-ok', 0, -42.00, 'acct-groceries-a',
    'household', 'none', NULL
);
SET CONSTRAINTS ranchos.finance_interpretations_journal_complete,
                ranchos.finance_interpretations_split_presence,
                ranchos.finance_interpretations_split_derived,
                ranchos.finance_journal_lines_balanced IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    INSERT INTO ranchos.finance_journal_entries (
        tenant_id, id, recorded_at, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-unrep', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_journal_lines (
        tenant_id, journal_entry_id, line_no, account_id, debit, credit
    ) VALUES
        ('00000000-0000-0000-0000-0000000000a1', 'journal-unrep', 0, 'acct-checking-a', 42.00, 0.00),
        ('00000000-0000-0000-0000-0000000000a1', 'journal-unrep', 1, 'acct-groceries-a', 0.00, 42.00);
    INSERT INTO ranchos.finance_interpretations (
        tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-unrep', 'activity-zero', 'journal-unrep',
        '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_splits (
        tenant_id, interpretation_id, split_no, amount, destination_account_id,
        allocation_domain, allocation_target_type, allocation_target_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-unrep', 0, -42.00, 'acct-groceries-a',
        'household', 'none', NULL
    );
    SET CONSTRAINTS ranchos.finance_interpretations_split_derived IMMEDIATE;
    RAISE EXCEPTION 'unrepresentative journal interpretation was accepted';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END;
$$;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    INSERT INTO ranchos.finance_journal_entries (
        tenant_id, id, recorded_at, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-unbound', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_journal_lines (
        tenant_id, journal_entry_id, line_no, account_id, debit, credit
    ) VALUES
        ('00000000-0000-0000-0000-0000000000a1', 'journal-unbound', 0, 'acct-checking-a', 42.00, 0.00),
        ('00000000-0000-0000-0000-0000000000a1', 'journal-unbound', 1, 'acct-groceries-a', 0.00, 42.00);
    INSERT INTO ranchos.finance_interpretations (
        tenant_id, id, source_activity_id, journal_entry_id, reverses_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-unbound', 'activity-ok', 'journal-unbound',
        'interp-ok', '00000000-0000-0000-0000-000000000011'
    );
    SET CONSTRAINTS ranchos.finance_interpretations_reversal_bound IMMEDIATE;
    RAISE EXCEPTION 'unbound reversal journal was accepted';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END;
$$;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    INSERT INTO ranchos.finance_journal_entries (
        tenant_id, id, recorded_at, reverses_journal_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-noninvert', CURRENT_TIMESTAMP, 'journal-ok',
        '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_journal_lines (
        tenant_id, journal_entry_id, line_no, account_id, debit, credit
    ) VALUES
        ('00000000-0000-0000-0000-0000000000a1', 'journal-noninvert', 0, 'acct-groceries-a', 42.00, 0.00),
        ('00000000-0000-0000-0000-0000000000a1', 'journal-noninvert', 1, 'acct-checking-a', 0.00, 42.00);
    INSERT INTO ranchos.finance_interpretations (
        tenant_id, id, source_activity_id, journal_entry_id, reverses_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-noninvert', 'activity-ok', 'journal-noninvert',
        'interp-ok', '00000000-0000-0000-0000-000000000011'
    );
    SET CONSTRAINTS ranchos.finance_interpretations_reversal_bound IMMEDIATE;
    RAISE EXCEPTION 'non-inverted reversal journal was accepted';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END;
$$;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    INSERT INTO ranchos.finance_journal_entries (
        tenant_id, id, recorded_at, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'journal-unpaired', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_journal_lines (
        tenant_id, journal_entry_id, line_no, account_id, debit, credit
    ) VALUES
        ('00000000-0000-0000-0000-0000000000a1', 'journal-unpaired', 0, 'acct-groceries-a', 20.00, 0.00),
        ('00000000-0000-0000-0000-0000000000a1', 'journal-unpaired', 1, 'acct-checking-a', 0.00, 20.00);
    INSERT INTO ranchos.finance_interpretations (
        tenant_id, id, source_activity_id, journal_entry_id, supersedes_id, created_by_user_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-unpaired', 'activity-ok', 'journal-unpaired',
        'interp-ok', '00000000-0000-0000-0000-000000000011'
    );
    INSERT INTO ranchos.finance_splits (
        tenant_id, interpretation_id, split_no, amount, destination_account_id,
        allocation_domain, allocation_target_type, allocation_target_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-unpaired', 0, -20.00, 'acct-groceries-a',
        'household', 'none', NULL
    );
    SET CONSTRAINTS ranchos.finance_interpretations_paired_supersession IMMEDIATE;
    RAISE EXCEPTION 'supersede without reversal was accepted';
EXCEPTION
    WHEN check_violation THEN
        NULL;
END;
$$;
SET CONSTRAINTS ALL DEFERRED;

INSERT INTO ranchos.finance_journal_entries (
    tenant_id, id, recorded_at, reverses_journal_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'journal-rev-ok', CURRENT_TIMESTAMP, 'journal-ok',
    '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_lines (
    tenant_id, journal_entry_id, line_no, account_id, debit, credit
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'journal-rev-ok', 0, 'acct-groceries-a', 0.00, 42.00),
    ('00000000-0000-0000-0000-0000000000a1', 'journal-rev-ok', 1, 'acct-checking-a', 42.00, 0.00);
INSERT INTO ranchos.finance_interpretations (
    tenant_id, id, source_activity_id, journal_entry_id, reverses_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-rev-ok', 'activity-ok', 'journal-rev-ok',
    'interp-ok', '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_entries (
    tenant_id, id, recorded_at, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'journal-rep-ok', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_lines (
    tenant_id, journal_entry_id, line_no, account_id, debit, credit
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'journal-rep-ok', 0, 'acct-groceries-a', 42.00, 0.00),
    ('00000000-0000-0000-0000-0000000000a1', 'journal-rep-ok', 1, 'acct-checking-a', 0.00, 42.00);
INSERT INTO ranchos.finance_interpretations (
    tenant_id, id, source_activity_id, journal_entry_id, supersedes_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-rep-ok', 'activity-ok', 'journal-rep-ok',
    'interp-ok', '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_splits (
    tenant_id, interpretation_id, split_no, amount, destination_account_id,
    allocation_domain, allocation_target_type, allocation_target_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-rep-ok', 0, -42.00, 'acct-groceries-a',
    'household', 'none', NULL
);
SET CONSTRAINTS ranchos.finance_interpretations_journal_complete,
                ranchos.finance_interpretations_split_presence,
                ranchos.finance_interpretations_split_derived,
                ranchos.finance_interpretations_paired_supersession,
                ranchos.finance_interpretations_reversal_bound,
                ranchos.finance_journal_lines_balanced IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
BEGIN
    IF (SELECT count(*) FROM ranchos.finance_mutation_audit) <> 1 THEN
        RAISE EXCEPTION 'migrator under FORCE RLS can see cross-tenant finance audit';
    END IF;
END;
$$;
ROLLBACK;
