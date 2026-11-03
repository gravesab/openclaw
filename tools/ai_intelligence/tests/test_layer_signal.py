"""Tests for the live active-layer signal."""

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from tools.ai_intelligence.execution_models import (
    AttemptStatus,
    ExecutionAttempt,
    ExecutionResult,
    ExecutionStatus,
)
from tools.ai_intelligence.layer_signal import (
    ActiveLayerSignal,
    LayerSignalBus,
    build_layer_signal,
    build_mcp_layer_signal,
    server_env_short,
    tokens_per_second,
    write_layer_signal,
    write_mcp_layer_signal,
)
from tools.ai_intelligence.routing_models import (
    AssignmentType,
    FallbackChain,
    ModelAssignment,
    PrivacyTier,
    RoutingDecision,
    RoutingMode,
    RoutingRequest,
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


def decision_for(*candidates: ModelAssignment) -> RoutingDecision:
    return RoutingDecision(
        request=RoutingRequest(component_id="ranchbrain"),
        component_name="RanchBrain",
        task_type="summary",
        privacy_tier=PrivacyTier.LOCAL,
        routing_mode=RoutingMode.PRODUCTION_SAFE,
        chain=FallbackChain.from_assignments(candidates),
    )


def success_result(
    model_id: str,
    provider_name: str,
    duration_ms: int = 1200,
) -> ExecutionResult:
    now = datetime.now(timezone.utc)
    attempt = ExecutionAttempt(
        provider_name=provider_name,
        model_id=model_id,
        status=AttemptStatus.SUCCESS,
        started_at=now,
        finished_at=now,
        duration_ms=duration_ms,
        content="answer",
    )
    return ExecutionResult(
        request_id="req-1",
        component_id="ranchbrain",
        status=ExecutionStatus.SUCCESS,
        attempts=(attempt,),
        content="answer",
        selected_model_id=model_id,
    )


class TokensPerSecondTests(unittest.TestCase):
    def test_ollama_eval_timings(self) -> None:
        self.assertAlmostEqual(
            tokens_per_second(
                "ollama",
                {"eval_count": 100, "eval_duration": 2_000_000_000},
                2500,
            ),
            50.0,
        )

    def test_ollama_missing_timings_is_unknown(self) -> None:
        self.assertIsNone(
            tokens_per_second("ollama", {"response": "x"}, 100)
        )
        self.assertIsNone(tokens_per_second("ollama", None, 100))

    def test_llamacpp_prefers_timings(self) -> None:
        self.assertAlmostEqual(
            tokens_per_second(
                "llama.cpp",
                {
                    "timings": {
                        "predicted_n": 40,
                        "predicted_ms": 1000,
                    },
                    "usage": {"completion_tokens": 40},
                },
                5000,
            ),
            40.0,
        )

    def test_llamacpp_falls_back_to_usage(self) -> None:
        self.assertAlmostEqual(
            tokens_per_second(
                "llama.cpp",
                {"usage": {"completion_tokens": 30}},
                1500,
            ),
            20.0,
        )

    def test_openrouter_usage_over_duration(self) -> None:
        self.assertAlmostEqual(
            tokens_per_second(
                "openrouter",
                {"usage": {"completion_tokens": 60}},
                3000,
            ),
            20.0,
        )

    def test_zero_duration_is_unknown(self) -> None:
        self.assertIsNone(
            tokens_per_second(
                "openrouter",
                {"usage": {"completion_tokens": 60}},
                0,
            )
        )

    def test_unknown_provider_is_unknown(self) -> None:
        self.assertIsNone(
            tokens_per_second("mystery", {"tokens": 5}, 100)
        )


class BuildLayerSignalTests(unittest.TestCase):
    def test_winner_names_apple_layer(self) -> None:
        decision = decision_for(
            assignment(
                "apple-foundation-models",
                "apple-foundation-models",
                "local",
                assignment_type=AssignmentType.PRIMARY,
                priority=1,
            ),
            assignment(
                "ollama-hermes3-8b", "ollama", "local"
            ),
        )
        signal = build_layer_signal(
            decision,
            success_result(
                "apple-foundation-models",
                "apple-foundation-models",
                duration_ms=800,
            ),
            {},
        )
        self.assertEqual(signal.layer, "apple-intelligence")
        self.assertEqual(signal.model_id, "apple-foundation-models")
        self.assertEqual(signal.latency_ms, 800)
        self.assertTrue(signal.ok)
        self.assertIsNone(signal.tokens_per_sec)

    def test_failover_names_serving_layer_with_tps(self) -> None:
        decision = decision_for(
            assignment(
                "apple-foundation-models",
                "apple-foundation-models",
                "local",
                assignment_type=AssignmentType.PRIMARY,
                priority=1,
            ),
            assignment(
                "llama-cpp-qwen3.5-9b", "llama.cpp", "local"
            ),
        )
        signal = build_layer_signal(
            decision,
            success_result(
                "llama-cpp-qwen3.5-9b", "llama.cpp", duration_ms=2000
            ),
            {
                "llama-cpp-qwen3.5-9b": {
                    "timings": {
                        "predicted_n": 50,
                        "predicted_ms": 1000,
                    }
                }
            },
        )
        self.assertEqual(signal.layer, "llama.cpp")
        self.assertAlmostEqual(signal.tokens_per_sec, 50.0)

    def test_failed_result_goes_dark_on_last_layer(self) -> None:
        decision = decision_for(
            assignment(
                "ollama-hermes3-8b",
                "ollama",
                "local",
                assignment_type=AssignmentType.PRIMARY,
                priority=1,
            ),
        )
        now = datetime.now(timezone.utc)
        result = ExecutionResult(
            request_id="req-9",
            component_id="ranchbrain",
            status=ExecutionStatus.FAILED,
            attempts=(
                ExecutionAttempt(
                    provider_name="ollama",
                    model_id="ollama-hermes3-8b",
                    status=AttemptStatus.UNAVAILABLE,
                    started_at=now,
                    finished_at=now,
                    duration_ms=50,
                    error_type="ProviderUnavailableError",
                    error_message="down",
                ),
            ),
        )
        signal = build_layer_signal(decision, result, {})
        self.assertEqual(signal.layer, "ollama")
        self.assertFalse(signal.ok)


class LayerSignalBusTests(unittest.TestCase):
    def test_latest_tracks_emissions(self) -> None:
        bus = LayerSignalBus()
        self.assertIsNone(bus.latest())
        first = build_layer_signal(
            decision_for(
                assignment(
                    "ollama-hermes3-8b",
                    "ollama",
                    "local",
                    assignment_type=AssignmentType.PRIMARY,
                    priority=1,
                )
            ),
            success_result("ollama-hermes3-8b", "ollama"),
            {},
        )
        bus.emit(first)
        bus.emit(first)
        self.assertIs(bus.latest(), first)
        self.assertEqual(bus.emitted_count, 2)


class WriteLayerSignalTests(unittest.TestCase):
    def test_roundtrip_json_file(self) -> None:
        signal = ActiveLayerSignal(
            layer="llama.cpp",
            model_id="llama-cpp-qwen3.5-9b",
            provider_name="llama.cpp",
            latency_ms=1200,
            tokens_per_sec=40.0,
            ok=True,
            request_id="req-1",
            observed_at="2026-10-31T00:00:00+00:00",
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "sub" / "layer-signal.json")
            write_layer_signal(signal, path)
            loaded = json.loads(Path(path).read_text("utf-8"))
            leftovers = [
                name
                for name in Path(tmp, "sub").iterdir()
                if name.suffix == ".tmp"
            ]
        self.assertEqual(loaded["layer"], "llama.cpp")
        self.assertEqual(loaded["tokens_per_sec"], 40.0)
        self.assertEqual(leftovers, [])


class McpLayerSignalTests(unittest.TestCase):
    def test_default_record_matches_viz_shape(self) -> None:
        with patch.dict(
            "os.environ",
            {"OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development"},
        ):
            payload = build_mcp_layer_signal()
        self.assertEqual(payload["layer"], "mcp")
        self.assertEqual(
            payload["model"], "mcp boundary / finance.categorize"
        )
        self.assertEqual(payload["tps"], "-")
        self.assertEqual(
            payload["note"],
            "Apple FM on-device finance classifier local only",
        )
        self.assertEqual(payload["server_env"], "dev")
        self.assertEqual(payload["isolation"], "DEV→DEV / PROD→PROD")

    def test_server_env_short_mapping(self) -> None:
        with patch.dict(
            "os.environ",
            {"OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "production"},
        ):
            self.assertEqual(server_env_short(), "prod")
        with patch.dict(
            "os.environ",
            {"OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT": "development"},
        ):
            self.assertEqual(server_env_short(), "dev")

    def test_write_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "layer-signal.json")
            returned = write_mcp_layer_signal(
                path, model="mcp boundary / ranchbrain", ok=True
            )
            loaded = json.loads(Path(path).read_text("utf-8"))
        self.assertEqual(returned, loaded)
        self.assertEqual(loaded["layer"], "mcp")
        self.assertEqual(
            loaded["model"], "mcp boundary / ranchbrain"
        )

    def test_chain_fields_ride_along(self) -> None:
        payload = build_mcp_layer_signal(
            model="mcp boundary / property.handbook.ingest",
            tool="tasks.create",
            chunks=127,
            tasks_created=12,
            app="property.handbook.ingest",
        )
        self.assertEqual(payload["tool"], "tasks.create")
        self.assertEqual(payload["chunks"], 127)
        self.assertEqual(payload["tasks_created"], 12)
        self.assertEqual(payload["app"], "property.handbook.ingest")
        self.assertEqual(payload["env"], payload["server_env"])

    def test_chain_fields_omitted_when_unknown(self) -> None:
        payload = build_mcp_layer_signal()
        for key in ("tool", "chunks", "tasks_created", "app"):
            self.assertNotIn(key, payload)


if __name__ == "__main__":
    unittest.main()
