-- Unapplied DEV-only Ranch OS finance persistence foundation contract.
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator after 001.

BEGIN;

DO $$
DECLARE
    runtime_bypasses_rls boolean;
BEGIN
    IF current_user <> 'ranchos_dev_migrator' THEN
        RAISE EXCEPTION 'this DEV migration must run as ranchos_dev_migrator';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ranchos_dev_migrator')
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ranchos_dev_runtime') THEN
        RAISE EXCEPTION 'ranchos_dev_migrator and ranchos_dev_runtime must be provisioned before this migration';
    END IF;
    SELECT rolbypassrls INTO runtime_bypasses_rls
    FROM pg_roles
    WHERE rolname = 'ranchos_dev_runtime';
    IF runtime_bypasses_rls IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'ranchos_dev_runtime must not have BYPASSRLS';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'ranchos')
       OR NOT EXISTS (
           SELECT 1
           FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'ranchos' AND p.proname = 'require_uuid_setting'
       )
       OR to_regclass('ranchos.tenants') IS NULL
       OR to_regclass('ranchos.users') IS NULL
       OR to_regclass('ranchos.tenant_memberships') IS NULL THEN
        RAISE EXCEPTION '001 tenancy foundation is required before this migration';
    END IF;
END;
$$;

CREATE TABLE ranchos.finance_accounts (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id text NOT NULL CHECK (id <> ''),
    name text NOT NULL CHECK (name <> ''),
    account_type text NOT NULL CHECK (account_type IN (
        'asset', 'liability', 'income', 'expense', 'equity'
    )),
    institution text CHECK (institution IS NULL OR institution <> ''),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_accounts_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE TABLE ranchos.finance_source_artifacts (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id text NOT NULL CHECK (id <> ''),
    kind text NOT NULL CHECK (kind IN ('statement_csv', 'receipt')),
    original_filename text NOT NULL CHECK (original_filename <> ''),
    content_digest text NOT NULL CHECK (content_digest <> ''),
    media_type text NOT NULL CHECK (media_type <> ''),
    byte_size integer NOT NULL CHECK (byte_size >= 0),
    parser_version text NOT NULL CHECK (parser_version <> ''),
    period_start timestamptz,
    period_end timestamptz,
    account_id text,
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_source_artifacts_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT finance_source_artifacts_account_matches_tenant
        FOREIGN KEY (tenant_id, account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id),
    CONSTRAINT finance_source_artifacts_period_window CHECK (
        (period_start IS NULL AND period_end IS NULL)
        OR (period_start IS NOT NULL AND period_end IS NOT NULL AND period_start <= period_end)
    )
);

CREATE TABLE ranchos.finance_source_activities (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id text NOT NULL CHECK (id <> ''),
    source_account_id text NOT NULL,
    source_artifact_id text,
    posted_at timestamptz NOT NULL,
    description text NOT NULL CHECK (description <> ''),
    amount numeric(20,2) NOT NULL CHECK (amount <> 0),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    provenance_observed_at timestamptz NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_source_activities_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT finance_source_activities_account_matches_tenant
        FOREIGN KEY (tenant_id, source_account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id),
    CONSTRAINT finance_source_activities_artifact_matches_tenant
        FOREIGN KEY (tenant_id, source_artifact_id)
        REFERENCES ranchos.finance_source_artifacts (tenant_id, id)
);

CREATE TABLE ranchos.finance_journal_entries (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id text NOT NULL CHECK (id <> ''),
    recorded_at timestamptz NOT NULL,
    reverses_journal_id text,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_journal_entries_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT finance_journal_entries_reverses_matches_tenant
        FOREIGN KEY (tenant_id, reverses_journal_id)
        REFERENCES ranchos.finance_journal_entries (tenant_id, id)
);

CREATE UNIQUE INDEX finance_journal_entries_reverses_unique
    ON ranchos.finance_journal_entries (tenant_id, reverses_journal_id)
    WHERE reverses_journal_id IS NOT NULL;

CREATE TABLE ranchos.finance_journal_lines (
    tenant_id uuid NOT NULL,
    journal_entry_id text NOT NULL,
    line_no integer NOT NULL CHECK (line_no >= 0),
    account_id text NOT NULL,
    debit numeric(20,2) NOT NULL CHECK (debit >= 0),
    credit numeric(20,2) NOT NULL CHECK (credit >= 0),
    PRIMARY KEY (tenant_id, journal_entry_id, line_no),
    CONSTRAINT finance_journal_lines_entry_matches_tenant
        FOREIGN KEY (tenant_id, journal_entry_id)
        REFERENCES ranchos.finance_journal_entries (tenant_id, id),
    CONSTRAINT finance_journal_lines_account_matches_tenant
        FOREIGN KEY (tenant_id, account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id),
    CONSTRAINT finance_journal_lines_one_sided CHECK (
        (debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)
    )
);

CREATE TABLE ranchos.finance_interpretations (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id text NOT NULL CHECK (id <> ''),
    source_activity_id text NOT NULL,
    journal_entry_id text NOT NULL,
    reverses_id text,
    supersedes_id text,
    created_by_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, journal_entry_id),
    CONSTRAINT finance_interpretations_creator_matches_tenant
        FOREIGN KEY (tenant_id, created_by_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id),
    CONSTRAINT finance_interpretations_activity_matches_tenant
        FOREIGN KEY (tenant_id, source_activity_id)
        REFERENCES ranchos.finance_source_activities (tenant_id, id),
    CONSTRAINT finance_interpretations_journal_matches_tenant
        FOREIGN KEY (tenant_id, journal_entry_id)
        REFERENCES ranchos.finance_journal_entries (tenant_id, id),
    CONSTRAINT finance_interpretations_reverses_matches_tenant
        FOREIGN KEY (tenant_id, reverses_id)
        REFERENCES ranchos.finance_interpretations (tenant_id, id),
    CONSTRAINT finance_interpretations_supersedes_matches_tenant
        FOREIGN KEY (tenant_id, supersedes_id)
        REFERENCES ranchos.finance_interpretations (tenant_id, id),
    CONSTRAINT finance_interpretations_not_both_correction_kinds CHECK (
        NOT (reverses_id IS NOT NULL AND supersedes_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX finance_interpretations_reverses_unique
    ON ranchos.finance_interpretations (tenant_id, reverses_id)
    WHERE reverses_id IS NOT NULL;
CREATE UNIQUE INDEX finance_interpretations_supersedes_unique
    ON ranchos.finance_interpretations (tenant_id, supersedes_id)
    WHERE supersedes_id IS NOT NULL;
CREATE UNIQUE INDEX finance_interpretations_root_activity_unique
    ON ranchos.finance_interpretations (tenant_id, source_activity_id)
    WHERE reverses_id IS NULL AND supersedes_id IS NULL;

CREATE TABLE ranchos.finance_splits (
    tenant_id uuid NOT NULL,
    interpretation_id text NOT NULL,
    split_no integer NOT NULL CHECK (split_no >= 0),
    amount numeric(20,2) NOT NULL CHECK (amount <> 0),
    destination_account_id text NOT NULL,
    allocation_domain text,
    allocation_target_type text,
    allocation_target_id text,
    PRIMARY KEY (tenant_id, interpretation_id, split_no),
    CONSTRAINT finance_splits_interpretation_matches_tenant
        FOREIGN KEY (tenant_id, interpretation_id)
        REFERENCES ranchos.finance_interpretations (tenant_id, id),
    CONSTRAINT finance_splits_destination_matches_tenant
        FOREIGN KEY (tenant_id, destination_account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id),
    CONSTRAINT finance_splits_allocation_compatible CHECK (
        (
            allocation_domain IS NULL
            AND allocation_target_type IS NULL
            AND (allocation_target_id IS NULL OR allocation_target_id = '')
        )
        OR (
            allocation_domain = 'household'
            AND allocation_target_type IN ('none', 'household')
            AND (
                (allocation_target_type = 'none' AND (allocation_target_id IS NULL OR allocation_target_id = ''))
                OR (allocation_target_type = 'household' AND allocation_target_id IS NOT NULL AND allocation_target_id <> '')
            )
        )
        OR (
            allocation_domain = 'livestock'
            AND allocation_target_type IN ('herd', 'animal')
            AND allocation_target_id IS NOT NULL AND allocation_target_id <> ''
        )
        OR (
            allocation_domain = 'property'
            AND allocation_target_type = 'asset'
            AND allocation_target_id IS NOT NULL AND allocation_target_id <> ''
        )
        OR (
            allocation_domain = 'equipment'
            AND allocation_target_type = 'equipment'
            AND allocation_target_id IS NOT NULL AND allocation_target_id <> ''
        )
        OR (
            allocation_domain = 'land'
            AND allocation_target_type = 'parcel'
            AND allocation_target_id IS NOT NULL AND allocation_target_id <> ''
        )
    )
);

CREATE TABLE ranchos.finance_idempotency (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    scope text NOT NULL,
    identity text NOT NULL CHECK (identity <> ''),
    key_digest text NOT NULL CHECK (key_digest <> ''),
    operation text NOT NULL CHECK (operation IN (
        'ranchos.finance.account-create',
        'ranchos.finance.source-artifact-record',
        'ranchos.finance.source-activity-record',
        'ranchos.finance.interpretation-post',
        'ranchos.finance.interpretation-reverse',
        'ranchos.finance.interpretation-supersede'
    )),
    outcome text NOT NULL CHECK (outcome IN ('reserved', 'committed')),
    transaction_id uuid NOT NULL,
    result_account_id text,
    result_artifact_id text,
    result_activity_id text,
    result_interpretation_id text,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, scope, identity),
    CONSTRAINT finance_idempotency_scope_matches_operation CHECK (scope = operation),
    CONSTRAINT finance_idempotency_result_matches_operation CHECK (
        (
            outcome = 'reserved'
            AND result_account_id IS NULL
            AND result_artifact_id IS NULL
            AND result_activity_id IS NULL
            AND result_interpretation_id IS NULL
        )
        OR (
            outcome = 'committed'
            AND operation = 'ranchos.finance.account-create'
            AND result_account_id IS NOT NULL
            AND result_artifact_id IS NULL
            AND result_activity_id IS NULL
            AND result_interpretation_id IS NULL
        )
        OR (
            outcome = 'committed'
            AND operation = 'ranchos.finance.source-artifact-record'
            AND result_account_id IS NULL
            AND result_artifact_id IS NOT NULL
            AND result_activity_id IS NULL
            AND result_interpretation_id IS NULL
        )
        OR (
            outcome = 'committed'
            AND operation = 'ranchos.finance.source-activity-record'
            AND result_account_id IS NULL
            AND result_artifact_id IS NULL
            AND result_activity_id IS NOT NULL
            AND result_interpretation_id IS NULL
        )
        OR (
            outcome = 'committed'
            AND operation IN (
                'ranchos.finance.interpretation-post',
                'ranchos.finance.interpretation-reverse',
                'ranchos.finance.interpretation-supersede'
            )
            AND result_account_id IS NULL
            AND result_artifact_id IS NULL
            AND result_activity_id IS NULL
            AND result_interpretation_id IS NOT NULL
        )
    ),
    CONSTRAINT finance_idempotency_account_matches_tenant
        FOREIGN KEY (tenant_id, result_account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id),
    CONSTRAINT finance_idempotency_artifact_matches_tenant
        FOREIGN KEY (tenant_id, result_artifact_id)
        REFERENCES ranchos.finance_source_artifacts (tenant_id, id),
    CONSTRAINT finance_idempotency_activity_matches_tenant
        FOREIGN KEY (tenant_id, result_activity_id)
        REFERENCES ranchos.finance_source_activities (tenant_id, id),
    CONSTRAINT finance_idempotency_interpretation_matches_tenant
        FOREIGN KEY (tenant_id, result_interpretation_id)
        REFERENCES ranchos.finance_interpretations (tenant_id, id)
);

CREATE TABLE ranchos.finance_mutation_audit (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL,
    transaction_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN (
        'ranchos.finance.account-create',
        'ranchos.finance.source-artifact-record',
        'ranchos.finance.source-activity-record',
        'ranchos.finance.interpretation-post',
        'ranchos.finance.interpretation-reverse',
        'ranchos.finance.interpretation-supersede'
    )),
    targets text NOT NULL CHECK (targets <> ''),
    actor_user_id uuid NOT NULL REFERENCES ranchos.users(id),
    principal_id uuid NOT NULL,
    correlation_id text NOT NULL CHECK (correlation_id <> ''),
    policy_version text NOT NULL CHECK (policy_version <> ''),
    validator_version text NOT NULL CHECK (validator_version <> ''),
    idempotency_outcome text NOT NULL CHECK (idempotency_outcome <> ''),
    provenance_source_type text NOT NULL CHECK (provenance_source_type <> ''),
    provenance_source_id text NOT NULL CHECK (provenance_source_id <> ''),
    provenance_source_version text NOT NULL CHECK (provenance_source_version <> ''),
    result_metadata text NOT NULL CHECK (result_metadata <> ''),
    recorded_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_mutation_audit_actor_matches_tenant
        FOREIGN KEY (tenant_id, actor_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);

CREATE INDEX finance_source_activities_tenant_posted_idx
    ON ranchos.finance_source_activities (tenant_id, posted_at, id);
CREATE INDEX finance_interpretations_tenant_activity_idx
    ON ranchos.finance_interpretations (tenant_id, source_activity_id);

CREATE OR REPLACE FUNCTION ranchos.finance_journal_reject_unbalanced()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    debit_total numeric(20,2);
    credit_total numeric(20,2);
    line_count integer;
BEGIN
    SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0), COUNT(*)
    INTO debit_total, credit_total, line_count
    FROM ranchos.finance_journal_lines
    WHERE tenant_id = NEW.tenant_id AND journal_entry_id = NEW.journal_entry_id;
    IF line_count < 2 OR debit_total <> credit_total THEN
        RAISE EXCEPTION 'journal entry must balance exactly'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_journal_lines_balanced
AFTER INSERT ON ranchos.finance_journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_journal_reject_unbalanced();

CREATE OR REPLACE FUNCTION ranchos.finance_interpretations_reject_invalid_splits()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF NEW.reverses_id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM ranchos.finance_splits split
            WHERE split.tenant_id = NEW.tenant_id
              AND split.interpretation_id = NEW.id
        ) THEN
            RAISE EXCEPTION 'reversal cannot carry replacement splits'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM ranchos.finance_splits split
        WHERE split.tenant_id = NEW.tenant_id
          AND split.interpretation_id = NEW.id
    ) THEN
        RAISE EXCEPTION 'posted interpretation requires splits'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_interpretations_split_presence
AFTER INSERT ON ranchos.finance_interpretations
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_interpretations_reject_invalid_splits();

-- Posted lines and splits may be inserted only in the same PostgreSQL
-- transaction that created the parent interpretation. age(xmin) = 0 is
-- that creating transaction; after commit, later appends are rejected.
-- Coordinator order stays valid: journal, lines, interpretation, splits.
CREATE OR REPLACE FUNCTION ranchos.finance_journal_lines_reject_posted_append()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM ranchos.finance_interpretations interpretation
        WHERE interpretation.tenant_id = NEW.tenant_id
          AND interpretation.journal_entry_id = NEW.journal_entry_id
          AND age(interpretation.xmin) <> 0
    ) THEN
        RAISE EXCEPTION 'posted journal lines are immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_journal_lines_posted_immutable
AFTER INSERT ON ranchos.finance_journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_journal_lines_reject_posted_append();

CREATE OR REPLACE FUNCTION ranchos.finance_splits_reject_posted_append()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM ranchos.finance_interpretations interpretation
        WHERE interpretation.tenant_id = NEW.tenant_id
          AND interpretation.id = NEW.interpretation_id
          AND age(interpretation.xmin) <> 0
    ) THEN
        RAISE EXCEPTION 'posted splits are immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_splits_posted_immutable
AFTER INSERT ON ranchos.finance_splits
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_splits_reject_posted_append();

CREATE OR REPLACE FUNCTION ranchos.finance_interpretations_reject_incomplete_journal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    debit_total numeric(20,2);
    credit_total numeric(20,2);
    line_count integer;
BEGIN
    SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0), COUNT(*)
    INTO debit_total, credit_total, line_count
    FROM ranchos.finance_journal_lines
    WHERE tenant_id = NEW.tenant_id AND journal_entry_id = NEW.journal_entry_id;
    IF line_count < 2 OR debit_total <> credit_total THEN
        RAISE EXCEPTION 'interpretation journal must have at least two balanced lines'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_interpretations_journal_complete
AFTER INSERT ON ranchos.finance_interpretations
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_interpretations_reject_incomplete_journal();

CREATE OR REPLACE FUNCTION ranchos.finance_interpretations_reject_unpaired_supersession()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF NEW.supersedes_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM ranchos.finance_interpretations reversal
        WHERE reversal.tenant_id = NEW.tenant_id
          AND reversal.reverses_id = NEW.supersedes_id
    ) THEN
        RAISE EXCEPTION 'superseding interpretation requires a paired reversal'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_interpretations_paired_supersession
AFTER INSERT ON ranchos.finance_interpretations
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_interpretations_reject_unpaired_supersession();

CREATE OR REPLACE FUNCTION ranchos.finance_interpretations_reject_unrepresentative_journal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    activity_amount numeric(20,2);
    source_account text;
    split_sum numeric(20,2);
    split_count integer;
    reverses_journal text;
BEGIN
    IF NEW.reverses_id IS NOT NULL THEN
        RETURN NEW;
    END IF;
    SELECT amount, source_account_id
    INTO activity_amount, source_account
    FROM ranchos.finance_source_activities
    WHERE tenant_id = NEW.tenant_id AND id = NEW.source_activity_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'journal must represent the supplied splits and source activity'
            USING ERRCODE = '23514';
    END IF;
    SELECT COALESCE(SUM(amount), 0), COUNT(*)
    INTO split_sum, split_count
    FROM ranchos.finance_splits
    WHERE tenant_id = NEW.tenant_id AND interpretation_id = NEW.id;
    IF split_count = 0 OR split_sum <> activity_amount OR split_sum >= 0 THEN
        RAISE EXCEPTION 'journal must represent the supplied splits and source activity'
            USING ERRCODE = '23514';
    END IF;
    SELECT reverses_journal_id
    INTO reverses_journal
    FROM ranchos.finance_journal_entries
    WHERE tenant_id = NEW.tenant_id AND id = NEW.journal_entry_id;
    IF NOT FOUND OR reverses_journal IS NOT NULL THEN
        RAISE EXCEPTION 'journal must represent the supplied splits and source activity'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT expected.line_no, expected.account_id, expected.debit, expected.credit
        FROM (
            SELECT
                (ROW_NUMBER() OVER (ORDER BY split.split_no, split.destination_account_id) - 1)::integer AS line_no,
                split.destination_account_id AS account_id,
                (-split.amount)::numeric(20,2) AS debit,
                0::numeric(20,2) AS credit
            FROM ranchos.finance_splits split
            WHERE split.tenant_id = NEW.tenant_id AND split.interpretation_id = NEW.id
            UNION ALL
            SELECT
                split_count,
                source_account,
                0::numeric(20,2),
                (-split_sum)::numeric(20,2)
        ) expected
        EXCEPT
        SELECT line.line_no, line.account_id, line.debit, line.credit
        FROM ranchos.finance_journal_lines line
        WHERE line.tenant_id = NEW.tenant_id AND line.journal_entry_id = NEW.journal_entry_id
    ) OR EXISTS (
        SELECT line.line_no, line.account_id, line.debit, line.credit
        FROM ranchos.finance_journal_lines line
        WHERE line.tenant_id = NEW.tenant_id AND line.journal_entry_id = NEW.journal_entry_id
        EXCEPT
        SELECT expected.line_no, expected.account_id, expected.debit, expected.credit
        FROM (
            SELECT
                (ROW_NUMBER() OVER (ORDER BY split.split_no, split.destination_account_id) - 1)::integer AS line_no,
                split.destination_account_id AS account_id,
                (-split.amount)::numeric(20,2) AS debit,
                0::numeric(20,2) AS credit
            FROM ranchos.finance_splits split
            WHERE split.tenant_id = NEW.tenant_id AND split.interpretation_id = NEW.id
            UNION ALL
            SELECT
                split_count,
                source_account,
                0::numeric(20,2),
                (-split_sum)::numeric(20,2)
        ) expected
    ) THEN
        RAISE EXCEPTION 'journal must represent the supplied splits and source activity'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_interpretations_split_derived
AFTER INSERT ON ranchos.finance_interpretations
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_interpretations_reject_unrepresentative_journal();

CREATE OR REPLACE FUNCTION ranchos.finance_interpretations_reject_unbound_reversal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
DECLARE
    original_activity text;
    original_journal text;
    new_reverses_journal text;
BEGIN
    IF NEW.reverses_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT source_activity_id, journal_entry_id
    INTO original_activity, original_journal
    FROM ranchos.finance_interpretations
    WHERE tenant_id = NEW.tenant_id AND id = NEW.reverses_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'reversal journal must bind the original journal'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.source_activity_id IS DISTINCT FROM original_activity THEN
        RAISE EXCEPTION 'reversal must keep the source activity'
            USING ERRCODE = '23514';
    END IF;
    SELECT reverses_journal_id
    INTO new_reverses_journal
    FROM ranchos.finance_journal_entries
    WHERE tenant_id = NEW.tenant_id AND id = NEW.journal_entry_id;
    IF NOT FOUND OR new_reverses_journal IS DISTINCT FROM original_journal THEN
        RAISE EXCEPTION 'reversal journal must bind the original journal'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM ranchos.finance_journal_lines original_line
        LEFT JOIN ranchos.finance_journal_lines reversed_line
          ON reversed_line.tenant_id = NEW.tenant_id
         AND reversed_line.journal_entry_id = NEW.journal_entry_id
         AND reversed_line.line_no = original_line.line_no
         AND reversed_line.account_id = original_line.account_id
        WHERE original_line.tenant_id = NEW.tenant_id
          AND original_line.journal_entry_id = original_journal
          AND (
              reversed_line.journal_entry_id IS NULL
              OR reversed_line.debit IS DISTINCT FROM original_line.credit
              OR reversed_line.credit IS DISTINCT FROM original_line.debit
          )
    ) OR EXISTS (
        SELECT 1
        FROM ranchos.finance_journal_lines reversed_line
        LEFT JOIN ranchos.finance_journal_lines original_line
          ON original_line.tenant_id = NEW.tenant_id
         AND original_line.journal_entry_id = original_journal
         AND original_line.line_no = reversed_line.line_no
         AND original_line.account_id = reversed_line.account_id
        WHERE reversed_line.tenant_id = NEW.tenant_id
          AND reversed_line.journal_entry_id = NEW.journal_entry_id
          AND original_line.journal_entry_id IS NULL
    ) THEN
        RAISE EXCEPTION 'reversal journal must invert the original lines'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_interpretations_reversal_bound
AFTER INSERT ON ranchos.finance_interpretations
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_interpretations_reject_unbound_reversal();

CREATE OR REPLACE FUNCTION ranchos.finance_idempotency_enforce_finalize_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ranchos, pg_temp
AS $$
BEGIN
    IF OLD.tenant_id IS DISTINCT FROM NEW.tenant_id
       OR OLD.scope IS DISTINCT FROM NEW.scope
       OR OLD.identity IS DISTINCT FROM NEW.identity
       OR OLD.key_digest IS DISTINCT FROM NEW.key_digest
       OR OLD.operation IS DISTINCT FROM NEW.operation
       OR OLD.transaction_id IS DISTINCT FROM NEW.transaction_id THEN
        RAISE EXCEPTION 'idempotency identity is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.outcome = 'committed' THEN
        RAISE EXCEPTION 'committed idempotency is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.outcome <> 'reserved' OR NEW.outcome <> 'committed' THEN
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.operation = 'ranchos.finance.account-create' AND NEW.result_account_id IS NULL THEN
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.operation = 'ranchos.finance.source-artifact-record' AND NEW.result_artifact_id IS NULL THEN
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.operation = 'ranchos.finance.source-activity-record' AND NEW.result_activity_id IS NULL THEN
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.operation IN (
        'ranchos.finance.interpretation-post',
        'ranchos.finance.interpretation-reverse',
        'ranchos.finance.interpretation-supersede'
    ) AND NEW.result_interpretation_id IS NULL THEN
        RAISE EXCEPTION 'idempotency finalize is invalid'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER finance_idempotency_finalize_only
BEFORE UPDATE ON ranchos.finance_idempotency
FOR EACH ROW
EXECUTE PROCEDURE ranchos.finance_idempotency_enforce_finalize_only();

ALTER TABLE ranchos.finance_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_source_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_source_artifacts FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_source_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_source_activities FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_journal_entries FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_journal_lines FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_interpretations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_interpretations FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_splits ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_splits FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_idempotency FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_mutation_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_mutation_audit FORCE ROW LEVEL SECURITY;

CREATE POLICY finance_accounts_tenant_isolation ON ranchos.finance_accounts
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_source_artifacts_tenant_isolation ON ranchos.finance_source_artifacts
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_source_activities_tenant_isolation ON ranchos.finance_source_activities
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_journal_entries_tenant_isolation ON ranchos.finance_journal_entries
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_journal_lines_tenant_isolation ON ranchos.finance_journal_lines
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_interpretations_tenant_isolation ON ranchos.finance_interpretations
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_splits_tenant_isolation ON ranchos.finance_splits
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_idempotency_tenant_isolation ON ranchos.finance_idempotency
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_mutation_audit_tenant_isolation ON ranchos.finance_mutation_audit
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

REVOKE ALL ON ranchos.finance_accounts FROM PUBLIC;
REVOKE ALL ON ranchos.finance_source_artifacts FROM PUBLIC;
REVOKE ALL ON ranchos.finance_source_activities FROM PUBLIC;
REVOKE ALL ON ranchos.finance_journal_entries FROM PUBLIC;
REVOKE ALL ON ranchos.finance_journal_lines FROM PUBLIC;
REVOKE ALL ON ranchos.finance_interpretations FROM PUBLIC;
REVOKE ALL ON ranchos.finance_splits FROM PUBLIC;
REVOKE ALL ON ranchos.finance_idempotency FROM PUBLIC;
REVOKE ALL ON ranchos.finance_mutation_audit FROM PUBLIC;

GRANT SELECT, INSERT ON ranchos.finance_accounts, ranchos.finance_source_artifacts,
    ranchos.finance_source_activities, ranchos.finance_journal_entries,
    ranchos.finance_journal_lines, ranchos.finance_interpretations, ranchos.finance_splits
    TO ranchos_dev_runtime;
GRANT SELECT, INSERT, UPDATE ON ranchos.finance_idempotency TO ranchos_dev_runtime;
GRANT INSERT ON ranchos.finance_mutation_audit TO ranchos_dev_runtime;

ALTER TABLE ranchos.finance_accounts OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_source_artifacts OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_source_activities OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_journal_entries OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_journal_lines OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_interpretations OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_splits OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_idempotency OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_mutation_audit OWNER TO ranchos_dev_migrator;

DO $$
DECLARE
    table_name text;
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'finance_accounts',
        'finance_source_artifacts',
        'finance_source_activities',
        'finance_journal_entries',
        'finance_journal_lines',
        'finance_interpretations',
        'finance_splits',
        'finance_idempotency',
        'finance_mutation_audit'
    ]
    LOOP
        SELECT pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity
        INTO table_owner, rls_enabled, rls_forced
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'ranchos' AND c.relkind = 'r' AND c.relname = table_name;
        IF NOT FOUND OR table_owner <> 'ranchos_dev_migrator' THEN
            RAISE EXCEPTION 'tenant-scoped table % must be owned by ranchos_dev_migrator', table_name;
        END IF;
        IF NOT rls_enabled OR NOT rls_forced THEN
            RAISE EXCEPTION 'tenant-scoped table % must enable and force RLS', table_name;
        END IF;
    END LOOP;
END;
$$;

COMMIT;
