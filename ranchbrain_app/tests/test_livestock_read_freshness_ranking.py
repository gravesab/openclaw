"""Herd fact-freshness ranking for the RanchOS DEV livestock read contract."""

from __future__ import annotations

from datetime import datetime, timezone
import unittest

from ranchbrain.livestock_read_api import (
    DataOrigin,
    FactFreshness,
    LiveLifecycleStatus,
    LivestockAnimalReadFactV1,
    LivestockProvenanceV1,
    build_herd_dashboard,
)

OBSERVED = datetime(2026, 9, 21, 12, tzinfo=timezone.utc)


def animal(animal_id: str, freshness: FactFreshness) -> LivestockAnimalReadFactV1:
    return LivestockAnimalReadFactV1(
        animal_id,
        "tenant-a",
        animal_id,
        "cattle",
        "beef",
        "angus",
        LiveLifecycleStatus.ACTIVE,
        freshness,
        "ear_tag",
        f"tag-{animal_id}",
        LivestockProvenanceV1(
            "ranch_record",
            animal_id,
            "read-model-v1",
            OBSERVED,
            DataOrigin.LIVE,
        ),
    )


def freshness(animals: tuple[LivestockAnimalReadFactV1, ...]) -> tuple[int, str, str]:
    dashboard = build_herd_dashboard("North Ranch", animals)
    card = next(item for item in dashboard.summaries if item.id == "fact-freshness")
    if dashboard.origin is not DataOrigin.LIVE:
        raise AssertionError("dashboard origin must stay live")
    return dashboard.herd_count, card.status.value, card.detail


class LivestockReadFreshnessRankingTests(unittest.TestCase):
    def test_empty_herd_is_current(self) -> None:
        count, status, detail = freshness(())
        self.assertEqual(count, 0)
        self.assertEqual(status, "Current")
        self.assertEqual(detail, "Animal facts are current")

    def test_current_herd_is_current(self) -> None:
        count, status, detail = freshness((animal("animal-a", FactFreshness.CURRENT),))
        self.assertEqual(count, 1)
        self.assertEqual(status, "Current")
        self.assertEqual(detail, "Animal facts are current")

    def test_stale_among_current_is_care_due(self) -> None:
        count, status, detail = freshness(
            (
                animal("animal-a", FactFreshness.STALE),
                animal("animal-b", FactFreshness.CURRENT),
            )
        )
        self.assertEqual(count, 2)
        self.assertEqual(status, "Care due")
        self.assertEqual(detail, "1 animals need fact review")

    def test_incomplete_is_review_not_care_due(self) -> None:
        count, status, detail = freshness((animal("animal-a", FactFreshness.INCOMPLETE),))
        self.assertEqual(count, 1)
        self.assertEqual(status, "Review")
        self.assertNotEqual(status, "Care due")

    def test_conflicting_is_review_not_care_due(self) -> None:
        _count, status, _detail = freshness((animal("animal-a", FactFreshness.CONFLICTING),))
        self.assertEqual(status, "Review")
        self.assertNotEqual(status, "Care due")

    def test_incomplete_outranks_stale(self) -> None:
        count, status, detail = freshness(
            (
                animal("animal-a", FactFreshness.STALE),
                animal("animal-b", FactFreshness.INCOMPLETE),
            )
        )
        self.assertEqual(count, 2)
        self.assertEqual(status, "Review")
        self.assertEqual(detail, "2 animals need fact review")

    def test_conflicting_outranks_stale(self) -> None:
        _count, status, _detail = freshness(
            (
                animal("animal-a", FactFreshness.STALE),
                animal("animal-b", FactFreshness.CONFLICTING),
            )
        )
        self.assertEqual(status, "Review")


    def test_missing_identifier_marks_records_review_and_leaves_freshness_current(self) -> None:
        fact = LivestockAnimalReadFactV1(
            "animal-a",
            "tenant-a",
            "animal-a",
            "cattle",
            "beef",
            "angus",
            LiveLifecycleStatus.ACTIVE,
            FactFreshness.CURRENT,
            None,
            None,
            LivestockProvenanceV1(
                "ranch_record",
                "animal-a",
                "read-model-v1",
                OBSERVED,
                DataOrigin.LIVE,
            ),
        )
        dashboard = build_herd_dashboard("North Ranch", (fact,))
        freshness_card = next(item for item in dashboard.summaries if item.id == "fact-freshness")
        records_card = next(item for item in dashboard.summaries if item.id == "records-review")
        self.assertEqual(freshness_card.status.value, "Current")
        self.assertEqual(freshness_card.detail, "Animal facts are current")
        self.assertEqual(records_card.status.value, "Review")
        self.assertEqual(records_card.detail, "1 animals have no active identifier")

    def test_stale_with_identifier_leaves_records_review_current(self) -> None:
        dashboard = build_herd_dashboard(
            "North Ranch",
            (animal("animal-a", FactFreshness.STALE),),
        )
        freshness_card = next(item for item in dashboard.summaries if item.id == "fact-freshness")
        records_card = next(item for item in dashboard.summaries if item.id == "records-review")
        self.assertEqual(freshness_card.status.value, "Care due")
        self.assertEqual(records_card.status.value, "Current")
        self.assertEqual(records_card.detail, "Every animal has an active identifier")


if __name__ == "__main__":
    unittest.main()
