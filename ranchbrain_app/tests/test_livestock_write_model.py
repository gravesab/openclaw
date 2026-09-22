from datetime import datetime, timedelta, timezone
import unittest

from ranchbrain.livestock_read_model import LivestockFactProvenance
from ranchbrain.livestock_write_model import (
    AnimalCreateCommandV1,
    AnimalIdentifierType,
    IdentifierAssignCommandV1,
    IdentifierRetireCommandV1,
    IdentifierRetirementReason,
    LifecycleCorrectionConfirmationV1,
    LifecycleCorrectionReason,
    LivestockWriteError,
    LivestockWriteErrorCode,
    RoutineLifecycleEventCommandV1,
    RoutineLifecycleEventType,
    assign_identifier,
    create_animal,
    record_routine_lifecycle_event,
    retire_identifier,
)
from ranchbrain.tenancy import Role, TenantContext


NOW = datetime(2026, 8, 30, 14, tzinfo=timezone.utc)


def context(role=Role.MANAGER, tenant_id="tenant-a"):
    return TenantContext(tenant_id, "user-a", "principal-a", role, "development", "request-a")


def provenance(source_id="fixture-1"):
    return LivestockFactProvenance("fixture", source_id, "fixture-v1", NOW)


def animal_command():
    return AnimalCreateCommandV1("animal-1", "Juniper", "cattle", "beef", "angus", provenance("animal-1"))


def identifier_command(identifier_id="identifier-1", value="RB-104"):
    return IdentifierAssignCommandV1(identifier_id, "animal-1", AnimalIdentifierType.EAR_TAG, value, NOW, provenance(identifier_id))


def retire_command(retirement_id="retirement-1", identifier_id="identifier-1", retired_at=None, reason=IdentifierRetirementReason.REPLACED):
    return IdentifierRetireCommandV1(
        retirement_id,
        identifier_id,
        reason,
        NOW + timedelta(minutes=1) if retired_at is None else retired_at,
        provenance(retirement_id),
    )


def lifecycle_command(event_id="event-1", occurred_at=NOW, **overrides):
    values = {
        "id": event_id,
        "animal_id": "animal-1",
        "event_type": RoutineLifecycleEventType.INTAKE,
        "occurred_at": occurred_at,
        "provenance": provenance(event_id),
    }
    values.update(overrides)
    return RoutineLifecycleEventCommandV1(**values)


class LivestockWriteModelTests(unittest.TestCase):
    def test_manager_can_create_catalog_valid_immutable_animal_with_audit_input(self):
        animal = create_animal(context(), animal_command(), NOW)

        self.assertEqual(animal.tenant_id, "tenant-a")
        self.assertEqual(animal.audit.actor_user_id, "user-a")
        self.assertEqual(animal.audit.correlation_id, "request-a")
        with self.assertRaises(LivestockWriteError):
            AnimalCreateCommandV1("animal-2", "Unknown", "other", "beef", None, provenance("animal-2"))
        pet = AnimalCreateCommandV1("animal-3", "Milo", "pet", "companion", None, provenance("animal-3"))
        self.assertEqual(pet.species_code, "pet")

    def test_viewer_cannot_create_an_animal(self):
        with self.assertRaises(LivestockWriteError) as raised:
            create_animal(context(Role.VIEWER), animal_command(), NOW)
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.FORBIDDEN)

    def test_owner_can_write_animal_identifier_and_lifecycle_records(self):
        owner = context(Role.OWNER)
        animal = create_animal(owner, animal_command(), NOW)
        assigned = assign_identifier(owner, identifier_command(), (), (), NOW)
        event = record_routine_lifecycle_event(owner, lifecycle_command(), (), NOW)
        self.assertEqual(animal.tenant_id, "tenant-a")
        self.assertEqual(assigned.tenant_id, "tenant-a")
        self.assertEqual(event.tenant_id, "tenant-a")

    def test_viewer_cannot_write_identifiers_or_lifecycle_events(self):
        viewer = context(Role.VIEWER)
        with self.assertRaises(LivestockWriteError) as raised:
            assign_identifier(viewer, identifier_command(), (), (), NOW)
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.FORBIDDEN)
        assigned = assign_identifier(context(), identifier_command(), (), (), NOW)
        with self.assertRaises(LivestockWriteError) as raised:
            retire_identifier(viewer, retire_command(), assigned, (), NOW + timedelta(minutes=1))
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.FORBIDDEN)
        with self.assertRaises(LivestockWriteError) as raised:
            record_routine_lifecycle_event(viewer, lifecycle_command(), (), NOW)
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.FORBIDDEN)

    def test_active_identifier_is_unique_per_tenant_and_reusable_only_after_retirement(self):
        assigned = assign_identifier(context(), identifier_command(), (), (), NOW)
        with self.assertRaises(LivestockWriteError) as raised:
            assign_identifier(context(), identifier_command("identifier-2"), (assigned,), (), NOW)
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.IDENTIFIER_NOT_AVAILABLE)

        retirement = retire_identifier(context(), retire_command(), assigned, (), NOW + timedelta(minutes=1))
        self.assertEqual(retirement.provenance.source_id, "retirement-1")
        reused = assign_identifier(context(), identifier_command("identifier-2"), (assigned,), (retirement,), NOW + timedelta(minutes=2))
        self.assertEqual(reused.normalized_value, "RB-104")
        self.assertNotEqual(reused.id, assigned.id)

    def test_identifier_retirement_is_append_only_and_tenant_bound(self):
        assigned = assign_identifier(context(), identifier_command(), (), (), NOW)
        with self.assertRaises(LivestockWriteError) as raised:
            retire_identifier(
                context(Role.MANAGER, "tenant-b"),
                retire_command(reason=IdentifierRetirementReason.LOST),
                assigned,
                (),
                NOW + timedelta(minutes=1),
            )
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.CONTEXT_MISMATCH)
        with self.assertRaises(LivestockWriteError) as raised:
            retire_identifier(
                context(),
                retire_command(identifier_id="identifier-other", reason=IdentifierRetirementReason.LOST),
                assigned,
                (),
                NOW + timedelta(minutes=1),
            )
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.CONTEXT_MISMATCH)
        retirement = retire_identifier(
            context(),
            retire_command(reason=IdentifierRetirementReason.LOST),
            assigned,
            (),
            NOW + timedelta(minutes=1),
        )
        self.assertEqual(retirement.provenance.source_type, "fixture")
        with self.assertRaises(LivestockWriteError):
            IdentifierRetireCommandV1(
                "retirement-2",
                assigned.id,
                IdentifierRetirementReason.LOST,
                NOW + timedelta(minutes=2),
                None,
            )
        with self.assertRaises(LivestockWriteError):
            retire_identifier(
                context(),
                retire_command("retirement-2", reason=IdentifierRetirementReason.LOST, retired_at=NOW + timedelta(minutes=2)),
                assigned,
                (retirement,),
                NOW + timedelta(minutes=2),
            )

    def test_routine_events_are_closed_and_append_in_occurred_time_order(self):
        intake = record_routine_lifecycle_event(context(), lifecycle_command(), (), NOW)
        tagged = record_routine_lifecycle_event(
            context(),
            lifecycle_command("event-2", NOW + timedelta(minutes=1), event_type=RoutineLifecycleEventType.TAGGED),
            (intake,),
            NOW + timedelta(minutes=1),
        )
        self.assertEqual(tagged.event_type, RoutineLifecycleEventType.TAGGED)
        with self.assertRaises(LivestockWriteError) as raised:
            record_routine_lifecycle_event(
                context(), lifecycle_command("event-3", NOW), (intake, tagged), NOW + timedelta(minutes=2)
            )
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.INVALID)

    def test_lifecycle_correction_requires_owner_capability_and_context_bound_confirmation(self):
        intake = record_routine_lifecycle_event(context(), lifecycle_command(), (), NOW)
        confirmation = LifecycleCorrectionConfirmationV1("confirmation-1", "user-a", "request-a", NOW + timedelta(minutes=1))
        correction = lifecycle_command(
            "event-2",
            NOW - timedelta(minutes=1),
            supersedes_event_id="event-1",
            correction_reason=LifecycleCorrectionReason.INCORRECT_TIME,
            confirmation=confirmation,
        )
        with self.assertRaises(LivestockWriteError) as raised:
            record_routine_lifecycle_event(context(), correction, (intake,), NOW + timedelta(minutes=2))
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.FORBIDDEN)

        corrected = record_routine_lifecycle_event(context(Role.OWNER), correction, (intake,), NOW + timedelta(minutes=2))
        self.assertEqual(corrected.supersedes_event_id, intake.id)
        with self.assertRaises(LivestockWriteError):
            record_routine_lifecycle_event(context(Role.OWNER), correction, (intake, corrected), NOW + timedelta(minutes=3))

    def test_identifier_assignment_id_cannot_be_reused_even_after_retirement(self):
        assigned = assign_identifier(context(), identifier_command(), (), (), NOW)
        retirement = retire_identifier(context(), retire_command(), assigned, (), NOW + timedelta(minutes=1))
        for retirements in ((), (retirement,)):
            with self.subTest(retired=bool(retirements)):
                with self.assertRaises(LivestockWriteError) as raised:
                    assign_identifier(
                        context(),
                        identifier_command("identifier-1", "RB-999"),
                        (assigned,),
                        retirements,
                        NOW + timedelta(minutes=2),
                    )
                self.assertEqual(raised.exception.code, LivestockWriteErrorCode.INVALID)

    def test_duplicate_lifecycle_event_id_is_rejected_for_append(self):
        intake = record_routine_lifecycle_event(context(), lifecycle_command(), (), NOW)
        with self.assertRaises(LivestockWriteError) as raised:
            record_routine_lifecycle_event(
                context(),
                lifecycle_command("event-1", NOW + timedelta(minutes=1), event_type=RoutineLifecycleEventType.TAGGED),
                (intake,),
                NOW + timedelta(minutes=1),
            )
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.INVALID)

    def test_duplicate_lifecycle_event_id_is_rejected_for_correction(self):
        intake = record_routine_lifecycle_event(context(), lifecycle_command(), (), NOW)
        tagged = record_routine_lifecycle_event(
            context(),
            lifecycle_command("event-2", NOW + timedelta(minutes=1), event_type=RoutineLifecycleEventType.TAGGED),
            (intake,),
            NOW + timedelta(minutes=1),
        )
        confirmation = LifecycleCorrectionConfirmationV1("confirmation-1", "user-a", "request-a", NOW + timedelta(minutes=2))
        correction = lifecycle_command(
            "event-1",
            NOW + timedelta(minutes=3),
            event_type=RoutineLifecycleEventType.TAGGED,
            supersedes_event_id="event-2",
            correction_reason=LifecycleCorrectionReason.INCORRECT_TIME,
            confirmation=confirmation,
        )
        with self.assertRaises(LivestockWriteError) as raised:
            record_routine_lifecycle_event(context(Role.OWNER), correction, (intake, tagged), NOW + timedelta(minutes=3))
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.INVALID)

    def test_lifecycle_append_order_uses_effective_correction_times(self):
        intake = record_routine_lifecycle_event(context(), lifecycle_command(), (), NOW)
        confirmation = LifecycleCorrectionConfirmationV1("confirmation-1", "user-a", "request-a", NOW + timedelta(minutes=1))
        corrected_earlier = record_routine_lifecycle_event(
            context(Role.OWNER),
            lifecycle_command(
                "event-correction",
                NOW - timedelta(minutes=1),
                supersedes_event_id=intake.id,
                correction_reason=LifecycleCorrectionReason.INCORRECT_TIME,
                confirmation=confirmation,
            ),
            (intake,),
            NOW + timedelta(minutes=2),
        )
        appended = record_routine_lifecycle_event(
            context(),
            lifecycle_command("event-next", NOW),
            (intake, corrected_earlier),
            NOW + timedelta(minutes=3),
        )
        self.assertEqual(appended.id, "event-next")

        corrected_later = record_routine_lifecycle_event(
            context(Role.OWNER),
            lifecycle_command(
                "event-correction-later",
                NOW + timedelta(minutes=2),
                supersedes_event_id=appended.id,
                correction_reason=LifecycleCorrectionReason.INCORRECT_TIME,
                confirmation=confirmation,
            ),
            (intake, corrected_earlier, appended),
            NOW + timedelta(minutes=4),
        )
        with self.assertRaises(LivestockWriteError) as raised:
            record_routine_lifecycle_event(
                context(),
                lifecycle_command("event-too-early", NOW + timedelta(minutes=1)),
                (intake, corrected_earlier, appended, corrected_later),
                NOW + timedelta(minutes=5),
            )
        self.assertEqual(raised.exception.code, LivestockWriteErrorCode.INVALID)
