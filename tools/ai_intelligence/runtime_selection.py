"""Choose an approved local runtime, and keep cloud attachable for large problems.

Configured assignments stay the only candidates. This module does not invent a
model, call a provider, or attach a cloud client.
"""

from __future__ import annotations

from dataclasses import replace
from enum import Enum
from typing import Sequence

from tools.ai_intelligence.routing_models import (
    AssignmentType,
    ModelAssignment,
    PrivacyTier,
    RoutingModelError,
)


class RuntimeFamily(str, Enum):
    """Where a configured model actually runs."""

    APPLE_INTELLIGENCE = "apple-intelligence"
    MLX = "mlx"
    LLAMA_CPP = "llama.cpp"
    OLLAMA = "ollama"
    CLOUD = "cloud"


class WorkloadClass(str, Enum):
    """The kind of work used to order eligible runtimes."""

    LIGHTWEIGHT_PRIVATE = "lightweight-private"
    DEEP_LOCAL = "deep-local"
    LARGE_PROBLEM = "large-problem"


_LIGHTWEIGHT_TASKS = frozenset(
    {
        "routine_local_query",
        "classification",
        "extraction",
        "summary",
        "work_request_draft",
    }
)
_LARGE_PROBLEM_TASKS = frozenset(
    {
        "long_context_engineering",
        "linux_admin",
        "swift",
    }
)

# llama.cpp is the preferred open-source runtime: GGUF coverage, Metal, and an
# OpenAI-compatible server. MLX stays available for Apple Silicon models that
# are already served there. Ollama is the last local fallback.
_LIGHTWEIGHT_ORDER = (
    RuntimeFamily.APPLE_INTELLIGENCE,
    RuntimeFamily.LLAMA_CPP,
    RuntimeFamily.MLX,
    RuntimeFamily.OLLAMA,
)
_DEEP_LOCAL_ORDER = (
    RuntimeFamily.LLAMA_CPP,
    RuntimeFamily.MLX,
    RuntimeFamily.OLLAMA,
)
_LARGE_PROBLEM_ORDER = (
    RuntimeFamily.LLAMA_CPP,
    RuntimeFamily.MLX,
    RuntimeFamily.OLLAMA,
    RuntimeFamily.CLOUD,
)


def workload_for_task(task_type: str) -> WorkloadClass:
    """Map a stored component task to a runtime workload."""

    normalized = task_type.strip().lower()
    if normalized in _LIGHTWEIGHT_TASKS:
        return WorkloadClass.LIGHTWEIGHT_PRIVATE
    if normalized in _LARGE_PROBLEM_TASKS:
        return WorkloadClass.LARGE_PROBLEM
    return WorkloadClass.DEEP_LOCAL


def runtime_family(assignment: ModelAssignment) -> RuntimeFamily:
    """Classify one configured model by its id and deployment."""

    model_id = assignment.model_id.strip().lower()
    provider = assignment.provider.strip().lower()
    if model_id == "apple-foundation-models" or "foundation" in provider:
        return RuntimeFamily.APPLE_INTELLIGENCE
    if model_id.startswith("omlx-") or "mlx" in provider or "omlx" in provider:
        return RuntimeFamily.MLX
    if model_id.startswith("llama-cpp-") or "llama.cpp" in provider or "llama-cpp" in provider:
        return RuntimeFamily.LLAMA_CPP
    if model_id.startswith("ollama-") or "ollama" in provider:
        return RuntimeFamily.OLLAMA
    if assignment.deployment.strip().lower() != "local":
        return RuntimeFamily.CLOUD
    raise RoutingModelError(
        f"Unrecognized local runtime for model {assignment.model_id}"
    )


def preference_order(workload: WorkloadClass) -> tuple[RuntimeFamily, ...]:
    """Return the runtime order for a workload."""

    if workload is WorkloadClass.LIGHTWEIGHT_PRIVATE:
        return _LIGHTWEIGHT_ORDER
    if workload is WorkloadClass.DEEP_LOCAL:
        return _DEEP_LOCAL_ORDER
    if workload is WorkloadClass.LARGE_PROBLEM:
        return _LARGE_PROBLEM_ORDER
    raise RoutingModelError(f"Unsupported workload: {workload}")


def select_runtime_assignments(
    assignments: Sequence[ModelAssignment],
    *,
    privacy_tier: PrivacyTier,
    task_type: str,
) -> tuple[ModelAssignment, ...]:
    """Return approved assignments ordered for this privacy tier and task.

    Apple Intelligence is eligible only for lightweight private work. llama.cpp
    is the preferred open-source runtime, then MLX, then Ollama. A cloud
    assignment can remain only on a large problem whose privacy tier already
    permits external processing. Local privacy never keeps a cloud candidate.
    """

    workload = workload_for_task(task_type)
    order = preference_order(workload)
    eligible: list[ModelAssignment] = []
    for assignment in assignments:
        family = runtime_family(assignment)
        if privacy_tier is PrivacyTier.LOCAL and (
            family is RuntimeFamily.CLOUD or not assignment.is_local
        ):
            continue
        if family is RuntimeFamily.CLOUD and workload is not WorkloadClass.LARGE_PROBLEM:
            continue
        if family is RuntimeFamily.APPLE_INTELLIGENCE and workload is not WorkloadClass.LIGHTWEIGHT_PRIVATE:
            continue
        if family not in order:
            continue
        eligible.append(assignment)

    if not eligible:
        raise RoutingModelError(
            "No eligible runtime remains for "
            f"{privacy_tier.value} {workload.value} work"
        )

    ranked = sorted(
        eligible,
        key=lambda assignment: (
            order.index(runtime_family(assignment)),
            0 if assignment.is_primary else 1,
            assignment.priority,
            assignment.model_id,
        ),
    )
    selected: list[ModelAssignment] = []
    for index, assignment in enumerate(ranked):
        selected.append(
            replace(
                assignment,
                assignment_type=(
                    AssignmentType.PRIMARY
                    if index == 0
                    else AssignmentType.FALLBACK
                ),
                priority=1 if index == 0 else index,
            )
        )
    return tuple(selected)
