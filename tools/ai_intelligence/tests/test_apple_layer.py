"""Tests for the Apple Intelligence layer classification hook."""

from __future__ import annotations

import unittest

from tools.ai_intelligence.apple_layer import (
    AppleLayerHook,
    classify_apple_layer,
)
from tools.ai_intelligence.routing_models import PrivacyTier
from tools.ai_intelligence.runtime_selection import WorkloadClass


class ClassifyAppleLayerTests(unittest.TestCase):
    def test_lightweight_local_is_eligible(self) -> None:
        verdict = classify_apple_layer(
            task_type="summary",
            privacy_tier=PrivacyTier.LOCAL,
        )
        self.assertTrue(verdict.eligible)
        self.assertIs(
            verdict.workload, WorkloadClass.LIGHTWEIGHT_PRIVATE
        )

    def test_on_device_satisfies_looser_tiers(self) -> None:
        for tier in (PrivacyTier.MIXED, PrivacyTier.EXTERNAL_APPROVED):
            verdict = classify_apple_layer(
                task_type="classification",
                privacy_tier=tier,
            )
            self.assertTrue(verdict.eligible)

    def test_heavy_tasks_are_ineligible(self) -> None:
        for task_type in ("swift", "linux_admin", "knowledge"):
            verdict = classify_apple_layer(
                task_type=task_type,
                privacy_tier=PrivacyTier.LOCAL,
            )
            self.assertFalse(verdict.eligible)
            self.assertIn("not lightweight-private", verdict.reason)


class AppleLayerHookTests(unittest.TestCase):
    def test_available_helper_is_eligible(self) -> None:
        hook = AppleLayerHook(is_available=lambda: True)
        self.assertTrue(
            hook.eligible(
                task_type="summary",
                privacy_tier=PrivacyTier.LOCAL,
            )
        )

    def test_unavailable_helper_is_ineligible(self) -> None:
        hook = AppleLayerHook(is_available=lambda: False)
        self.assertFalse(
            hook.eligible(
                task_type="summary",
                privacy_tier=PrivacyTier.LOCAL,
            )
        )

    def test_probe_never_runs_for_heavy_tasks(self) -> None:
        calls: list[None] = []

        def probe() -> bool:
            calls.append(None)
            return True

        hook = AppleLayerHook(is_available=probe)
        self.assertFalse(
            hook.eligible(
                task_type="swift",
                privacy_tier=PrivacyTier.LOCAL,
            )
        )
        self.assertEqual(calls, [])

    def test_probe_exceptions_mean_ineligible(self) -> None:
        def probe() -> bool:
            raise RuntimeError("helper crashed")

        hook = AppleLayerHook(is_available=probe)
        self.assertFalse(
            hook.eligible(
                task_type="summary",
                privacy_tier=PrivacyTier.LOCAL,
            )
        )

    def test_hook_is_callable(self) -> None:
        hook = AppleLayerHook(is_available=lambda: True)
        self.assertTrue(
            hook(task_type="summary", privacy_tier=PrivacyTier.LOCAL)
        )

    def test_rejects_non_callable_probe(self) -> None:
        with self.assertRaises(TypeError):
            AppleLayerHook(is_available=True)  # type: ignore[arg-type]


if __name__ == "__main__":
    unittest.main()
