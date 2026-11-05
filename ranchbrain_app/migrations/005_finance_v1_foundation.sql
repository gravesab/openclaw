-- Unapplied DEV-only Ranch Finance v1 foundation (Master Specification v1.1, Checkpoint 1).
-- Replaces the superseded double-entry 005 (owner rulings P0-5 and D4, 2026-11-05).
-- Never apply this file to Production.
-- Apply only on an isolated disposable DEV database as ranchos_dev_migrator after 001.
-- Never apply to ranchos_livestock_dev, which holds real records.
--
-- Scope: domains, accounts, categories, transactions, transfers, audit events.
-- Import profiles/batches (Checkpoint 3) and recurring rules (Checkpoint 5) come later;
-- finance_transactions.import_batch_id gains its foreign key in Checkpoint 3.
-- Every table is tenant-scoped with FORCE RLS (Checkpoint 0 plan C4/D2).

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

-- Shared helper (first use; other modules may adopt it later).
CREATE OR REPLACE FUNCTION ranchos.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- 5.1 finance_domains ---------------------------------------------------------
CREATE TABLE ranchos.finance_domains (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    code text NOT NULL CHECK (code IN ('personal', 'ranch', 'zero_g')),
    name text NOT NULL CHECK (btrim(name) <> ''),
    sort_order integer NOT NULL DEFAULT 0,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_domains_code_unique UNIQUE (tenant_id, code)
);
CREATE INDEX finance_domains_active_idx ON ranchos.finance_domains (tenant_id, is_active);

CREATE OR REPLACE FUNCTION ranchos.finance_domains_reject_code_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'finance domain code is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER finance_domains_code_immutable
    BEFORE UPDATE ON ranchos.finance_domains
    FOR EACH ROW EXECUTE FUNCTION ranchos.finance_domains_reject_code_change();

-- 5.2 finance_accounts --------------------------------------------------------
CREATE TABLE ranchos.finance_accounts (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    default_domain_id uuid NOT NULL,
    name text NOT NULL CHECK (btrim(name) <> ''),
    account_type text NOT NULL CHECK (account_type IN ('checking', 'savings', 'credit', 'investment', 'cash')),
    institution text,
    currency char(3) NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
    opening_balance numeric(14,2) NOT NULL DEFAULT 0.00,
    opening_balance_date date,
    last_four text CHECK (last_four IS NULL OR last_four ~ '^[0-9]{4}$'),
    is_active boolean NOT NULL DEFAULT true,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_accounts_opening_balance_dated
        CHECK (opening_balance = 0 OR opening_balance_date IS NOT NULL),
    CONSTRAINT finance_accounts_default_domain_fk
        FOREIGN KEY (tenant_id, default_domain_id)
        REFERENCES ranchos.finance_domains (tenant_id, id) ON DELETE RESTRICT
);
CREATE INDEX finance_accounts_domain_idx ON ranchos.finance_accounts (tenant_id, default_domain_id);
CREATE INDEX finance_accounts_active_idx ON ranchos.finance_accounts (tenant_id, is_active);
CREATE INDEX finance_accounts_name_idx ON ranchos.finance_accounts (tenant_id, lower(name));

-- 5.3 finance_categories ------------------------------------------------------
CREATE TABLE ranchos.finance_categories (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    domain_id uuid,
    parent_id uuid,
    name text NOT NULL CHECK (btrim(name) <> ''),
    category_type text NOT NULL CHECK (category_type IN ('income', 'expense', 'transfer')),
    color text CHECK (color IS NULL OR color ~ '^#[0-9A-Fa-f]{6}$'),
    icon text,
    sort_order integer NOT NULL DEFAULT 0,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_categories_not_own_parent CHECK (parent_id IS NULL OR parent_id <> id),
    CONSTRAINT finance_categories_domain_fk
        FOREIGN KEY (tenant_id, domain_id)
        REFERENCES ranchos.finance_domains (tenant_id, id) ON DELETE RESTRICT,
    CONSTRAINT finance_categories_parent_fk
        FOREIGN KEY (tenant_id, parent_id)
        REFERENCES ranchos.finance_categories (tenant_id, id) ON DELETE RESTRICT
);
-- Names are unique case-insensitively within parent/domain scope (null scopes compare equal).
CREATE UNIQUE INDEX finance_categories_scoped_name_idx ON ranchos.finance_categories (
    tenant_id,
    coalesce(domain_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(name)
);

-- 5.7 finance_transfers (before transactions, which reference it) -------------
CREATE TABLE ranchos.finance_transfers (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    from_account_id uuid NOT NULL,
    to_account_id uuid NOT NULL,
    transfer_date date NOT NULL,
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    amount numeric(14,2) NOT NULL CHECK (amount > 0),
    status text NOT NULL CHECK (status IN ('pending', 'confirmed', 'excluded', 'broken')),
    notes text,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_transfers_distinct_accounts CHECK (from_account_id <> to_account_id),
    CONSTRAINT finance_transfers_from_fk
        FOREIGN KEY (tenant_id, from_account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id) ON DELETE RESTRICT,
    CONSTRAINT finance_transfers_to_fk
        FOREIGN KEY (tenant_id, to_account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id) ON DELETE RESTRICT
);

-- 5.6 finance_transactions ----------------------------------------------------
CREATE TABLE ranchos.finance_transactions (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL,
    domain_id uuid NOT NULL,
    category_id uuid,
    transfer_id uuid,
    import_batch_id uuid,
    supersedes_transaction_id uuid,
    -- Signed and authoritative: positive inflow, negative outflow, zero prohibited (Spec §4).
    -- There is deliberately no editable direction column.
    amount numeric(14,2) NOT NULL CHECK (amount <> 0),
    currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    description text NOT NULL CHECK (btrim(description) <> '' AND description = btrim(description)),
    normalized_description text NOT NULL,
    merchant text,
    transaction_date date NOT NULL,
    posted_date date,
    source_type text NOT NULL CHECK (source_type IN ('csv', 'manual', 'recurring_confirmation', 'system_correction')),
    source_row_number integer CHECK (source_row_number IS NULL OR source_row_number > 0),
    source_reference text,
    dedup_fingerprint text NOT NULL CHECK (dedup_fingerprint <> ''),
    notes text,
    reconciliation_status text NOT NULL DEFAULT 'unreconciled'
        CHECK (reconciliation_status IN ('unreconciled', 'reconciled')),
    record_status text NOT NULL DEFAULT 'active'
        CHECK (record_status IN ('active', 'excluded', 'voided', 'superseded')),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_transactions_csv_row_required
        CHECK (source_type <> 'csv' OR source_row_number IS NOT NULL),
    CONSTRAINT finance_transactions_not_self_superseding
        CHECK (supersedes_transaction_id IS NULL OR supersedes_transaction_id <> id),
    CONSTRAINT finance_transactions_account_fk
        FOREIGN KEY (tenant_id, account_id)
        REFERENCES ranchos.finance_accounts (tenant_id, id) ON DELETE RESTRICT,
    CONSTRAINT finance_transactions_domain_fk
        FOREIGN KEY (tenant_id, domain_id)
        REFERENCES ranchos.finance_domains (tenant_id, id) ON DELETE RESTRICT,
    -- SET NULL only the category column; tenant_id is part of the key (PostgreSQL 15+).
    CONSTRAINT finance_transactions_category_fk
        FOREIGN KEY (tenant_id, category_id)
        REFERENCES ranchos.finance_categories (tenant_id, id) ON DELETE SET NULL (category_id),
    CONSTRAINT finance_transactions_transfer_fk
        FOREIGN KEY (tenant_id, transfer_id)
        REFERENCES ranchos.finance_transfers (tenant_id, id) ON DELETE RESTRICT,
    CONSTRAINT finance_transactions_supersedes_fk
        FOREIGN KEY (tenant_id, supersedes_transaction_id)
        REFERENCES ranchos.finance_transactions (tenant_id, id) ON DELETE RESTRICT
);
CREATE INDEX finance_transactions_account_date_idx ON ranchos.finance_transactions (tenant_id, account_id, transaction_date);
CREATE INDEX finance_transactions_domain_date_idx ON ranchos.finance_transactions (tenant_id, domain_id, transaction_date);
CREATE INDEX finance_transactions_category_date_idx ON ranchos.finance_transactions (tenant_id, category_id, transaction_date);
CREATE INDEX finance_transactions_import_batch_idx ON ranchos.finance_transactions (tenant_id, import_batch_id);
CREATE INDEX finance_transactions_transfer_idx ON ranchos.finance_transactions (tenant_id, transfer_id);
CREATE INDEX finance_transactions_source_reference_idx ON ranchos.finance_transactions (tenant_id, account_id, source_reference);
CREATE INDEX finance_transactions_dedup_idx ON ranchos.finance_transactions (tenant_id, account_id, dedup_fingerprint);
CREATE INDEX finance_transactions_active_idx ON ranchos.finance_transactions (tenant_id, domain_id, transaction_date)
    WHERE record_status = 'active';

-- normalized_description is derived, never user-editable; currency must match the account (v1).
CREATE OR REPLACE FUNCTION ranchos.finance_transactions_derive_and_check()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    account_currency char(3);
BEGIN
    NEW.normalized_description := lower(regexp_replace(btrim(NEW.description), '\s+', ' ', 'g'));
    SELECT a.currency INTO account_currency
    FROM ranchos.finance_accounts a
    WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.account_id;
    IF account_currency IS NOT NULL AND account_currency <> NEW.currency THEN
        RAISE EXCEPTION 'transaction currency must match its account in v1' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER finance_transactions_derive_and_check
    BEFORE INSERT OR UPDATE ON ranchos.finance_transactions
    FOR EACH ROW EXECUTE FUNCTION ranchos.finance_transactions_derive_and_check();

-- A confirmed transfer has exactly two active rows: -amount on the source account and
-- +amount on the destination, both carrying transfer_id (Spec §5.7). Checked at commit.
CREATE OR REPLACE FUNCTION ranchos.finance_transfer_check(p_tenant uuid, p_transfer uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    t ranchos.finance_transfers%ROWTYPE;
    active_rows integer;
    source_ok integer;
    destination_ok integer;
BEGIN
    IF p_transfer IS NULL THEN
        RETURN;
    END IF;
    SELECT * INTO t FROM ranchos.finance_transfers WHERE tenant_id = p_tenant AND id = p_transfer;
    IF NOT FOUND OR t.status <> 'confirmed' THEN
        RETURN;
    END IF;
    SELECT count(*),
           count(*) FILTER (WHERE account_id = t.from_account_id AND amount = -t.amount AND currency = t.currency),
           count(*) FILTER (WHERE account_id = t.to_account_id AND amount = t.amount AND currency = t.currency)
    INTO active_rows, source_ok, destination_ok
    FROM ranchos.finance_transactions
    WHERE tenant_id = p_tenant AND transfer_id = p_transfer AND record_status = 'active';
    IF active_rows <> 2 OR source_ok <> 1 OR destination_ok <> 1 THEN
        RAISE EXCEPTION 'confirmed transfer % must have exactly two equal and opposite active rows', p_transfer
            USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ranchos.finance_transfers_check_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM ranchos.finance_transfer_check(NEW.tenant_id, NEW.id);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION ranchos.finance_transactions_transfer_check_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM ranchos.finance_transfer_check(OLD.tenant_id, OLD.transfer_id);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM ranchos.finance_transfer_check(NEW.tenant_id, NEW.transfer_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER finance_transfers_pairing
    AFTER INSERT OR UPDATE ON ranchos.finance_transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ranchos.finance_transfers_check_trigger();
CREATE CONSTRAINT TRIGGER finance_transactions_transfer_pairing
    AFTER INSERT OR UPDATE OR DELETE ON ranchos.finance_transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ranchos.finance_transactions_transfer_check_trigger();

-- 5.9 finance_audit_events: finance-local append-only (no OpenClaw audit service exists).
CREATE TABLE ranchos.finance_audit_events (
    tenant_id uuid NOT NULL REFERENCES ranchos.tenants(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    occurred_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actor_user_id uuid NOT NULL,
    principal_id uuid NOT NULL,
    action text NOT NULL CHECK (btrim(action) <> ''),
    object_type text NOT NULL CHECK (btrim(object_type) <> ''),
    object_id uuid NOT NULL,
    correlation_id text NOT NULL CHECK (btrim(correlation_id) <> ''),
    before_redacted jsonb,
    after_redacted jsonb,
    confirmation_reason text,
    device_metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(device_metadata) = 'object'),
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT finance_audit_events_actor_matches_tenant
        FOREIGN KEY (tenant_id, actor_user_id)
        REFERENCES ranchos.tenant_memberships (tenant_id, user_id)
);
CREATE INDEX finance_audit_events_object_idx ON ranchos.finance_audit_events (tenant_id, object_type, object_id);
CREATE INDEX finance_audit_events_correlation_idx ON ranchos.finance_audit_events (tenant_id, correlation_id);

CREATE OR REPLACE FUNCTION ranchos.finance_audit_events_reject_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'finance audit events are append-only' USING ERRCODE = '42501';
END;
$$;
CREATE TRIGGER finance_audit_events_append_only
    BEFORE UPDATE OR DELETE ON ranchos.finance_audit_events
    FOR EACH ROW EXECUTE FUNCTION ranchos.finance_audit_events_reject_change();

-- updated_at triggers on mutable tables.
CREATE TRIGGER finance_domains_set_updated_at BEFORE UPDATE ON ranchos.finance_domains
    FOR EACH ROW EXECUTE FUNCTION ranchos.set_updated_at();
CREATE TRIGGER finance_accounts_set_updated_at BEFORE UPDATE ON ranchos.finance_accounts
    FOR EACH ROW EXECUTE FUNCTION ranchos.set_updated_at();
CREATE TRIGGER finance_categories_set_updated_at BEFORE UPDATE ON ranchos.finance_categories
    FOR EACH ROW EXECUTE FUNCTION ranchos.set_updated_at();
CREATE TRIGGER finance_transfers_set_updated_at BEFORE UPDATE ON ranchos.finance_transfers
    FOR EACH ROW EXECUTE FUNCTION ranchos.set_updated_at();
CREATE TRIGGER finance_transactions_set_updated_at BEFORE UPDATE ON ranchos.finance_transactions
    FOR EACH ROW EXECUTE FUNCTION ranchos.set_updated_at();

-- Seed personal/ranch/zero_g for the tenant selected in ranchos.tenant_id (idempotent).
-- Called by the migrator during tenant bootstrap; not executable by the runtime role.
CREATE OR REPLACE FUNCTION ranchos.finance_seed_domains()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    selected_tenant uuid := ranchos.require_uuid_setting('ranchos.tenant_id');
BEGIN
    INSERT INTO ranchos.finance_domains (tenant_id, code, name, sort_order)
    VALUES
        (selected_tenant, 'personal', 'Personal', 0),
        (selected_tenant, 'ranch', 'Ranch', 1),
        (selected_tenant, 'zero_g', 'Zero-G LLC', 2)
    ON CONFLICT (tenant_id, code) DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION ranchos.finance_seed_domains() FROM PUBLIC;

-- Row-level security ----------------------------------------------------------
ALTER TABLE ranchos.finance_domains ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_domains FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_categories FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_transfers FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_transactions FORCE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ranchos.finance_audit_events FORCE ROW LEVEL SECURITY;

CREATE POLICY finance_domains_tenant_isolation ON ranchos.finance_domains
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_accounts_tenant_isolation ON ranchos.finance_accounts
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_categories_tenant_isolation ON ranchos.finance_categories
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_transfers_tenant_isolation ON ranchos.finance_transfers
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_transactions_tenant_isolation ON ranchos.finance_transactions
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));
CREATE POLICY finance_audit_events_tenant_isolation ON ranchos.finance_audit_events
    USING (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'))
    WITH CHECK (tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id'));

-- Grants: Checkpoint 1 is read-only for the runtime, plus append-only audit -----
REVOKE ALL ON ranchos.finance_domains FROM PUBLIC;
REVOKE ALL ON ranchos.finance_accounts FROM PUBLIC;
REVOKE ALL ON ranchos.finance_categories FROM PUBLIC;
REVOKE ALL ON ranchos.finance_transfers FROM PUBLIC;
REVOKE ALL ON ranchos.finance_transactions FROM PUBLIC;
REVOKE ALL ON ranchos.finance_audit_events FROM PUBLIC;

GRANT SELECT ON ranchos.finance_domains, ranchos.finance_accounts, ranchos.finance_categories,
    ranchos.finance_transfers, ranchos.finance_transactions
    TO ranchos_dev_runtime;
GRANT INSERT ON ranchos.finance_audit_events TO ranchos_dev_runtime;

ALTER TABLE ranchos.finance_domains OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_accounts OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_categories OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_transfers OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_transactions OWNER TO ranchos_dev_migrator;
ALTER TABLE ranchos.finance_audit_events OWNER TO ranchos_dev_migrator;

DO $$
DECLARE
    table_name text;
    table_owner text;
    rls_enabled boolean;
    rls_forced boolean;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'finance_domains',
        'finance_accounts',
        'finance_categories',
        'finance_transfers',
        'finance_transactions',
        'finance_audit_events'
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
