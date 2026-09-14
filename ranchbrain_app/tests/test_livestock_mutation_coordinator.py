from copy import deepcopy
from datetime import datetime, timedelta, timezone
from uuid import uuid4
import unittest

from ranchbrain.livestock_mutation_coordinator import (
    LivestockAnimalCreateRequest,
    LivestockIdentifierAssignRequest,
    LivestockIdentifierRetireRequest,
    LivestockLifecycleCorrectRequest,
    LivestockLifecycleRecordRequest,
    LivestockMutationCoordinator,
    LivestockMutationError,
    LivestockMutationErrorCode,
    canonical_animal_create_digest,
    canonical_identifier_assign_digest,
    canonical_identifier_retire_digest,
    canonical_lifecycle_correct_digest,
    canonical_lifecycle_record_digest,
)
from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import (
    AnimalCreateCommandV1,
    AnimalIdentifierType,
    IdentifierAssignCommandV1,
    IdentifierRetireCommandV1,
    IdentifierRetirementReason,
    LifecycleCorrectionConfirmationV1,
    LifecycleCorrectionReason,
    RoutineLifecycleEventCommandV1,
    RoutineLifecycleEventType,
    assign_identifier as assign_identifier_model,
    create_animal,
    record_routine_lifecycle_event,
)
from ranchbrain.livestock_write_repository import (
    ANIMAL_CREATE_OPERATION,
    IDENTIFIER_ASSIGN_OPERATION,
    IDENTIFIER_RETIRE_OPERATION,
    LIFECYCLE_CORRECT_OPERATION,
    LIFECYCLE_RECORD_OPERATION,
    LivestockAuditRecord,
    LivestockConfirmationRecord,
    LivestockPersistenceError,
    LivestockPersistenceErrorCode,
    LivestockWriteRepository,
)
from ranchbrain.tenancy import (
    Capability,
    Role,
    Tenant,
    TenantContext,
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
IDENTIFIER_A = "00000000-0000-0000-0000-000000000401"
IDENTIFIER_B = "00000000-0000-0000-0000-000000000402"
RETIREMENT_A = "00000000-0000-0000-0000-000000000501"
EVENT_A = "00000000-0000-0000-0000-000000000601"
EVENT_B = "00000000-0000-0000-0000-000000000602"
CONFIRM_A = "00000000-0000-0000-0000-000000000308"
CONFIRM_I = "00000000-0000-0000-0000-000000000408"
CONFIRM_R = "00000000-0000-0000-0000-000000000508"
CONFIRM_L = "00000000-0000-0000-0000-000000000608"
CONFIRM_C = "00000000-0000-0000-0000-000000000708"


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
    def __init__(self, *, now=NOW, fail_on=None, confirmation_row=None, animals=None, identifiers=None, retirements=None, events=None):
        self.now = now
        self.fail_on = fail_on
        self.events = []
        self.locals = None
        self.committed = False
        self.rolled_back = False
        self.confirmations = {}
        self.idempotency = {}
        self.animals = list(animals or [])
        self.identifiers = list(identifiers or [])
        self.retirements = list(retirements or [])
        self.lifecycle_events = list(events or [])
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
            "identifiers": list(self.identifiers),
            "retirements": list(self.retirements),
            "lifecycle_events": list(self.lifecycle_events),
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

    def lock_animal(self, tenant_id, animal_id):
        self.events.append("lock_animal")
        return next((animal for animal in self.animals if animal.tenant_id == tenant_id and animal.id == animal_id), None)

    def lock_identifier(self, tenant_id, identifier_id):
        self.events.append("lock_identifier")
        return next(
            (identifier for identifier in self.identifiers if identifier.tenant_id == tenant_id and identifier.id == identifier_id),
            None,
        )

    def lock_active_identifier_slot(self, tenant_id, identifier_type, normalized_value):
        self.events.append("lock_active_identifier_slot")

    def load_identifiers_for_collision(self, tenant_id, identifier_type, normalized_value):
        return tuple(
            identifier
            for identifier in self.identifiers
            if identifier.tenant_id == tenant_id
            and identifier.identifier_type is identifier_type
            and identifier.normalized_value == normalized_value
        )

    def load_retirements_for_identifiers(self, tenant_id, identifier_ids):
        wanted = set(identifier_ids)
        return tuple(
            retirement
            for retirement in self.retirements
            if retirement.tenant_id == tenant_id and retirement.identifier_id in wanted
        )

    def insert_identifier(self, identifier):
        self.events.append("persist_identifier")
        if self.fail_on == "persist_identifier":
            raise RuntimeError("forced persist failure")
        collision = any(
            existing.tenant_id == identifier.tenant_id
            and existing.identifier_type is identifier.identifier_type
            and existing.normalized_value == identifier.normalized_value
            and existing.id != identifier.id
            and existing.id not in {retirement.identifier_id for retirement in self.retirements}
            for existing in self.identifiers
        )
        if collision:
            raise LivestockPersistenceError(
                "identifier value is already active in this tenant",
                LivestockPersistenceErrorCode.IDENTIFIER_NOT_AVAILABLE,
            )
        self.identifiers.append(identifier)

    def insert_retirement(self, retirement):
        self.events.append("persist_retirement")
        if self.fail_on == "persist_retirement":
            raise RuntimeError("forced persist failure")
        if any(
            existing.tenant_id == retirement.tenant_id and existing.identifier_id == retirement.identifier_id
            for existing in self.retirements
        ):
            raise LivestockPersistenceError("identifier is already retired", LivestockPersistenceErrorCode.IDENTIFIER_INVALID)
        self.retirements.append(retirement)

    def lock_lifecycle_animal_history(self, tenant_id, animal_id):
        self.events.append("lock_lifecycle_animal_history")

    def load_lifecycle_events_for_animal(self, tenant_id, animal_id):
        return tuple(
            event
            for event in self.lifecycle_events
            if event.tenant_id == tenant_id and event.animal_id == animal_id
        )

    def insert_lifecycle_event(self, event):
        self.events.append("persist_lifecycle")
        if self.fail_on == "persist_lifecycle":
            raise RuntimeError("forced persist failure")
        if event.supersedes_event_id is not None and any(
            existing.tenant_id == event.tenant_id and existing.supersedes_event_id == event.supersedes_event_id
            for existing in self.lifecycle_events
        ):
            raise LivestockPersistenceError("lifecycle event is already superseded", LivestockPersistenceErrorCode.LIFECYCLE_INVALID)
        self.lifecycle_events.append(event)

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
            self.identifiers = self._snapshot["identifiers"]
            self.retirements = self._snapshot["retirements"]
            self.lifecycle_events = self._snapshot["lifecycle_events"]
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
        self.assertEqual(session.audits[0].operation, ANIMAL_CREATE_OPERATION)
        self.assertEqual(len(session.audits), 1)
        finalized = session.idempotency[(TENANT_A, ANIMAL_CREATE_OPERATION, "idem-a")]
        self.assertEqual(finalized.operation, ANIMAL_CREATE_OPERATION)
        self.assertEqual(finalized.outcome, "committed")
        self.assertEqual(finalized.result_animal_id, ANIMAL_A)
        self.assertEqual(finalized.animal.id, ANIMAL_A)

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
            operation=ANIMAL_CREATE_OPERATION,
        )
        self.assertNotIn("set_local", session.events)
        self.assertIsNone(session.locals)


def animal_row(tenant_id=TENANT_A):
    return create_animal(
        TenantContext(tenant_id, USER_A, PRINCIPAL_A, Role.MANAGER, "development", "request-a"),
        command(),
        NOW,
    )


def identifier_provenance(source_id=IDENTIFIER_A):
    return LivestockFactProvenance("fixture", source_id, "fixture-v1", NOW)


def assign_command(**overrides):
    values = {
        "id": IDENTIFIER_A,
        "animal_id": ANIMAL_A,
        "identifier_type": AnimalIdentifierType.EAR_TAG,
        "normalized_value": "RB-104",
        "effective_at": NOW,
        "provenance": identifier_provenance(),
    }
    values.update(overrides)
    return IdentifierAssignCommandV1(**values)


def retire_command(**overrides):
    values = {
        "id": RETIREMENT_A,
        "identifier_id": IDENTIFIER_A,
        "reason": IdentifierRetirementReason.REPLACED,
        "retired_at": NOW + timedelta(minutes=1),
        "provenance": identifier_provenance(RETIREMENT_A),
    }
    values.update(overrides)
    return IdentifierRetireCommandV1(**values)


def assign_digest(cmd, confirmation_id=CONFIRM_I, identity="idem-i", tenant_id=TENANT_A):
    return canonical_identifier_assign_digest(
        tenant_id=tenant_id,
        command=cmd,
        confirmation_id=confirmation_id,
        idempotency_identity=identity,
        policy_version="policy-v1",
        validator_version="validator-v1",
    )


def retire_digest(cmd, confirmation_id=CONFIRM_R, identity="idem-r", tenant_id=TENANT_A):
    return canonical_identifier_retire_digest(
        tenant_id=tenant_id,
        command=cmd,
        confirmation_id=confirmation_id,
        idempotency_identity=identity,
        policy_version="policy-v1",
        validator_version="validator-v1",
    )


def assign_confirmation(cmd=None, **overrides):
    cmd = cmd or assign_command()
    issued = NOW - timedelta(seconds=30)
    values = {
        "id": CONFIRM_I,
        "tenant_id": TENANT_A,
        "actor_user_id": USER_A,
        "principal_id": PRINCIPAL_A,
        "operation": IDENTIFIER_ASSIGN_OPERATION,
        "target_manifest": cmd.id,
        "command_digest": assign_digest(cmd),
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
        "idempotency_identity": "idem-i",
        "issued_at": issued,
        "expires_at": issued + timedelta(minutes=2),
        "consumed_at": None,
    }
    values.update(overrides)
    return LivestockConfirmationRecord(**values)


def retire_confirmation(cmd=None, **overrides):
    cmd = cmd or retire_command()
    issued = NOW - timedelta(seconds=30)
    values = {
        "id": CONFIRM_R,
        "tenant_id": TENANT_A,
        "actor_user_id": USER_A,
        "principal_id": PRINCIPAL_A,
        "operation": IDENTIFIER_RETIRE_OPERATION,
        "target_manifest": cmd.identifier_id,
        "command_digest": retire_digest(cmd),
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
        "idempotency_identity": "idem-r",
        "issued_at": issued,
        "expires_at": issued + timedelta(minutes=2),
        "consumed_at": None,
    }
    values.update(overrides)
    return LivestockConfirmationRecord(**values)


def assign_request(cmd=None, **overrides):
    cmd = cmd or assign_command()
    values = {
        "command": cmd,
        "confirmation": assign_confirmation(cmd),
        "idempotency_identity": "idem-i",
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
    }
    values.update(overrides)
    return LivestockIdentifierAssignRequest(**values)


def retire_request(cmd=None, **overrides):
    cmd = cmd or retire_command()
    values = {
        "command": cmd,
        "confirmation": retire_confirmation(cmd),
        "idempotency_identity": "idem-r",
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
    }
    values.update(overrides)
    return LivestockIdentifierRetireRequest(**values)


def identifier_row(tenant_id=TENANT_A, identifier_id=IDENTIFIER_A, value="RB-104"):
    context = TenantContext(tenant_id, USER_A, PRINCIPAL_A, Role.MANAGER, "development", "request-a")
    return assign_identifier_model(context, assign_command(id=identifier_id, normalized_value=value), (), (), NOW)


class LivestockIdentifierMutationCoordinatorTests(unittest.TestCase):
    def test_admission_rejects_missing_principal_tenant_and_non_uuid(self):
        session = FakeSession(animals=[animal_row()])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().assign_identifier(
                principal="not-a-principal",
                requested_tenant_id=TENANT_A,
                request=assign_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().retire_identifier(
                principal=principal(),
                requested_tenant_id=None,
                request=retire_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().assign_identifier(
                principal=principal(id=PRINCIPAL_A.replace("-", "")),
                requested_tenant_id=TENANT_A,
                request=assign_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.PRINCIPAL_ID_INVALID)
        self.assertEqual(session.events, [])

    def test_admission_rejects_viewer_and_inactive_membership(self):
        session = FakeSession(animals=[animal_row()])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.VIEWER).assign_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=assign_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        inactive = [
            TenantMembership(TENANT_A, USER_A, Role.MANAGER, status="inactive"),
            TenantMembership(TENANT_B, USER_A, Role.VIEWER),
        ]
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(memberships=inactive).retire_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=retire_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        self.assertEqual(session.events, [])

    def test_first_write_rejects_expired_used_unbound_and_wrong_matrix_id(self):
        expired = assign_confirmation(issued_at=NOW - timedelta(minutes=3), expires_at=NOW - timedelta(minutes=1))
        reused = assign_confirmation(consumed_at=NOW - timedelta(seconds=1))
        unbound = assign_confirmation(command_digest="not-the-canonical-digest")
        wrong_op = assign_confirmation(operation=ANIMAL_CREATE_OPERATION)
        for invalid in (expired, reused, unbound, wrong_op):
            session = FakeSession(confirmation_row=invalid, animals=[animal_row()])
            with self.assertRaises(LivestockMutationError) as raised:
                coordinator().assign_identifier(
                    principal=principal(),
                    requested_tenant_id=TENANT_A,
                    request=assign_request(confirmation=invalid),
                    session=session,
                    now=NOW,
                )
            self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
            self.assertIn("rollback", session.events)
            self.assertFalse(session.committed)
            self.assertEqual(session.identifiers, [])
            self.assertEqual(session.audits, [])

    def test_successful_assign_locks_animal_then_persists_in_order(self):
        admitted = assign_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()])
        result = coordinator().assign_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=assign_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.identifier.id, IDENTIFIER_A)
        self.assertEqual(result.identifier.normalized_value, "RB-104")
        self.assertEqual(
            session.events,
            [
                "begin",
                "set_local",
                "current_timestamp",
                "reserve_idempotency",
                "consume_confirmation",
                "lock_animal",
                "lock_active_identifier_slot",
                "persist_identifier",
                "insert_audit",
                "finalize_idempotency",
                "commit",
            ],
        )
        finalized = session.idempotency[(TENANT_A, IDENTIFIER_ASSIGN_OPERATION, "idem-i")]
        self.assertEqual(finalized.result_identifier_id, IDENTIFIER_A)
        self.assertIsNone(finalized.result_animal_id)
        self.assertEqual(session.audits[0].operation, IDENTIFIER_ASSIGN_OPERATION)

    def test_successful_retire_locks_identifier_then_persists_in_order(self):
        admitted = retire_confirmation()
        assigned = identifier_row()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()], identifiers=[assigned])
        result = coordinator().retire_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=retire_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.retirement.id, RETIREMENT_A)
        self.assertEqual(result.retirement.provenance.source_id, RETIREMENT_A)
        self.assertEqual(
            session.events,
            [
                "begin",
                "set_local",
                "current_timestamp",
                "reserve_idempotency",
                "consume_confirmation",
                "lock_identifier",
                "persist_retirement",
                "insert_audit",
                "finalize_idempotency",
                "commit",
            ],
        )
        finalized = session.idempotency[(TENANT_A, IDENTIFIER_RETIRE_OPERATION, "idem-r")]
        self.assertEqual(finalized.result_retirement_id, RETIREMENT_A)
        self.assertIsNone(finalized.result_identifier_id)

    def test_identical_assign_and_retire_replays_do_not_consume_persist_or_audit(self):
        assign_admitted = assign_confirmation()
        session = FakeSession(confirmation_row=assign_admitted, animals=[animal_row()])
        first = coordinator().assign_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=assign_request(confirmation=assign_admitted),
            session=session,
            now=NOW,
        )
        session.events.clear()
        replayed_assign = coordinator().assign_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=assign_request(confirmation=assign_admitted),
            session=session,
            now=NOW,
        )
        self.assertTrue(replayed_assign.replayed)
        self.assertEqual(replayed_assign.identifier.id, first.identifier.id)
        self.assertEqual(replayed_assign.transaction_id, first.transaction_id)
        self.assertEqual(session.events, ["begin", "set_local", "current_timestamp", "commit"])
        self.assertEqual(len(session.identifiers), 1)
        self.assertEqual(len(session.audits), 1)

        retire_admitted = retire_confirmation()
        session.confirmations[retire_admitted.id] = retire_admitted
        first_retire = coordinator().retire_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=retire_request(confirmation=retire_admitted),
            session=session,
            now=NOW,
        )
        session.events.clear()
        replayed_retire = coordinator().retire_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=retire_request(confirmation=retire_admitted),
            session=session,
            now=NOW,
        )
        self.assertTrue(replayed_retire.replayed)
        self.assertEqual(replayed_retire.retirement.id, first_retire.retirement.id)
        self.assertEqual(session.events, ["begin", "set_local", "current_timestamp", "commit"])
        self.assertEqual(len(session.retirements), 1)
        self.assertEqual(len(session.audits), 2)

    def test_same_identity_with_different_digest_conflicts(self):
        admitted = assign_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()])
        coordinator().assign_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=assign_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        other = assign_command(id=IDENTIFIER_B, normalized_value="RB-999")
        other_confirmation = assign_confirmation(
            other,
            id=str(uuid4()),
            target_manifest=other.id,
            command_digest=assign_digest(other, confirmation_id=other.id),
        )
        other_confirmation = LivestockConfirmationRecord(
            other_confirmation.id,
            other_confirmation.tenant_id,
            other_confirmation.actor_user_id,
            other_confirmation.principal_id,
            other_confirmation.operation,
            other_confirmation.target_manifest,
            assign_digest(other, confirmation_id=other_confirmation.id),
            other_confirmation.policy_version,
            other_confirmation.validator_version,
            other_confirmation.idempotency_identity,
            other_confirmation.issued_at,
            other_confirmation.expires_at,
            None,
        )
        session.confirmations[other_confirmation.id] = other_confirmation
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().assign_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=assign_request(command=other, confirmation=other_confirmation),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.IDEMPOTENCY_CONFLICT)
        self.assertEqual(len(session.identifiers), 1)

    def test_missing_animal_and_identifier_fail_closed(self):
        admitted = assign_confirmation()
        session = FakeSession(confirmation_row=admitted)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().assign_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=assign_request(confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TARGET_NOT_FOUND)
        self.assertTrue(session.rolled_back)
        self.assertEqual(session.identifiers, [])

        retire_admitted = retire_confirmation()
        session = FakeSession(confirmation_row=retire_admitted, animals=[animal_row()])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().retire_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=retire_request(confirmation=retire_admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TARGET_NOT_FOUND)
        self.assertTrue(session.rolled_back)
        self.assertEqual(session.retirements, [])

    def test_active_collision_already_retired_and_retire_before_effective_fail_closed(self):
        existing = identifier_row()
        admitted = assign_confirmation(assign_command(id=IDENTIFIER_B))
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()], identifiers=[existing])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().assign_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=assign_request(assign_command(id=IDENTIFIER_B), confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.IDENTIFIER_NOT_AVAILABLE)
        self.assertEqual([item.id for item in session.identifiers], [IDENTIFIER_A])

        assigned = identifier_row()
        first_retirement = coordinator().retire_identifier(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=retire_request(),
            session=FakeSession(
                confirmation_row=retire_confirmation(),
                animals=[animal_row()],
                identifiers=[assigned],
            ),
            now=NOW,
        ).retirement
        second = retire_command(id=str(uuid4()))
        second_confirmation = retire_confirmation(second, id=str(uuid4()), command_digest=retire_digest(second, confirmation_id="x"))
        second_confirmation = LivestockConfirmationRecord(
            str(uuid4()),
            TENANT_A,
            USER_A,
            PRINCIPAL_A,
            IDENTIFIER_RETIRE_OPERATION,
            second.identifier_id,
            retire_digest(second, confirmation_id="pending"),
            "policy-v1",
            "validator-v1",
            "idem-r2",
            NOW - timedelta(seconds=30),
            NOW + timedelta(minutes=2) - timedelta(seconds=30),
            None,
        )
        second_confirmation = LivestockConfirmationRecord(
            second_confirmation.id,
            second_confirmation.tenant_id,
            second_confirmation.actor_user_id,
            second_confirmation.principal_id,
            second_confirmation.operation,
            second_confirmation.target_manifest,
            retire_digest(second, confirmation_id=second_confirmation.id, identity="idem-r2"),
            second_confirmation.policy_version,
            second_confirmation.validator_version,
            "idem-r2",
            second_confirmation.issued_at,
            second_confirmation.expires_at,
            None,
        )
        already_session = FakeSession(
            confirmation_row=second_confirmation,
            animals=[animal_row()],
            identifiers=[assigned],
            retirements=[first_retirement],
        )
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().retire_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=retire_request(second, confirmation=second_confirmation, idempotency_identity="idem-r2"),
                session=already_session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.IDENTIFIER_INVALID)

        too_early = retire_command(retired_at=NOW - timedelta(minutes=5))
        early_confirmation = LivestockConfirmationRecord(
            str(uuid4()),
            TENANT_A,
            USER_A,
            PRINCIPAL_A,
            IDENTIFIER_RETIRE_OPERATION,
            too_early.identifier_id,
            retire_digest(too_early, confirmation_id="pending", identity="idem-early"),
            "policy-v1",
            "validator-v1",
            "idem-early",
            NOW - timedelta(seconds=30),
            NOW + timedelta(minutes=2) - timedelta(seconds=30),
            None,
        )
        early_confirmation = LivestockConfirmationRecord(
            early_confirmation.id,
            early_confirmation.tenant_id,
            early_confirmation.actor_user_id,
            early_confirmation.principal_id,
            early_confirmation.operation,
            early_confirmation.target_manifest,
            retire_digest(too_early, confirmation_id=early_confirmation.id, identity="idem-early"),
            early_confirmation.policy_version,
            early_confirmation.validator_version,
            "idem-early",
            early_confirmation.issued_at,
            early_confirmation.expires_at,
            None,
        )
        early_session = FakeSession(
            confirmation_row=early_confirmation,
            animals=[animal_row()],
            identifiers=[identifier_row()],
        )
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().retire_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=retire_request(too_early, confirmation=early_confirmation, idempotency_identity="idem-early"),
                session=early_session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.IDENTIFIER_INVALID)

    def test_persist_failure_rolls_back_assign_and_retire(self):
        admitted = assign_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()], fail_on="persist_identifier")
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().assign_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=assign_request(confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TRANSACTION_FAILED)
        self.assertTrue(session.rolled_back)
        self.assertEqual(session.identifiers, [])
        self.assertEqual(session.audits, [])
        self.assertEqual(session.idempotency, {})

        retire_admitted = retire_confirmation()
        session = FakeSession(
            confirmation_row=retire_admitted,
            animals=[animal_row()],
            identifiers=[identifier_row()],
            fail_on="persist_retirement",
        )
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().retire_identifier(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=retire_request(confirmation=retire_admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TRANSACTION_FAILED)
        self.assertTrue(session.rolled_back)
        self.assertEqual(session.retirements, [])
        self.assertEqual(session.audits, [])
        self.assertEqual(session.idempotency, {})


def lifecycle_provenance(source_id=EVENT_A):
    return LivestockFactProvenance("fixture", source_id, "fixture-v1", NOW)


def record_command(**overrides):
    values = {
        "id": EVENT_A,
        "animal_id": ANIMAL_A,
        "event_type": RoutineLifecycleEventType.INTAKE,
        "occurred_at": NOW,
        "provenance": lifecycle_provenance(),
    }
    values.update(overrides)
    return RoutineLifecycleEventCommandV1(**values)


def ignored_correction_confirmation():
    return LifecycleCorrectionConfirmationV1(
        "ignored-caller-confirmation",
        USER_A,
        "ignored-correlation",
        NOW - timedelta(minutes=5),
    )


def correct_command(**overrides):
    values = {
        "id": EVENT_B,
        "animal_id": ANIMAL_A,
        "event_type": RoutineLifecycleEventType.INTAKE,
        "occurred_at": NOW - timedelta(minutes=1),
        "provenance": lifecycle_provenance(EVENT_B),
        "supersedes_event_id": EVENT_A,
        "correction_reason": LifecycleCorrectionReason.INCORRECT_TIME,
        "confirmation": ignored_correction_confirmation(),
    }
    values.update(overrides)
    return RoutineLifecycleEventCommandV1(**values)


def record_digest(cmd, confirmation_id=CONFIRM_L, identity="idem-l", tenant_id=TENANT_A):
    return canonical_lifecycle_record_digest(
        tenant_id=tenant_id,
        command=cmd,
        confirmation_id=confirmation_id,
        idempotency_identity=identity,
        policy_version="policy-v1",
        validator_version="validator-v1",
    )


def correct_digest(cmd, confirmation_id=CONFIRM_C, identity="idem-c", tenant_id=TENANT_A):
    return canonical_lifecycle_correct_digest(
        tenant_id=tenant_id,
        command=cmd,
        confirmation_id=confirmation_id,
        idempotency_identity=identity,
        policy_version="policy-v1",
        validator_version="validator-v1",
    )


def record_confirmation(cmd=None, **overrides):
    cmd = cmd or record_command()
    issued = NOW - timedelta(seconds=30)
    values = {
        "id": CONFIRM_L,
        "tenant_id": TENANT_A,
        "actor_user_id": USER_A,
        "principal_id": PRINCIPAL_A,
        "operation": LIFECYCLE_RECORD_OPERATION,
        "target_manifest": cmd.id,
        "command_digest": record_digest(cmd),
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
        "idempotency_identity": "idem-l",
        "issued_at": issued,
        "expires_at": issued + timedelta(minutes=2),
        "consumed_at": None,
    }
    values.update(overrides)
    if "command_digest" not in overrides:
        values["command_digest"] = record_digest(
            cmd,
            confirmation_id=values["id"],
            identity=values["idempotency_identity"],
        )
    return LivestockConfirmationRecord(**values)


def correct_confirmation(cmd=None, **overrides):
    cmd = cmd or correct_command()
    issued = NOW - timedelta(seconds=30)
    values = {
        "id": CONFIRM_C,
        "tenant_id": TENANT_A,
        "actor_user_id": USER_A,
        "principal_id": PRINCIPAL_A,
        "operation": LIFECYCLE_CORRECT_OPERATION,
        "target_manifest": cmd.supersedes_event_id,
        "command_digest": correct_digest(cmd),
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
        "idempotency_identity": "idem-c",
        "issued_at": issued,
        "expires_at": issued + timedelta(minutes=2),
        "consumed_at": None,
    }
    values.update(overrides)
    if "command_digest" not in overrides:
        values["command_digest"] = correct_digest(
            cmd,
            confirmation_id=values["id"],
            identity=values["idempotency_identity"],
        )
    return LivestockConfirmationRecord(**values)


def record_request(cmd=None, **overrides):
    cmd = cmd or record_command()
    values = {
        "command": cmd,
        "confirmation": record_confirmation(cmd),
        "idempotency_identity": "idem-l",
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
    }
    values.update(overrides)
    return LivestockLifecycleRecordRequest(**values)


def correct_request(cmd=None, **overrides):
    cmd = cmd or correct_command()
    values = {
        "command": cmd,
        "confirmation": correct_confirmation(cmd),
        "idempotency_identity": "idem-c",
        "policy_version": "policy-v1",
        "validator_version": "validator-v1",
    }
    values.update(overrides)
    return LivestockLifecycleCorrectRequest(**values)


def recorded_event(tenant_id=TENANT_A):
    context = TenantContext(tenant_id, USER_A, PRINCIPAL_A, Role.MANAGER, "development", "request-a")
    return record_routine_lifecycle_event(context, record_command(), (), NOW - timedelta(minutes=2))


class LivestockLifecycleMutationCoordinatorTests(unittest.TestCase):
    def test_admission_rejects_missing_tenant_viewer_and_correction_shape_before_transaction(self):
        session = FakeSession()
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=None,
                request=record_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.VIEWER).record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=record_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=record_request(correct_command()),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.OWNER).correct_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=correct_request(record_command()),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        self.assertEqual(session.events, [])

    def test_admission_rejects_manager_correction_before_transaction(self):
        session = FakeSession(animals=[animal_row()], events=[recorded_event()])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.MANAGER).correct_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=correct_request(),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.ADMISSION_DENIED)
        self.assertEqual(session.events, [])

    def test_first_write_rejects_expired_used_unbound_wrong_matrix_id_and_wrong_target(self):
        expired = record_confirmation(issued_at=NOW - timedelta(minutes=3), expires_at=NOW - timedelta(minutes=1))
        reused = record_confirmation(consumed_at=NOW - timedelta(seconds=1))
        unbound = record_confirmation(command_digest="not-the-canonical-digest")
        wrong_op = record_confirmation(operation=ANIMAL_CREATE_OPERATION)
        wrong_target = record_confirmation(target_manifest=ANIMAL_A)
        for invalid in (expired, reused, unbound, wrong_op, wrong_target):
            session = FakeSession(confirmation_row=invalid, animals=[animal_row()])
            with self.assertRaises(LivestockMutationError) as raised:
                coordinator().record_lifecycle_event(
                    principal=principal(),
                    requested_tenant_id=TENANT_A,
                    request=record_request(confirmation=invalid),
                    session=session,
                    now=NOW,
                )
            self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
            self.assertIn("rollback", session.events)
            self.assertEqual(session.lifecycle_events, [])
            self.assertEqual(session.audits, [])

        wrong_correct_target = correct_confirmation(target_manifest=EVENT_B)
        session = FakeSession(confirmation_row=wrong_correct_target, animals=[animal_row()], events=[recorded_event()])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.OWNER).correct_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=correct_request(confirmation=wrong_correct_target),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.CONFIRMATION_INVALID)
        self.assertEqual(len(session.lifecycle_events), 1)

    def test_successful_record_locks_animal_history_then_persists_in_order(self):
        admitted = record_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()])
        result = coordinator().record_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=record_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.event.id, EVENT_A)
        self.assertEqual(result.event.event_type, RoutineLifecycleEventType.INTAKE)
        self.assertEqual(
            session.events,
            [
                "begin",
                "set_local",
                "current_timestamp",
                "reserve_idempotency",
                "consume_confirmation",
                "lock_animal",
                "lock_lifecycle_animal_history",
                "persist_lifecycle",
                "insert_audit",
                "finalize_idempotency",
                "commit",
            ],
        )
        finalized = session.idempotency[(TENANT_A, LIFECYCLE_RECORD_OPERATION, "idem-l")]
        self.assertEqual(finalized.result_lifecycle_event_id, EVENT_A)
        self.assertIsNone(finalized.result_animal_id)
        self.assertEqual(session.audits[0].operation, LIFECYCLE_RECORD_OPERATION)

    def test_successful_correct_synthesizes_cf2_confirmation_and_does_not_overwrite(self):
        admitted = correct_confirmation()
        original = recorded_event()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()], events=[original])
        result = coordinator(Role.OWNER).correct_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=correct_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertFalse(result.replayed)
        self.assertEqual(result.event.supersedes_event_id, EVENT_A)
        self.assertEqual(result.event.confirmation.id, CONFIRM_C)
        self.assertEqual(result.event.confirmation.approved_by_user_id, USER_A)
        self.assertEqual(result.event.confirmation.correlation_id, "request-a")
        self.assertNotEqual(result.event.confirmation.id, ignored_correction_confirmation().id)
        self.assertEqual(len(session.lifecycle_events), 2)
        self.assertEqual(session.lifecycle_events[0].id, EVENT_A)
        self.assertEqual(session.lifecycle_events[1].id, EVENT_B)
        finalized = session.idempotency[(TENANT_A, LIFECYCLE_CORRECT_OPERATION, "idem-c")]
        self.assertEqual(finalized.result_lifecycle_event_id, EVENT_B)
        self.assertIsNone(finalized.result_identifier_id)

    def test_identical_record_and_correct_replays_do_not_consume_persist_or_audit(self):
        admitted = record_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()])
        first = coordinator().record_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=record_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        session.events.clear()
        replayed = coordinator().record_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=record_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        self.assertTrue(replayed.replayed)
        self.assertEqual(replayed.event.id, first.event.id)
        self.assertEqual(session.events, ["begin", "set_local", "current_timestamp", "commit"])
        self.assertEqual(len(session.lifecycle_events), 1)
        self.assertEqual(len(session.audits), 1)

        session.now = NOW + timedelta(seconds=1)
        correct_admitted = correct_confirmation()
        session.confirmations[correct_admitted.id] = correct_admitted
        first_correct = coordinator(Role.OWNER).correct_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=correct_request(confirmation=correct_admitted),
            session=session,
            now=NOW,
        )
        session.events.clear()
        replayed_correct = coordinator(Role.OWNER).correct_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=correct_request(confirmation=correct_admitted),
            session=session,
            now=NOW,
        )
        self.assertTrue(replayed_correct.replayed)
        self.assertEqual(replayed_correct.event.id, first_correct.event.id)
        self.assertEqual(session.events, ["begin", "set_local", "current_timestamp", "commit"])
        self.assertEqual(len(session.lifecycle_events), 2)
        self.assertEqual(len(session.audits), 2)

    def test_same_idempotency_identity_with_different_digest_conflicts(self):
        admitted = record_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()])
        coordinator().record_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=record_request(confirmation=admitted),
            session=session,
            now=NOW,
        )
        other_id = str(uuid4())
        other = record_command(id=other_id, provenance=lifecycle_provenance(other_id))
        other_confirmation = record_confirmation(other, id=str(uuid4()), idempotency_identity="idem-l")
        session.confirmations[other_confirmation.id] = other_confirmation
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=record_request(other, confirmation=other_confirmation, idempotency_identity="idem-l"),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.IDEMPOTENCY_CONFLICT)
        self.assertEqual(len(session.lifecycle_events), 1)

    def test_missing_animal_out_of_order_and_second_supersession_fail_closed(self):
        admitted = record_confirmation()
        session = FakeSession(confirmation_row=admitted)
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=record_request(confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TARGET_NOT_FOUND)
        self.assertTrue(session.rolled_back)

        existing = recorded_event()
        too_early = record_command(id=EVENT_B, occurred_at=NOW - timedelta(minutes=5), provenance=lifecycle_provenance(EVENT_B))
        early_confirmation = record_confirmation(too_early, id=str(uuid4()), idempotency_identity="idem-early")
        early_session = FakeSession(confirmation_row=early_confirmation, animals=[animal_row()], events=[existing])
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=record_request(too_early, confirmation=early_confirmation, idempotency_identity="idem-early"),
                session=early_session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.LIFECYCLE_INVALID)

        first = coordinator(Role.OWNER).correct_lifecycle_event(
            principal=principal(),
            requested_tenant_id=TENANT_A,
            request=correct_request(),
            session=FakeSession(
                confirmation_row=correct_confirmation(),
                animals=[animal_row()],
                events=[existing],
            ),
            now=NOW,
        ).event
        second_id = str(uuid4())
        second = correct_command(id=second_id, provenance=lifecycle_provenance(second_id))
        second_confirmation = correct_confirmation(second, id=str(uuid4()), idempotency_identity="idem-c2")
        already = FakeSession(
            confirmation_row=second_confirmation,
            animals=[animal_row()],
            events=[existing, first],
        )
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.OWNER).correct_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=correct_request(second, confirmation=second_confirmation, idempotency_identity="idem-c2"),
                session=already,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.LIFECYCLE_INVALID)

    def test_persist_failure_rolls_back_record_and_correct(self):
        admitted = record_confirmation()
        session = FakeSession(confirmation_row=admitted, animals=[animal_row()], fail_on="persist_lifecycle")
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator().record_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=record_request(confirmation=admitted),
                session=session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TRANSACTION_FAILED)
        self.assertTrue(session.rolled_back)
        self.assertEqual(session.lifecycle_events, [])
        self.assertEqual(session.audits, [])
        self.assertEqual(session.idempotency, {})

        correct_admitted = correct_confirmation()
        original = recorded_event()
        correct_session = FakeSession(
            confirmation_row=correct_admitted,
            animals=[animal_row()],
            events=[original],
            fail_on="persist_lifecycle",
        )
        with self.assertRaises(LivestockMutationError) as raised:
            coordinator(Role.OWNER).correct_lifecycle_event(
                principal=principal(),
                requested_tenant_id=TENANT_A,
                request=correct_request(confirmation=correct_admitted),
                session=correct_session,
                now=NOW,
            )
        self.assertEqual(raised.exception.code, LivestockMutationErrorCode.TRANSACTION_FAILED)
        self.assertTrue(correct_session.rolled_back)
        self.assertEqual([event.id for event in correct_session.lifecycle_events], [EVENT_A])
        self.assertEqual(correct_session.audits, [])
        self.assertEqual(correct_session.idempotency, {})
