-- Disposable-only post-commit finance journal/split immutability proof.
-- Never apply to Production. Requires 001 and 005 on an isolated cluster.
-- Transaction 1 commits a Tenant A posting as ranchos_dev_runtime.
-- Transaction 2, as the same non-superuser runtime role, must fail to append.
-- Cluster teardown is the cleanup mechanism.

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
SET LOCAL ROLE ranchos_dev_runtime;
INSERT INTO ranchos.finance_accounts (
    tenant_id, id, name, account_type, institution,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'acct-immut-checking', 'Checking', 'asset', 'BancFirst',
     'fixture', 'acct-immut-checking', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'),
    ('00000000-0000-0000-0000-0000000000a1', 'acct-immut-groceries', 'Groceries', 'expense', NULL,
     'fixture', 'acct-immut-groceries', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011');
INSERT INTO ranchos.finance_source_activities (
    tenant_id, id, source_account_id, posted_at, description, amount,
    provenance_source_type, provenance_source_id, provenance_source_version, provenance_observed_at,
    created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'activity-immut', 'acct-immut-checking', CURRENT_TIMESTAMP, 'Groceries', -42.00,
    'fixture', 'activity-immut', 'fixture-v1', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_entries (
    tenant_id, id, recorded_at, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'journal-immut', CURRENT_TIMESTAMP, '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_journal_lines (
    tenant_id, journal_entry_id, line_no, account_id, debit, credit
) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'journal-immut', 0, 'acct-immut-groceries', 42.00, 0.00),
    ('00000000-0000-0000-0000-0000000000a1', 'journal-immut', 1, 'acct-immut-checking', 0.00, 42.00);
INSERT INTO ranchos.finance_interpretations (
    tenant_id, id, source_activity_id, journal_entry_id, created_by_user_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-immut', 'activity-immut', 'journal-immut',
    '00000000-0000-0000-0000-000000000011'
);
INSERT INTO ranchos.finance_splits (
    tenant_id, interpretation_id, split_no, amount, destination_account_id,
    allocation_domain, allocation_target_type, allocation_target_id
) VALUES (
    '00000000-0000-0000-0000-0000000000a1', 'interp-immut', 0, -42.00, 'acct-immut-groceries',
    'household', 'none', NULL
);
COMMIT;

BEGIN;
SET LOCAL ROLE ranchos_dev_runtime;
SET LOCAL ranchos.principal_id = '00000000-0000-0000-0000-000000000001';
SET LOCAL ranchos.environment = 'development';
SET LOCAL ranchos.tenant_id = '00000000-0000-0000-0000-0000000000a1';
DO $$
DECLARE
    runtime_is_super boolean;
BEGIN
    SELECT rolsuper INTO runtime_is_super
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_is_super IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not be a superuser';
    END IF;
    INSERT INTO ranchos.finance_journal_lines (
        tenant_id, journal_entry_id, line_no, account_id, debit, credit
    ) VALUES
        ('00000000-0000-0000-0000-0000000000a1', 'journal-immut', 2, 'acct-immut-groceries', 1.00, 0.00),
        ('00000000-0000-0000-0000-0000000000a1', 'journal-immut', 3, 'acct-immut-checking', 0.00, 1.00);
    SET CONSTRAINTS ranchos.finance_journal_lines_posted_immutable IMMEDIATE;
    RAISE EXCEPTION 'extra balanced journal lines were accepted';
EXCEPTION
    WHEN SQLSTATE '23514' THEN
        IF SQLERRM NOT LIKE '%posted journal lines are immutable%' THEN
            RAISE EXCEPTION 'expected posted journal line immutability, got %', SQLERRM;
        END IF;
        RAISE NOTICE 'finance post-commit immutability: extra journal lines denied';
END;
$$;
DO $$
BEGIN
    INSERT INTO ranchos.finance_splits (
        tenant_id, interpretation_id, split_no, amount, destination_account_id,
        allocation_domain, allocation_target_type, allocation_target_id
    ) VALUES (
        '00000000-0000-0000-0000-0000000000a1', 'interp-immut', 1, -1.00, 'acct-immut-groceries',
        'household', 'none', NULL
    );
    SET CONSTRAINTS ranchos.finance_splits_posted_immutable IMMEDIATE;
    RAISE EXCEPTION 'extra split was accepted';
EXCEPTION
    WHEN SQLSTATE '23514' THEN
        IF SQLERRM NOT LIKE '%posted splits are immutable%' THEN
            RAISE EXCEPTION 'expected posted split immutability, got %', SQLERRM;
        END IF;
        RAISE NOTICE 'finance post-commit immutability: extra split denied';
END;
$$;
DO $$
DECLARE
    line_count integer;
    split_count integer;
    debit_total numeric(20,2);
    credit_total numeric(20,2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
    INTO line_count, debit_total, credit_total
    FROM ranchos.finance_journal_lines
    WHERE tenant_id = '00000000-0000-0000-0000-0000000000a1'
      AND journal_entry_id = 'journal-immut';
    SELECT COUNT(*)
    INTO split_count
    FROM ranchos.finance_splits
    WHERE tenant_id = '00000000-0000-0000-0000-0000000000a1'
      AND interpretation_id = 'interp-immut';
    IF line_count <> 2 OR split_count <> 1 OR debit_total <> credit_total OR debit_total <> 42.00 THEN
        RAISE EXCEPTION 'original posting was changed after rejected appends';
    END IF;
    RAISE NOTICE 'finance post-commit immutability: original posting unchanged';
END;
$$;
SELECT 'finance post-commit immutability: extra journal lines denied' AS marker
UNION ALL
SELECT 'finance post-commit immutability: extra split denied'
UNION ALL
SELECT 'finance post-commit immutability: original posting unchanged';
ROLLBACK;
