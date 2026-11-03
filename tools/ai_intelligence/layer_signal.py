"""Live active-layer signal for the AI routing core.

After each execution the engine emits one signal naming the layer that
served the request, with latency, tokens/sec, and model name. Glow and
dashboard consumers read the latest signal; they never infer the layer
from configuration.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping

from tools.ai_intelligence.execution_models import (
    AttemptStatus,
    ExecutionResult,
)
from tools.ai_intelligence.routing_models import RoutingDecision
from tools.ai_intelligence.runtime_selection import (
    RuntimeFamily,
    runtime_family,
)


@dataclass(frozen=True)
class ActiveLayerSignal:
    """One observed layer outcome, ready to render or persist."""

    layer: str
    model_id: str
    provider_name: str
    latency_ms: int
    tokens_per_sec: float | None
    ok: bool
    request_id: str
    observed_at: str

    def as_dict(self) -> dict[str, Any]:
        """Return a JSON-serializable view of the signal."""

        return {
            "layer": self.layer,
            "model_id": self.model_id,
            "provider_name": self.provider_name,
            "latency_ms": self.latency_ms,
            "tokens_per_sec": self.tokens_per_sec,
            "ok": self.ok,
            "request_id": self.request_id,
            "observed_at": self.observed_at,
        }


def tokens_per_second(
    provider_name: str,
    raw_response: Mapping[str, Any] | None,
    duration_ms: int,
) -> float | None:
    """Derive tokens/sec from provider timing metadata, if present.

    Returns None when the provider reports no usable token timing;
    callers must render that as unknown, never as zero throughput.
    """

    if not isinstance(raw_response, Mapping):
        return None
    provider = provider_name.strip().lower()
    try:
        if provider == "ollama":
            count = raw_response.get("eval_count")
            nanos = raw_response.get("eval_duration")
            if _is_positive_number(count) and _is_positive_number(nanos):
                return float(count) / (float(nanos) / 1_000_000_000)
            return None
        if provider == "llama.cpp":
            timings = raw_response.get("timings")
            if isinstance(timings, Mapping):
                predicted = timings.get("predicted_n")
                predicted_ms = timings.get("predicted_ms")
                if _is_positive_number(predicted) and _is_positive_number(
                    predicted_ms
                ):
                    return float(predicted) / (
                        float(predicted_ms) / 1000
                    )
            usage = raw_response.get("usage")
            if isinstance(usage, Mapping):
                completed = usage.get("completion_tokens")
                if _is_positive_number(completed) and duration_ms > 0:
                    return float(completed) / (duration_ms / 1000)
            return None
        if provider == "openrouter":
            usage = raw_response.get("usage")
            if isinstance(usage, Mapping):
                completed = usage.get("completion_tokens")
                if _is_positive_number(completed) and duration_ms > 0:
                    return float(completed) / (duration_ms / 1000)
            return None
    except (TypeError, ValueError, ZeroDivisionError):
        return None
    return None


def _is_positive_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and value > 0
    )


def _layer_for_model(
    decision: RoutingDecision,
    model_id: str,
    provider_name: str,
) -> str:
    for assignment in decision.chain.ordered_candidates:
        if assignment.model_id == model_id:
            return runtime_family(assignment).value
    provider = provider_name.strip().lower()
    if "foundation" in provider or provider.startswith("apple"):
        return RuntimeFamily.APPLE_INTELLIGENCE.value
    if "llama" in provider:
        return RuntimeFamily.LLAMA_CPP.value
    if "mlx" in provider or "omlx" in provider:
        return RuntimeFamily.MLX.value
    if "ollama" in provider:
        return RuntimeFamily.OLLAMA.value
    return RuntimeFamily.CLOUD.value


def build_layer_signal(
    decision: RoutingDecision,
    result: ExecutionResult,
    raw_responses: Mapping[str, Mapping[str, Any] | None] | None = None,
) -> ActiveLayerSignal:
    """Build the active-layer signal for one execution result.

    The winning attempt names the layer; a failed result signals the
    last attempted layer with ok=False so the glow can go dark honestly.
    `raw_responses` maps model_id to that attempt's raw provider payload
    for tokens/sec derivation; attempts without one report unknown.
    """

    raws = raw_responses or {}
    successful = tuple(
        attempt
        for attempt in result.attempts
        if attempt.status is AttemptStatus.SUCCESS
    )
    if successful:
        winner = successful[0]
        ok = True
    else:
        winner = result.attempts[-1]
        ok = False
    return ActiveLayerSignal(
        layer=_layer_for_model(
            decision,
            winner.model_id,
            winner.provider_name,
        ),
        model_id=winner.model_id,
        provider_name=winner.provider_name,
        latency_ms=winner.duration_ms,
        tokens_per_sec=tokens_per_second(
            winner.provider_name,
            raws.get(winner.model_id),
            winner.duration_ms,
        ),
        ok=ok,
        request_id=result.request_id,
        observed_at=datetime.now(timezone.utc).isoformat(),
    )


class LayerSignalBus:
    """In-memory active-layer signal bus (engine-scoped)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._latest: ActiveLayerSignal | None = None
        self._emitted = 0

    def emit(self, signal: ActiveLayerSignal) -> None:
        """Publish a signal as the latest observed layer outcome."""

        with self._lock:
            self._latest = signal
            self._emitted += 1

    def latest(self) -> ActiveLayerSignal | None:
        """Return the latest signal, or None before any execution."""

        with self._lock:
            return self._latest

    @property
    def emitted_count(self) -> int:
        """Return how many signals have been emitted."""

        with self._lock:
            return self._emitted


def _atomic_write_json(path: str, payload: dict[str, Any]) -> None:
    """Atomically write a JSON payload (tmp file plus rename)."""

    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    fd, tmp_path = tempfile.mkstemp(
        dir=directory or None,
        prefix=".layer-signal-",
        suffix=".tmp",
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def write_layer_signal(signal: ActiveLayerSignal, path: str) -> None:
    """Atomically write the latest signal JSON for glow consumers."""

    _atomic_write_json(path, signal.as_dict())


MCP_LAYER_ID = "mcp"
MCP_MODEL_DEFAULT = "mcp boundary / finance.categorize"
MCP_NOTE_DEFAULT = "Apple FM on-device finance classifier local only"
ISOLATION_LABEL = "DEV→DEV / PROD→PROD"


def server_env_short() -> str:
    """Return this box's stack as the short env label (dev or prod)."""

    raw = os.environ.get(
        "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT", "development"
    )
    normalized = raw.strip().lower()
    if normalized in {"production", "prod"}:
        return "prod"
    return "dev"


def build_mcp_layer_signal(
    *,
    model: str = MCP_MODEL_DEFAULT,
    note: str = MCP_NOTE_DEFAULT,
    ok: bool = True,
    latency_ms: int = 0,
    request_id: str = "-",
    server_env: str | None = None,
    observed_at: str | None = None,
) -> dict[str, Any]:
    """Build the MCP boundary layer record for the signal file.

    The boundary is its own viz layer: requests served through MCP are
    recorded as mcp with the boundary operation as the model, so the
    visualizer glow can move there when finance.categorize runs.
    """

    return {
        "layer": MCP_LAYER_ID,
        "model": model,
        "tps": "-",
        "note": note,
        "server_env": server_env or server_env_short(),
        "isolation": ISOLATION_LABEL,
        "ok": ok,
        "latency_ms": latency_ms,
        "request_id": request_id,
        "observed_at": observed_at
        or datetime.now(timezone.utc).isoformat(),
    }


def write_mcp_layer_signal(
    path: str,
    **kwargs: Any,
) -> dict[str, Any]:
    """Build and atomically write the MCP boundary layer record."""

    payload = build_mcp_layer_signal(**kwargs)
    _atomic_write_json(path, payload)
    return payload
