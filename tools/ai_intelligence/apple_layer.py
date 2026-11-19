"""Apple Intelligence layer classification hook.

One place decides Apple-layer candidacy: the task must be lightweight
private work (on-device processing satisfies every privacy tier), and the
local helper must be available. The pure classifier is safe to call from
routing; the hook binds it to a live availability probe for selection
and for the active-layer signal.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from tools.ai_intelligence.routing_models import PrivacyTier
from tools.ai_intelligence.runtime_selection import (
    WorkloadClass,
    workload_for_task,
)


@dataclass(frozen=True)
class AppleLayerVerdict:
    """Policy verdict for Apple Intelligence layer candidacy."""

    eligible: bool
    reason: str
    workload: WorkloadClass
    privacy_tier: PrivacyTier


def classify_apple_layer(
    *,
    task_type: str,
    privacy_tier: PrivacyTier,
) -> AppleLayerVerdict:
    """Classify whether a request belongs on the Apple Intelligence layer.

    Apple Intelligence processes on-device, so it satisfies local, mixed,
    and external-approved privacy alike. Only the workload gates it:
    lightweight private tasks stay eligible, everything else does not.
    Availability is checked separately by AppleLayerHook.
    """

    workload = workload_for_task(task_type)
    if workload is not WorkloadClass.LIGHTWEIGHT_PRIVATE:
        return AppleLayerVerdict(
            eligible=False,
            reason=f"task is {workload.value}, not lightweight-private",
            workload=workload,
            privacy_tier=privacy_tier,
        )
    return AppleLayerVerdict(
        eligible=True,
        reason="lightweight-private task, on-device satisfies "
        f"{privacy_tier.value} privacy",
        workload=workload,
        privacy_tier=privacy_tier,
    )


class AppleLayerHook:
    """Availability-aware Apple-layer classifier for selection and glow.

    `is_available` is a lightweight probe (for example the Apple provider's
    availability check). It is called at most once per eligibility check
    and never when policy already rules Apple out.
    """

    def __init__(
        self,
        is_available: Callable[[], bool],
    ) -> None:
        if not callable(is_available):
            raise TypeError("is_available must be callable")
        self._is_available = is_available

    def eligible(
        self,
        *,
        task_type: str,
        privacy_tier: PrivacyTier,
    ) -> bool:
        """Return whether Apple may serve this request right now."""

        verdict = classify_apple_layer(
            task_type=task_type,
            privacy_tier=privacy_tier,
        )
        if not verdict.eligible:
            return False
        try:
            return bool(self._is_available())
        except Exception:
            return False

    __call__ = eligible
