"""Tests wiring runtime selection and the layer signal into the live path."""

from __future__ import annotations

import unittest
from typing import Any

from tools.ai_intelligence.apple_layer import AppleLayerHook
from tools.ai_intelligence.database import (
    ComponentRecord,
    DeploymentAssignmentRecord,
)
from tools.ai_intelligence.execution_engine import ExecutionEngine
from tools.ai_intelligence.execution_models import (
    ProviderRequest,
    ProviderResponse,
)
from tools.ai_intelligence.layer_signal import LayerSignalBus
from tools.ai_intelligence.provider import ProviderUnavailableError
from tools.ai_intelligence.router import AIRouter
from tools.ai_intelligence.routing_models import (
    AssignmentType,
    FallbackChain,
    ModelAssignment,
    PrivacyTier,
    RoutingDecision,
    RoutingMode,
    RoutingRequest,
)
from tools.ai_intelligence.runtime_selection import (
    select_runtime_assignments,
)


def component(
    *,
    component_id: str = "ranchbrain",
    task_type: str = "summary",
    privacy_tier: str = "local",
) -> ComponentRecord:
    return ComponentRecord(
        component_id=component_id,
        display_name="RanchBrain",
        description="Knowledge system",
        privacy_tier=privacy_tier,
        task_type=task_type,
        active=True,
        metadata={},
    )


def record(
    model_id: str,
    provider: str,
    deployment: str,
    *,
    assignment_type: str = "fallback",
    priority: int = 2,
    task_type: str = "summary",
    privacy_tier: str = "local",
) -> DeploymentAssignmentRecord:
    return DeploymentAssignmentRecord(
        component_id="ranchbrain",
        component_name="RanchBrain",
        component_privacy_tier=privacy_tier,
        task_type=task_type,
        assignment_type=assignment_type,
        priority=priority,
        model_id=model_id,
        model_name=model_id,
        provider=provider,
        deployment=deployment,
        model_status="active",
        routing_mode="production-safe",
        configuration_source="deployment_map.json",
        assignment_reason="Configured assignment",
        human_approved=True,
        effective_from=None,
    )


def assignment(
    model_id: str,
    provider: str,
    deployment: str,
    *,
    assignment_type: AssignmentType = AssignmentType.FALLBACK,
    priority: int = 2,
) -> ModelAssignment:
    return ModelAssignment(
        component_id="ranchbrain",
        component_name="RanchBrain",
        component_privacy_tier=PrivacyTier.LOCAL,
        task_type="summary",
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


class FakeDatabase:
    def __init__(
        self,
        stored_component: ComponentRecord,
        assignments: tuple[DeploymentAssignmentRecord, ...],
    ) -> None:
        self.stored_component = stored_component
        self.assignments = assignments

    def get_component(
        self, component_id: str
    ) -> ComponentRecord | None:
        return self.stored_component

    def get_active_assignments(
        self, component_id: str
    ) -> tuple[DeploymentAssignmentRecord, ...]:
        return self.assignments


class RouterSelectionTests(unittest.TestCase):
    def test_none_selector_preserves_legacy_order(self) -> None:
        database = FakeDatabase(
            component(),
            (
                record(
                    "ollama-hermes3-8b",
                    "ollama",
                    "local",
                    assignment_type="primary",
                    priority=1,
                ),
                record(
                    "apple-foundation-models",
                    "apple-foundation-models",
                    "local",
                ),
            ),
        )
        decision = AIRouter(database).route(
            RoutingRequest(component_id="ranchbrain")
        )
        self.assertEqual(
            decision.candidate_model_ids,
            ("ollama-hermes3-8b", "apple-foundation-models"),
        )

    def test_selector_orders_local_first(self) -> None:
        database = FakeDatabase(
            component(),
            (
                record(
                    "ollama-hermes3-8b",
                    "ollama",
                    "local",
                    assignment_type="primary",
                    priority=1,
                ),
                record(
                    "apple-foundation-models",
                    "apple-foundation-models",
                    "local",
                ),
                record(
                    "llama-cpp-qwen3.5-9b", "llama.cpp", "local"
                ),
            ),
        )
        router = AIRouter(
            database, runtime_selector=select_runtime_assignments
        )
        decision = router.route(
            RoutingRequest(component_id="ranchbrain")
        )
        self.assertEqual(
            decision.candidate_model_ids,
            (
                "apple-foundation-models",
                "llama-cpp-qwen3.5-9b",
                "ollama-hermes3-8b",
            ),
        )

    def test_selector_drops_cloud_on_local_privacy(self) -> None:
        database = FakeDatabase(
            component(),
            (
                record(
                    "openrouter-moonshotai-kimi-k2",
                    "openrouter",
                    "cloud",
                    assignment_type="primary",
                    priority=1,
                ),
                record(
                    "ollama-hermes3-8b", "ollama", "local"
                ),
            ),
        )
        router = AIRouter(
            database, runtime_selector=select_runtime_assignments
        )
        decision = router.route(
            RoutingRequest(component_id="ranchbrain")
        )
        self.assertEqual(
            decision.candidate_model_ids, ("ollama-hermes3-8b",)
        )

    def test_hook_drops_unavailable_apple(self) -> None:
        database = FakeDatabase(
            component(),
            (
                record(
                    "apple-foundation-models",
                    "apple-foundation-models",
                    "local",
                    assignment_type="primary",
                    priority=1,
                ),
                record(
                    "llama-cpp-qwen3.5-9b", "llama.cpp", "local"
                ),
            ),
        )
        from functools import partial

        router = AIRouter(
            database,
            runtime_selector=partial(
                select_runtime_assignments,
                apple_hook=AppleLayerHook(
                    is_available=lambda: False
                ),
            ),
        )
        decision = router.route(
            RoutingRequest(component_id="ranchbrain")
        )
        self.assertEqual(
            decision.candidate_model_ids,
            ("llama-cpp-qwen3.5-9b",),
        )


class FakeProvider:
    name = "ollama"

    def __init__(
        self,
        model_id: str,
        raw: dict[str, Any] | None = None,
        available: bool = True,
    ) -> None:
        self._model_id = model_id
        self._raw = raw or {}
        self._available = available

    def supports_model(self, model_id: str) -> bool:
        return model_id == self._model_id

    def is_available(self) -> bool:
        return self._available

    def execute(
        self, request: ProviderRequest
    ) -> ProviderResponse:
        return ProviderResponse(
            provider_name="ollama",
            model_id=self._model_id,
            content="answer",
            duration_ms=2000,
            raw_response=self._raw,
        )


class FakeRegistry:
    def __init__(self, providers: list[FakeProvider]) -> None:
        self._providers = providers

    def get_provider(self, model_id: str) -> FakeProvider:
        for provider in self._providers:
            if provider.supports_model(model_id):
                return provider
        raise ProviderUnavailableError(model_id)


class FakeRouter:
    def __init__(self, decision: RoutingDecision) -> None:
        self._decision = decision

    def route(self, request: RoutingRequest) -> RoutingDecision:
        return self._decision


class EngineSignalTests(unittest.TestCase):
    def _decision(self, *model_ids: str) -> RoutingDecision:
        candidates = tuple(
            assignment(
                model_id,
                "ollama",
                "local",
                assignment_type=(
                    AssignmentType.PRIMARY
                    if index == 0
                    else AssignmentType.FALLBACK
                ),
                priority=index + 1,
            )
            for index, model_id in enumerate(model_ids)
        )
        return RoutingDecision(
            request=RoutingRequest(component_id="ranchbrain"),
            component_name="RanchBrain",
            task_type="summary",
            privacy_tier=PrivacyTier.LOCAL,
            routing_mode=RoutingMode.PRODUCTION_SAFE,
            chain=FallbackChain.from_assignments(candidates),
        )

    def test_success_emits_layer_signal(self) -> None:
        bus = LayerSignalBus()
        engine = ExecutionEngine(
            FakeRouter(self._decision("ollama-hermes3-8b")),
            FakeRegistry(
                [
                    FakeProvider(
                        "ollama-hermes3-8b",
                        raw={
                            "eval_count": 100,
                            "eval_duration": 2_000_000_000,
                        },
                    )
                ]
            ),
            signal_bus=bus,
        )
        result = engine.execute(
            RoutingRequest(component_id="ranchbrain"), prompt="hi"
        )
        self.assertTrue(result.succeeded)
        signal = bus.latest()
        self.assertIsNotNone(signal)
        assert signal is not None
        self.assertEqual(signal.layer, "ollama")
        self.assertEqual(signal.model_id, "ollama-hermes3-8b")
        self.assertAlmostEqual(signal.tokens_per_sec, 50.0)
        self.assertTrue(signal.ok)

    def test_failure_emits_dark_signal(self) -> None:
        bus = LayerSignalBus()
        engine = ExecutionEngine(
            FakeRouter(self._decision("ollama-hermes3-8b")),
            FakeRegistry(
                [FakeProvider("ollama-hermes3-8b", available=False)]
            ),
            signal_bus=bus,
        )
        result = engine.execute(
            RoutingRequest(component_id="ranchbrain"), prompt="hi"
        )
        self.assertTrue(result.failed)
        signal = bus.latest()
        self.assertIsNotNone(signal)
        assert signal is not None
        self.assertFalse(signal.ok)
        self.assertEqual(signal.layer, "ollama")

    def test_no_bus_means_no_signal(self) -> None:
        engine = ExecutionEngine(
            FakeRouter(self._decision("ollama-hermes3-8b")),
            FakeRegistry([FakeProvider("ollama-hermes3-8b")]),
        )
        result = engine.execute(
            RoutingRequest(component_id="ranchbrain"), prompt="hi"
        )
        self.assertTrue(result.succeeded)


if __name__ == "__main__":
    unittest.main()
