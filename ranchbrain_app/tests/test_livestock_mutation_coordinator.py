from copy import deepcopy
from datetime import datetime, timedelta, timezone
from uuid import uuid4
import unittest

from ranchbrain.livestock_mutation_coordinator import (
    LivestockAnimalCreateRequest,
    LivestockMutationCoordinator,
    LivestockMutationError,
    LivestockMutationErrorCode,
    canonical_animal_create_digest,
)
from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import AnimalCreateCommandV1
from ranchbrain.livestock_write_repository import (
    ANIMAL_CREATE_OPERATION,
    LivestockAuditRecord,
    LivestockConfirmationRecord,
    LivestockWriteRepository,
)
from ranchbrain.tenancy import (
    Capability,
    Role,
    Tenant,
    TenantContextResolver,
    TenantMembership,
    User,
    VerifiedPrincipal,
)


NOW = datetime(2026, 9, 13, 18, 30, tzinfo=timezone.utc)
PRINCIPAL_A = "00000000-0000-0000-0000-000000000001"
USER_A = "00000000-0000-0000-0000-000000000011"
TENANT_A = "00000000-0000-0000-0000-0000000000a1"
TENANT_B = "00000000-0000-0000-0000-0000000000b2"
ANIMAL_A = "00000000-0000-0000-0000-000000000301"
CONFIRM_A = "00000000-0000-0000-0000-000000000308"


def principal(**overrides) -> VerifiedPrincipal:
    values = {
        "id": PRINCIPAL_A,
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
        users=[User(USER_A, PRINCIPAL_A)],
        tenants=[
            Tenant(TENANT_A, "a", "Tenant A"),
            Tenant(TENANT_B, "b", "Tenant B"),
        ],
        memberships=memberships
        or [
            TenantMembership(TENANT_A, USER_A, role),
            TenantMembership(TENANT_B, USER_A, Role.VIEWER),
        ],
    )


def provenance():
    return LivestockFactProvenance("fixture", ANIMAL_A, "fixture-v1", NOW)


def command(**overrides):
    values = {
        "id": ANIMAL_A,
        "display_name": "Juniper",
        "species_code": "cattle",
        "production_type_code": "beef",
        "breed_code": "angus",
        "provenance": provenance(),
    }
    values.update(overrides)
    return AnimalCreateCommandV1(**values)


def digest_for(cmd, confirmation_id=CONFIRM_A, identity="idem-a", tenant_id=TENANT_A):
    return canonical_animal_create_digest(
        tenant_id=tenant_id,
        command=cmd,
        confirmation_id=confirmation_id,
        idempotency_identity=identity,
        policy_version="policy-v1",
        validator_version="validator-v1",
    )


def confirmation(cmd=None, **overrides):
    cmd = cmd or command()
    issued = NOW - timedelta(seconds=30)
    values = {
        "id": CONFIRM_A,
        "tenant_id": TENANT_A,
        "actor_user_id": USER_A,
        "principal_id": PRINCIPAL_A,
        "operation": ANIMAL_CREATE_OPERATION,
        "target_manifest": cmd.id,
        "command_digest": digest_for(cmd),
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
        "idempotency_identity": "idem-a",
        "issued_at": issued,
        "expires_at": issued + timedelta(minutes=2),
        "consumed_at": None,
    }
    values.update(overrides)
    return LivestockConfirmationRecord(**values)


def request(cmd=None, **overrides):
    cmd = cmd or command()
    values = {
        "command": cmd,
        "confirmation": confirmation(cmd),
        "idempotency_identity": "idem-a",
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
    }
    values.update(overrides)
    return LivestockAnimalCreateRequest(**values)


class FakeSession:
    def __init__(self, *, now=NOW, fail_on=None, confirmation_row=None):
        self.now = now
        self.fail_on = fail_on
        self.events = []
        self.locals = None
        self.committed = False
        self.rolled_back = False
        self.confirmations = {}
        self.idempotency = {}
        self.animals = []
        self.audits = []
        self._snapshot = None
        if confirmation_row is not None:
            self.confirmations[confirmation_row.id] = confirmation_row

    def _key(self, tenant_id, scope, identity):
        return (tenant_id, scope, identity)

    def _snap(self):
        self._snapshot = {
            "confirmations": deepcopy(self.confirmations),
            "idempotency": deepcopy(self.idempotency),
            "animals": list(self.animals),
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

    def load_confirmation(self, confirmation_id):
        return self.confirmations.get(confirmation_id)

    def mark_confirmation_consumed(self, confirmation_id, consumed_at):
        self.events.append("consume_confirmation")
        if self.fail_on == "consume_confirmation":
            raise RuntimeError("forced consume failure")
        current = self.confirmations[confirmation_id]
        self.confirmations[confirmation_id] = LivestockConfirmationRecord(
            current.id,
            current.tenant_id,
            current.actor_user_id,
            current.principal_id,
            current.operation,
            current.target_manifest,
            current.command_digest,
            current.policy_version,
            current.validator_version,
            current.idempotency_identity,
            current.issued_at,
            current.expires_at,
            consumed_at,
        )

    def load_idempotency(self, tenant_id, scope, identity):
        return self.idempotency.get(self._key(tenant_id, scope, identity))

    def insert_idempotency_reservation(self, record):
        self.events.append("reserve_idempotency")
        self.idempotency[self._key(record.tenant_id, record.scope, record.identity)] = record

    def finalize_idempotency(self, record):
        self.events.append("finalize_idempotency")
        self.idempotency[self._key(record.tenant_id, record.scope, record.identity)] = record

    def insert_animal(self, animal):
        self.events.append("persist_animal")
        if self.fail_on == "persist_animal":
            raise RuntimeError("forced persist failure")
        self.animals.append(animal)

    def insert_audit(self, record: LivestockAuditRecord):
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
            self.confirmations = self._snapshot["confirmations"]
            self.idempotency = self._snapshot["idempotency"]
            self.animals = self._snapshot["animals"]
            self.audits = self._snapshot["audits"]


def coordinator(role=Role.MANAGER, memberships=None):
    return LivestockMutationCoordinator(resolver(role, memberships), LivestockWriteRepository())


class LivestockMutationCoordinatorTests(unittest.TestCase):
    def test_admission_rejects_missing_principal_and_missing_tenant(self):
        session = FakeSession()
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().create_animal(
                principal="not-a-principal",
                requested_tenant_id=TENANT_A,
                request=request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().create_animal(
                principal=principal(),
                requested_tenant_id=None,
                request=request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        self.assertEqual(session.events, [])

    def test_admission_rejects_non_uuid_and_non_canonical_principal_ids(self):
        session = FakeSession()
        for invalid_id in (
            "principal-a",
            PRINCIPAL_A.replace("-", ""),
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        ):
            with self.assertRaises(LivestockMutationError) as raised:
                coordinator().create_animal(
                    principal=principal(id=invalid_id),
                    requested_tenant_id=TENANT_A,
                    request=request(),
                    session=session,
                    now=NOW,
                )
            self.assertEqual(raised.exception.code, LivestockMutationErrorCode.PRINCIPAL_ID_INVALID)
        self.assertEqual(session.events, [])

    def test_admission_rejects_inactive_membership_and_wrong_capability(self):
        session = FakeSession()
        inactive = [
            TenantMembership(TENANT_A, USER_A, Role.MANAGER, status="inactive"),
            TenantMembership(TENANT_B, USER_A, Role.VIEWER),
        ]
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(memberships=inactive).create_animal(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.VIEWER).create_animal(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().create_animal(
                principal=principal(),
                requested_tenant_id=TENANT_B,
                request=request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        self.assertEqual(session.events, [])

    def test_first_write_rejects_expired_reused_wrong_ttl_and_unbound_stored_confirmation(self):
        expired = confirmation(issued_at=NOW - timedelta(minutes=3), expires_at=NOW - timedelta(minutes=1))
        reused = confirmation(consumed_at=NOW - timedelta(seconds=1))
        wrong_ttl = confirmation(expires_at=NOW + timedelta(minutes=10))
        unbound = confirmation(operation="ranchos.livestock.identifier-assign")
        for invalid in (expired, reused, wrong_ttl, unbound):
            session = FakeSession(confirmation_row=invalid)
            with self.assertRaises(LivestockMutationError) as raised:
                coordinator().create_animal(
                    principal=principal(),
                    requested_tenant_id=TENANT_A,
                    request=request(confirmation=invalid),
                    session=session,
                    now=NOW,
                )
            self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
            self.assertIn("rollback", session.events)
            self.assertFalse(session.committed)
            self.assertEqual(session.animals, [])
            self.assertEqual(session.audits, [])

    def test_successful_create_sets_local_context_then_persists_in_order(self):
        admitted = confirmation()
        session = FakeSession(confirmation_row=admitted)
        result = coordinator().create_animal(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.animal.display_name, "Juniper")
        self.assertEqual(result.animal.tenant_id, TENANT_A)
        self.assertEqual(result.animal.provenance.source_id, ANIMAL_A)
        self.assertEqual(
            session.locals,
            {"principal_id": PRINCIPAL_A, "environment": "development", "tenant_id": TENANT_A},
        )
        self.assertEqual(
            session.events,
            [
                "begin",
                "set_local",
                "current_timestamp",
                "reserve_idempotency",
                "consume_confirmation",
                "persist_animal",
                "insert_audit",
                "finalize_idempotency",
                "commit",
            ],
        )
        self.assertTrue(session.committed)
        self.assertFalse(session.rolled_back)
        self.assertEqual(session.confirmations[CONFIRM_A].consumed_at, NOW)
        self.assertEqual(session.audits[0].operation, "animal_create")
        self.assertEqual(len(session.audits), 1)

    def test_identical_replay_returns_original_without_second_consume(self):
        admitted = confirmation()
        session = FakeSession(confirmation_row=admitted)
        first = coordinator().create_animal(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        session.events.clear()
        replayed = coordinator().create_animal(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.animal.id, first.animal.id)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        self.assertEqual(session.events, ["begin", "set_local", "current_timestamp", "commit"])
        self.assertNotIn("consume_confirmation", session.events)
        self.assertNotIn("persist_animal", session.events)
        self.assertNotIn("insert_audit", session.events)
        self.assertEqual(len(session.animals), 1)
        self.assertEqual(len(session.audits), 1)

    def test_committed_identical_retry_after_expiry_replays_without_fresh_confirmation(self):
        admitted = confirmation()
        session = FakeSession(confirmation_row=admitted)
        first = coordinator().create_animal(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        expired_caller = confirmation(
            consumed_at=NOW,
            issued_at=NOW - timedelta(minutes=3),
            expires_at=NOW - timedelta(minutes=1),
        )
        session.events.clear()
        replayed = coordinator().create_animal(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=request(confirmation=expired_caller),
            session=session,
            now=NOW + timedelta(minutes=2),
        )
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.animal.id, first.animal.id)
        self.assertEqual(replayed.transaction_id, first.transaction_id)
        self.assertEqual(session.events, ["begin", "set_local", "current_timestamp", "commit"])
        self.assertNotIn("consume_confirmation", session.events)
        self.assertEqual(len(session.animals), 1)
        self.assertEqual(len(session.audits), 1)

    def test_first_write_expired_by_session_time_fails_even_if_caller_time_is_valid(self):
        admitted = confirmation()
        session = FakeSession(confirmation_row=admitted, now=NOW + timedelta(minutes=3))
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().create_animal(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=request(confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
        self.assertTrue(session.rolled_back)
        self.assertFalse(session.committed)
        self.assertIsNone(session.confirmations[CONFIRM_A].consumed_at)
        self.assertEqual(session.animals, [])
        self.assertEqual(session.audits, [])
        self.assertEqual(session.idempotency, {})

    def test_same_idempotency_identity_with_different_digest_conflicts(self):
        first_confirmation = confirmation()
        session = FakeSession(confirmation_row=first_confirmation)
        coordinator().create_animal(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=request(confirmation=first_confirmation),
            session=session,
            now=NOW,
        )
        other = command(display_name="Willow", id=str(uuid4()))
        other_confirmation_id = str(uuid4())
        other_confirmation = confirmation(
            other,
            id=other_confirmation_id,
            target_manifest=other.id,
            command_digest=digest_for(other, confirmation_id=other_confirmation_id),
        )
        session.confirmations[other_confirmation.id] = other_confirmation
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().create_animal(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=request(command=other, confirmation=other_confirmation),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.IDEMPOTENCY_CONFLICT)
        self.assertIn("rollback", session.events)
        self.assertEqual(len(session.animals), 1)

    def test_persist_failure_rolls_back_confirmation_animal_and_audit(self):
        admitted = confirmation()
        session = FakeSession(confirmation_row=admitted, fail_on="persist_animal")
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().create_animal(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=request(confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TRANSACTION_FAILED)
        self.assertTrue(session.rolled_back)
        self.assertFalse(session.committed)
        self.assertIsNone(session.confirmations[CONFIRM_A].consumed_at)
        self.assertEqual(session.animals, [])
        self.assertEqual(session.audits, [])
        self.assertEqual(session.idempotency, {})
        self.assertEqual(
            session.events,
            [
                "begin",
                "set_local",
                "current_timestamp",
                "reserve_idempotency",
                "consume_confirmation",
                "persist_animal",
                "rollback",
            ],
        )

    def test_repository_does_not_issue_set_or_reset(self):
        admitted = confirmation()
        session = FakeSession(confirmation_row=admitted)
        repository = LivestockWriteRepository()
        context = resolver().resolve(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            capability=Capability.LIVESTOCK_ANIMAL_WRITE,
            now=NOW,
        )
        repository.consume_confirmation(
            session,
            confirmation_id=admitted.id,
            context=context,
            digest=digest_for(command()),
            idempotency_identity="idem-a",
            target_manifest=ANIMAL_A,
            policy_version="policy-v1",
            validator_version="validator-v1",
            now=NOW,
        )
        self.assertNotIn("set_local", session.events)
        self.assertIsNone(session.locals)
