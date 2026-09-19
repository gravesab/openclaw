from copy import deepcopy
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import unittest

from ranchbrain.finance_model import (
    Account,
    AccountType,
    AllocationDomain,
    AllocationLink,
    AllocationTargetType,
    FinanceLedger,
    Interpretation,
    JournalEntry,
    JournalLine,
    SourceActivity,
    Split,
    expense_journal_from_splits,
    reverse_journal_lines,
    reverse_interpretation,
)
from ranchbrain.finance_mutation_coordinator import (
    FinanceAccountCreateRequest,
    FinanceInterpretationPostRequest,
    FinanceInterpretationReverseRequest,
    FinanceInterpretationSupersedeRequest,
    FinanceMutationCoordinator,
    FinanceMutationError,
    FinanceMutationErrorCode,
    FinanceSourceActivityRequest,
    FinanceSourceArtifactRequest,
    canonical_account_create_digest,
)
from ranchbrain.finance_write_repository import (
    ACCOUNT_CREATE_OPERATION,
    INTERPRETATION_POST_OPERATION,
    INTERPRETATION_REVERSE_OPERATION,
    INTERPRETATION_SUPERSEDE_OPERATION,
    FinanceAuditRecord,
    FinanceFactProvenance,
    FinanceIdempotencyRecord,
    FinanceWriteRepository,
    SourceArtifactRecord,
)
from ranchbrain.tenancy import (
    Role,
    Tenant,
    TenantContextResolver,
    TenantMembership,
    User,
    VerifiedPrincipal,
)


NOW = datetime(2026, 9, 17, 15, 30, tzinfo=timezone.utc)
PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
PRINCIPAL_B = "00000000-0000-0000-0000-000000000002"
PRINCIPAL_C = "00000000-0000-0000-0000-000000000003"
USER_A = "00000000-0000-0000-0000-000000000011"
USER_B = "00000000-0000-0000-0000-000000000012"
USER_C = "00000000-0000-0000-0000-000000000013"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
POLICY_VERSION = "policy-v1"
VALIDATOR_VERSION = "validator-v1"
ZERO = Decimal("0.00")


def principal(principal_id=PRINCIPAL_A, **overrides) -> VerifiedPrincipal:
    values = {
        "id": principal_id,
        "principal_type": "human",
        "environment": "development",
        "lifecycle_state": "active",
        "assurance_profile": "mfa-fresh",
        "session_reference": "session-a",
        "valid_from": NOW - timedelta(minutes=5),
        "valid_until": NOW + timedelta(minutes=5),
        "correlation_id": "request-a",
    }
    values.update(overrides)
    return VerifiedPrincipal(**values)


def resolver(role=Role.MANAGER, memberships=None):
    return TenantContextResolver(
        environment="development",
        users=[User(USER_A, PRINCIPAL_A), User(USER_B, PRINCIPAL_B), User(USER_C, PRINCIPAL_C)],
        tenants=[
            Tenant(TENANT_A, "a", "Tenant A"),
            Tenant(TENANT_B, "b", "Tenant B"),
        ],
        memberships=memberships
        or [
            TenantMembership(TENANT_A, USER_A, role),
            TenantMembership(TENANT_A, USER_C, Role.OWNER),
            TenantMembership(TENANT_B, USER_B, Role.OWNER),
        ],
    )


def provenance(source_id="acct-checking"):
    return FinanceFactProvenance("fixture", source_id, "fixture-v1", NOW)


def checking() -> Account:
    return Account("acct-checking", "BancFirst: Checking", AccountType.ASSET, "BancFirst")


def groceries() -> Account:
    return Account("acct-groceries", "Household: Groceries", AccountType.EXPENSE)


def grocery_split(amount: str = "-42.00") -> Split:
    return Split(
        Decimal(amount),
        "acct-groceries",
        AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.NONE),
    )


def activity(amount: str = "-42.00") -> SourceActivity:
    return SourceActivity("activity-1", "acct-checking", NOW, "Neighborhood grocery", Decimal(amount))


def posted_interpretation(interpretation_id="interp-1", journal_id="journal-1", splits=None, supersedes_id=None):
    chosen = splits if splits is not None else (grocery_split(),)
    return Interpretation(
        interpretation_id,
        "activity-1",
        chosen,
        expense_journal_from_splits(journal_id, NOW, "acct-checking", chosen),
        supersedes_id=supersedes_id,
    )


def account_request(account=None, identity="idem-account"):
    account = account or checking()
    return FinanceAccountCreateRequest(account, provenance(account.id), identity, POLICY_VERSION, VALIDATOR_VERSION)


def coordinator(role=Role.MANAGER, memberships=None):
    return FinanceMutationCoordinator(resolver(role, memberships), FinanceWriteRepository())


class PgUniqueViolation(Exception):
    pgcode = "23505"


class FakeSession:
    def __init__(self, *, now=NOW, fail_on=None, accounts=None, artifacts=None, activities=None, interpretations=None):
        self.now = now
        self.fail_on = fail_on
        self.events = []
        self.locals = None
        self.committed = False
        self.rolled_back = False
        self.idempotency = {}
        self.accounts = list(accounts or [])
        self.artifacts = list(artifacts or [])
        self.activities = list(activities or [])
        self.journals = []
        self.lines = []
        self.interpretations = list(interpretations or [])
        self.splits = []
        self.audits = []
        self._snapshot = None

    def _key(self, tenant_id, scope, identity):
        return (tenant_id, scope, identity)

    def _snap(self):
        self._snapshot = {
            "idempotency": deepcopy(self.idempotency),
            "accounts": list(self.accounts),
            "artifacts": list(self.artifacts),
            "activities": list(self.activities),
            "journals": list(self.journals),
            "lines": list(self.lines),
            "interpretations": list(self.interpretations),
            "splits": list(self.splits),
            "audits": list(self.audits),
        }

    def begin(self):
        self.events.append("begin")
        self._snap()

    def set_local(self, *, principal_id, environment, tenant_id):
        self.events.append("set_local")
        self.locals = {"principal_id": principal_id, "environment": environment, "tenant_id": tenant_id}

    def current_timestamp(self):
        self.events.append("current_timestamp")
        return self.now

    def load_idempotency(self, tenant_id, scope, identity):
        return self.idempotency.get(self._key(tenant_id, scope, identity))

    def insert_idempotency_reservation(self, record):
        self.events.append("reserve_idempotency")
        self.idempotency[self._key(record.tenant_id, record.scope, record.identity)] = record
        return True

    def finalize_idempotency(self, record):
        self.events.append("finalize_idempotency")
        self.idempotency[self._key(record.tenant_id, record.scope, record.identity)] = record

    def insert_account(self, *, tenant_id, account, provenance, created_by_user_id, created_at):
        self.events.append("persist_account")
        if self.fail_on == "persist_account":
            raise RuntimeError("forced persist failure")
        self.accounts.append((tenant_id, account))

    def lock_account(self, tenant_id, account_id):
        self.events.append("lock_account")
        for stored_tenant, account in self.accounts:
            if stored_tenant == tenant_id and account.id == account_id:
                return account
        return None

    def insert_artifact(self, *, tenant_id, artifact, provenance, created_by_user_id, created_at):
        self.events.append("persist_artifact")
        self.artifacts.append((tenant_id, artifact))

    def lock_artifact(self, tenant_id, artifact_id):
        self.events.append("lock_artifact")
        for stored_tenant, artifact in self.artifacts:
            if stored_tenant == tenant_id and artifact.id == artifact_id:
                return artifact
        return None

    def insert_activity(self, *, tenant_id, activity, artifact_id, provenance, created_by_user_id, created_at):
        self.events.append("persist_activity")
        self.activities.append((tenant_id, activity))

    def lock_activity(self, tenant_id, activity_id):
        self.events.append("lock_activity")
        for stored_tenant, activity in self.activities:
            if stored_tenant == tenant_id and activity.id == activity_id:
                return activity
        return None

    def load_ledger(self, tenant_id):
        self.events.append("load_ledger")
        return FinanceLedger(
            tuple(account for stored_tenant, account in self.accounts if stored_tenant == tenant_id),
            tuple(activity for stored_tenant, activity in self.activities if stored_tenant == tenant_id),
            tuple(item for stored_tenant, item in self.interpretations if stored_tenant == tenant_id),
        )

    def insert_journal_entry(self, *, tenant_id, journal_id, recorded_at, reverses_journal_id, created_by_user_id, created_at):
        self.events.append("persist_journal")
        if reverses_journal_id is not None:
            for stored_tenant, _stored_id, stored_reverses in self.journals:
                if stored_tenant == tenant_id and stored_reverses == reverses_journal_id:
                    raise PgUniqueViolation("duplicate reversal journal")
        self.journals.append((tenant_id, journal_id, reverses_journal_id))

    def insert_journal_line(self, *, tenant_id, journal_id, line_no, account_id, debit, credit):
        self.lines.append((tenant_id, journal_id, line_no, account_id, debit, credit))

    def insert_interpretation(self, *, tenant_id, interpretation, created_by_user_id, created_at):
        self.events.append("persist_interpretation")
        if self.fail_on == "persist_interpretation":
            raise RuntimeError("forced persist failure")
        if interpretation.reverses_id is not None:
            for stored_tenant, stored in self.interpretations:
                if stored_tenant == tenant_id and stored.reverses_id == interpretation.reverses_id:
                    raise PgUniqueViolation("duplicate reversal")
        if interpretation.supersedes_id is not None:
            for stored_tenant, stored in self.interpretations:
                if stored_tenant == tenant_id and stored.supersedes_id == interpretation.supersedes_id:
                    raise PgUniqueViolation("duplicate supersession")
        self.interpretations.append((tenant_id, interpretation))

    def insert_split(self, *, tenant_id, interpretation_id, split_no, amount, destination_account_id, allocation_domain, allocation_target_type, allocation_target_id):
        self.splits.append((tenant_id, interpretation_id, split_no, amount, destination_account_id))

    def insert_audit(self, record: FinanceAuditRecord):
        self.events.append("insert_audit")
        self.audits.append(record)

    def commit(self):
        self.events.append("commit")
        self.committed = True
        self._snapshot = None

    def rollback(self):
        self.events.append("rollback")
        self.rolled_back = True
        if self._snapshot is not None:
            self.idempotency = self._snapshot["idempotency"]
            self.accounts = self._snapshot["accounts"]
            self.artifacts = self._snapshot["artifacts"]
            self.activities = self._snapshot["activities"]
            self.journals = self._snapshot["journals"]
            self.lines = self._snapshot["lines"]
            self.interpretations = self._snapshot["interpretations"]
            self.splits = self._snapshot["splits"]
            self.audits = self._snapshot["audits"]


class FinanceMutationCoordinatorTests(unittest.TestCase):
    def test_admission_rejects_missing_principal_and_missing_tenant(self):
        session = FakeSession()
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().create_account(
                principal="not-a-principal",
                requested_tenant_id=TENANT_A,
                request=account_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().create_account(
                principal=principal(),
                requested_tenant_id=None,
                request=account_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.ADMISSION_DENIED)
        self.assertEqual(session.events, [])

    def test_admission_rejects_viewer_chart_write_and_manager_correction(self):
        session = FakeSession()
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator(Role.VIEWER).create_account(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=account_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator(Role.MANAGER).reverse_interpretation(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=FinanceInterpretationReverseRequest(
                    "interp-1",
                    "interp-reverse",
                    provenance("interp-1"),
                    "idem-reverse",
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                ),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.ADMISSION_DENIED)

    def test_create_account_commits_audit_and_idempotency(self):
        session = FakeSession()
        result = coordinator().create_account(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=account_request(),
            session=session,
            now=NOW,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.account.id, "acct-checking")
        self.assertEqual(result.idempotency_outcome, "committed")
        self.assertEqual(session.locals["tenant_id"], TENANT_A)
        self.assertEqual(len(session.accounts), 1)
        self.assertEqual(len(session.audits), 1)
        self.assertEqual(session.audits[0].operation, ACCOUNT_CREATE_OPERATION)
        record = session.idempotency[(TENANT_A, ACCOUNT_CREATE_OPERATION, "idem-account")]
        self.assertEqual(record.outcome, "committed")
        self.assertEqual(record.result_account_id, "acct-checking")
        self.assertEqual(
            session.events,
            [
                "begin",
                "set_local",
                "current_timestamp",
                "reserve_idempotency",
                "persist_account",
                "insert_audit",
                "finalize_idempotency",
                "commit",
            ],
        )

    def test_exact_account_replay_does_not_persist_or_audit_again(self):
        session = FakeSession()
        first = coordinator().create_account(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=account_request(),
            session=session,
            now=NOW,
        )
        replayed = coordinator().create_account(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=account_request(),
            session=session,
            now=NOW,
        )
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        self.assertEqual(len(session.accounts), 1)
        self.assertEqual(len(session.audits), 1)

    def test_idempotency_conflict_rolls_back(self):
        session = FakeSession()
        coordinator().create_account(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=account_request(),
            session=session,
            now=NOW,
        )
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().create_account(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=account_request(Account("acct-savings", "Savings", AccountType.ASSET)),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.IDEMPOTENCY_CONFLICT)
        self.assertTrue(session.rolled_back)
        self.assertEqual(len(session.accounts), 1)

    def test_persist_failure_rolls_back_without_audit(self):
        session = FakeSession(fail_on="persist_account")
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().create_account(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=account_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.TRANSACTION_FAILED)
        self.assertTrue(session.rolled_back)
        self.assertEqual(session.accounts, [])
        self.assertEqual(session.audits, [])

    def test_source_artifact_and_activity_require_existing_account(self):
        session = FakeSession()
        coordinator().create_account(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=account_request(),
            session=session,
            now=NOW,
        )
        artifact = SourceArtifactRecord(
            "artifact-1",
            "statement_csv",
            "a.csv",
            "digest-a",
            "text/csv",
            12,
            "parser-v1",
            account_id="acct-checking",
        )
        recorded = coordinator().record_source_artifact(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=FinanceSourceArtifactRequest(artifact, provenance("artifact-1"), "idem-artifact", POLICY_VERSION, VALIDATOR_VERSION),
            session=session,
            now=NOW,
        )
        self.assertEqual(recorded.artifact.id, "artifact-1")
        activity_result = coordinator().record_source_activity(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=FinanceSourceActivityRequest(activity(), provenance("activity-1"), "idem-activity", POLICY_VERSION, VALIDATOR_VERSION, "artifact-1"),
            session=session,
            now=NOW,
        )
        self.assertEqual(activity_result.activity.id, "activity-1")
        empty = FakeSession()
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().record_source_activity(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=FinanceSourceActivityRequest(activity(), provenance("activity-1"), "idem-missing", POLICY_VERSION, VALIDATOR_VERSION),
                session=empty,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.TARGET_NOT_FOUND)

    def test_post_interpretation_validates_journal_split_integrity_before_persist(self):
        session = FakeSession(accounts=[(TENANT_A, checking()), (TENANT_A, groceries())], activities=[(TENANT_A, activity())])
        invalid = Interpretation(
            "interp-bad",
            "activity-1",
            (grocery_split(),),
            JournalEntry(
                "journal-bad",
                NOW,
                (
                    JournalLine("acct-groceries", Decimal("10.00"), ZERO),
                    JournalLine("acct-checking", ZERO, Decimal("10.00")),
                ),
            ),
        )
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().post_interpretation(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=FinanceInterpretationPostRequest(invalid, provenance("interp-bad"), "idem-bad", POLICY_VERSION, VALIDATOR_VERSION),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.INVALID)
        self.assertEqual(session.interpretations, [])
        posted = posted_interpretation()
        result = coordinator().post_interpretation(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationPostRequest(posted, provenance("interp-1"), "idem-post", POLICY_VERSION, VALIDATOR_VERSION),
            session=session,
            now=NOW,
        )
        self.assertEqual(result.interpretation.id, "interp-1")
        self.assertEqual(len(session.splits), 1)
        self.assertEqual(session.audits[-1].operation, INTERPRETATION_POST_OPERATION)

    def test_post_interpretation_rejects_correction_payloads(self):
        original = posted_interpretation()
        session = FakeSession(
            accounts=[(TENANT_A, checking()), (TENANT_A, groceries())],
            activities=[(TENANT_A, activity())],
            interpretations=[(TENANT_A, original)],
        )
        reversal = reverse_interpretation((original,), original.id, "interp-reversal", NOW)
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator(Role.MANAGER).post_interpretation(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=FinanceInterpretationPostRequest(
                    reversal, provenance(reversal.id), "idem-reversal", POLICY_VERSION, VALIDATOR_VERSION
                ),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.INVALID_CORRECTION)
        self.assertFalse(session.committed)

    def test_owner_reverse_inverts_full_journal_lines(self):
        posted = posted_interpretation()
        session = FakeSession(
            accounts=[(TENANT_A, checking()), (TENANT_A, groceries())],
            activities=[(TENANT_A, activity())],
            interpretations=[(TENANT_A, posted)],
        )
        result = coordinator(Role.OWNER).reverse_interpretation(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationReverseRequest(
                "interp-1",
                "interp-reverse",
                provenance("interp-reverse"),
                "idem-reverse",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=session,
            now=NOW,
        )
        self.assertEqual(result.interpretation.reverses_id, "interp-1")
        self.assertEqual(result.interpretation.splits, ())
        self.assertEqual(result.interpretation.journal_entry.lines, reverse_journal_lines(posted.journal_entry.lines))
        self.assertEqual(session.audits[-1].operation, INTERPRETATION_REVERSE_OPERATION)

    def test_second_owner_can_supersede_and_persists_paired_reversal(self):
        posted = posted_interpretation()
        replacement = posted_interpretation("interp-2", "journal-2", (grocery_split("-20.00"), grocery_split("-22.00")), "interp-1")
        session = FakeSession(
            accounts=[(TENANT_A, checking()), (TENANT_A, groceries())],
            activities=[(TENANT_A, activity())],
            interpretations=[(TENANT_A, posted)],
        )
        result = coordinator(
            Role.OWNER,
            [
                TenantMembership(TENANT_A, USER_A, Role.OWNER),
                TenantMembership(TENANT_A, USER_C, Role.OWNER),
                TenantMembership(TENANT_B, USER_B, Role.OWNER),
            ],
        ).supersede_interpretation(
            principal=principal(PRINCIPAL_C, correlation_id="request-c"),
            requested_tenant_id=TENANT_A,
            request=FinanceInterpretationSupersedeRequest(
                replacement,
                provenance("interp-2"),
                "idem-supersede",
                POLICY_VERSION,
                VALIDATOR_VERSION,
            ),
            session=session,
            now=NOW,
        )
        self.assertEqual(result.interpretation.id, "interp-2")
        persisted_ids = [item.id for _, item in session.interpretations]
        self.assertEqual(persisted_ids, ["interp-1", "reverse-interp-2", "interp-2"])
        reversal = session.interpretations[1][1]
        self.assertEqual(reversal.reverses_id, "interp-1")
        self.assertEqual(reversal.journal_entry.lines, reverse_journal_lines(posted.journal_entry.lines))
        self.assertEqual(session.audits[-1].operation, INTERPRETATION_SUPERSEDE_OPERATION)

    def test_digest_includes_tenant_and_rejects_cross_tenant_workspace(self):
        digest = canonical_account_create_digest(
            tenant_id=TENANT_A,
            account=checking(),
            provenance=provenance(),
            idempotency_identity="idem-account",
            policy_version=POLICY_VERSION,
            validator_version=VALIDATOR_VERSION,
        )
        other = canonical_account_create_digest(
            tenant_id=TENANT_B,
            account=checking(),
            provenance=provenance(),
            idempotency_identity="idem-account",
            policy_version=POLICY_VERSION,
            validator_version=VALIDATOR_VERSION,
        )
        self.assertNotEqual(digest, other)
        session = FakeSession()
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().create_account(
                principal=principal(),
                requested_tenant_id=TENANT_B,
                request=account_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.ADMISSION_DENIED)

    def test_concurrent_unique_conflicts_return_typed_outcomes(self):
        account = checking()
        digest = canonical_account_create_digest(
            tenant_id=TENANT_A,
            account=account,
            provenance=provenance(account.id),
            idempotency_identity="idem-account",
            policy_version=POLICY_VERSION,
            validator_version=VALIDATOR_VERSION,
        )
        committed = FinanceIdempotencyRecord(
            TENANT_A,
            ACCOUNT_CREATE_OPERATION,
            "idem-account",
            digest,
            ACCOUNT_CREATE_OPERATION,
            "committed",
            "tx-replay",
            result_account_id=account.id,
            account=account,
        )
        replay_session = _ConcurrentIdempotencySession(committed, accounts=[(TENANT_A, account)])
        replayed = coordinator().create_account(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=account_request(),
            session=replay_session,
            now=NOW,
        )
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.transaction_id, "tx-replay")
        self.assertEqual(replayed.idempotency_outcome, "replayed")

        conflicting = FinanceIdempotencyRecord(
            TENANT_A,
            ACCOUNT_CREATE_OPERATION,
            "idem-account",
            "other-digest",
            ACCOUNT_CREATE_OPERATION,
            "committed",
            "tx-conflict",
            result_account_id=account.id,
            account=account,
        )
        conflict_session = _ConcurrentIdempotencySession(conflicting, accounts=[(TENANT_A, account)])
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator().create_account(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=account_request(),
                session=conflict_session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.IDEMPOTENCY_CONFLICT)
        self.assertTrue(conflict_session.rolled_back)

        posted = posted_interpretation()
        existing_reversal = reverse_interpretation((posted,), "interp-1", "interp-reverse", NOW)
        correction_session = _StaleLedgerSession(
            accounts=[(TENANT_A, checking()), (TENANT_A, groceries())],
            activities=[(TENANT_A, activity())],
            interpretations=[(TENANT_A, posted), (TENANT_A, existing_reversal)],
        )
        correction_session.journals.append(
            (TENANT_A, existing_reversal.journal_entry.id, posted.journal_entry.id)
        )
        with self.assertRaises(FinanceMutationError) as raised:
            coordinator(Role.OWNER).reverse_interpretation(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=FinanceInterpretationReverseRequest(
                    "interp-1",
                    "interp-reverse-2",
                    provenance("interp-reverse-2"),
                    "idem-reverse-2",
                    POLICY_VERSION,
                    VALIDATOR_VERSION,
                ),
                session=correction_session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, FinanceMutationErrorCode.INVALID_CORRECTION)
        self.assertTrue(correction_session.rolled_back)


class _ConcurrentIdempotencySession(FakeSession):
    def __init__(self, hidden_record, **kwargs):
        super().__init__(**kwargs)
        self._hidden_record = hidden_record
        self._loads = 0

    def load_idempotency(self, tenant_id, scope, identity):
        self._loads += 1
        if self._loads == 1:
            return None
        return self._hidden_record

    def insert_idempotency_reservation(self, record):
        self.events.append("reserve_idempotency")
        return False


class _StaleLedgerSession(FakeSession):
    def load_ledger(self, tenant_id):
        self.events.append("load_ledger")
        return FinanceLedger(
            tuple(account for stored_tenant, account in self.accounts if stored_tenant == tenant_id),
            tuple(activity for stored_tenant, activity in self.activities if stored_tenant == tenant_id),
            tuple(
                item
                for stored_tenant, item in self.interpretations
                if stored_tenant == tenant_id and item.reverses_id is None
            ),
        )


if __name__ == "__main__":
    unittest.main()
