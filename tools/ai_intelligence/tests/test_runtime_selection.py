"""Tests for local runtime selection and the unattached cloud slot."""

from __future__ import annotations

import unittest

from tools.ai_intelligence.cloud_attachment import UnattachedCloudModels
from tools.ai_intelligence.routing_models import (
    AssignmentType,
    ModelAssignment,
    PrivacyTier,
    RoutingMode,
    RoutingModelError,
)
from tools.ai_intelligence.runtime_selection import (
    select_runtime_assignments,
    workload_for_task,
)


def assignment(
    model_id: str,
    *,
    provider: str,
    deployment: str = "local",
    assignment_type: AssignmentType = AssignmentType.FALLBACK,
    priority: int = 1,
    task_type: str = "knowledge",
    privacy: PrivacyTier = PrivacyTier.LOCAL,
) -> ModelAssignment:
    return ModelAssignment(
        component_id="ranchbrain",
        component_name="RanchBrain",
        component_privacy_tier=privacy,
        task_type=task_type,
        assignment_type=assignment_type,
        priority=priority,
        model_id=model_id,
        model_name=model_id,
        provider=provider,
        deployment=deployment,
        model_status="active",
        routing_mode=RoutingMode.PRODUCTION_SAFE,
        human_approved=True,
    )


class RuntimeSelectionTests(unittest.TestCase):
    def test_lightweight_work_prefers_apple_then_llama_cpp(self) -> None:
        selected = select_runtime_assignments(
            (
                assignment(
                    "ollama-llama3.2-3b",
                    provider="ollama",
                    assignment_type=AssignmentType.PRIMARY,
                    task_type="routine_local_query",
                ),
                assignment(
                    "omlx-qwen3.5-9b-4bit",
                    provider="omlx",
                    priority=2,
                    task_type="routine_local_query",
                ),
                assignment(
                    "llama-cpp-qwen3.5-9b",
                    provider="llama.cpp",
                    priority=3,
                    task_type="routine_local_query",
                ),
                assignment(
                    "apple-foundation-models",
                    provider="Apple Foundation Models",
                    priority=4,
                    task_type="routine_local_query",
                ),
            ),
            privacy_tier=PrivacyTier.LOCAL,
            task_type="routine_local_query",
        )

        self.assertEqual(
            tuple(item.model_id for item in selected),
            (
                "apple-foundation-models",
                "llama-cpp-qwen3.5-9b",
                "omlx-qwen3.5-9b-4bit",
                "ollama-llama3.2-3b",
            ),
        )
        self.assertEqual(selected[0].assignment_type, AssignmentType.PRIMARY)

    def test_deep_work_prefers_llama_cpp_over_mlx_and_skips_apple(self) -> None:
        selected = select_runtime_assignments(
            (
                assignment(
                    "apple-foundation-models",
                    provider="Apple Foundation Models",
                    assignment_type=AssignmentType.PRIMARY,
                ),
                assignment("omlx-qwen3.5-9b-4bit", provider="omlx", priority=1),
                assignment("llama-cpp-qwen3.5-9b", provider="llama.cpp", priority=2),
                assignment("ollama-hermes3-8b", provider="ollama", priority=3),
            ),
            privacy_tier=PrivacyTier.LOCAL,
            task_type="private_property_data",
        )

        self.assertEqual(
            tuple(item.model_id for item in selected),
            (
                "llama-cpp-qwen3.5-9b",
                "omlx-qwen3.5-9b-4bit",
                "ollama-hermes3-8b",
            ),
        )
        self.assertEqual(workload_for_task("private_property_data").value, "deep-local")

    def test_local_privacy_drops_cloud_even_for_a_large_problem(self) -> None:
        selected = select_runtime_assignments(
            (
                assignment(
                    "openai-frontier",
                    provider="OpenAI",
                    deployment="cloud",
                    assignment_type=AssignmentType.PRIMARY,
                    privacy=PrivacyTier.LOCAL,
                    task_type="swift",
                ),
                assignment(
                    "llama-cpp-qwen3.5-9b",
                    provider="llama.cpp",
                    task_type="swift",
                ),
            ),
            privacy_tier=PrivacyTier.LOCAL,
            task_type="swift",
        )

        self.assertEqual(
            tuple(item.model_id for item in selected),
            ("llama-cpp-qwen3.5-9b",),
        )

    def test_large_problem_keeps_cloud_after_local_runtimes(self) -> None:
        selected = select_runtime_assignments(
            (
                assignment(
                    "openai-frontier",
                    provider="OpenAI",
                    deployment="cloud",
                    assignment_type=AssignmentType.PRIMARY,
                    privacy=PrivacyTier.EXTERNAL_APPROVED,
                    task_type="long_context_engineering",
                ),
                assignment(
                    "ollama-hermes3-8b",
                    provider="ollama",
                    privacy=PrivacyTier.EXTERNAL_APPROVED,
                    task_type="long_context_engineering",
                ),
                assignment(
                    "llama-cpp-qwen3.5-9b",
                    provider="llama.cpp",
                    priority=2,
                    privacy=PrivacyTier.EXTERNAL_APPROVED,
                    task_type="long_context_engineering",
                ),
            ),
            privacy_tier=PrivacyTier.EXTERNAL_APPROVED,
            task_type="long_context_engineering",
        )

        self.assertEqual(
            tuple(item.model_id for item in selected),
            (
                "llama-cpp-qwen3.5-9b",
                "ollama-hermes3-8b",
                "openai-frontier",
            ),
        )

    def test_cloud_only_local_request_fails_closed(self) -> None:
        with self.assertRaises(RoutingModelError):
            select_runtime_assignments(
                (
                    assignment(
                        "openai-frontier",
                        provider="OpenAI",
                        deployment="cloud",
                        assignment_type=AssignmentType.PRIMARY,
                    ),
                ),
                privacy_tier=PrivacyTier.LOCAL,
                task_type="knowledge",
            )

    def test_cloud_slot_starts_unattached(self) -> None:
        self.assertIsNone(UnattachedCloudModels().provider())
