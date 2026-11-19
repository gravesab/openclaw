"""Runtime status probes for local model servers.

Availability answers "may I send now"; status answers "what is running."
These probes take an explicit base URL so callers control endpoint policy,
and they never send caller content.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from time import perf_counter
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

STATUS_TIMEOUT_SECONDS = 5.0


@dataclass(frozen=True)
class RuntimeStatus:
    """Observed state of one local model runtime."""

    provider: str
    ok: bool
    model: str | None = None
    latency_ms: int | None = None
    detail: str = ""


def _get_json(url: str, timeout: float) -> dict | None:
    try:
        with urlopen(url, timeout=timeout) as response:
            if response.status != 200:
                return None
            parsed = json.loads(response.read().decode("utf-8"))
    except (OSError, URLError, TimeoutError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


def ollama_runtime_status(
    base_url: str,
    *,
    timeout: float = STATUS_TIMEOUT_SECONDS,
) -> RuntimeStatus:
    """Probe Ollama's tag list for the first served model name."""

    started = perf_counter()
    parsed = _get_json(f"{base_url.rstrip('/')}/api/tags", timeout)
    latency_ms = max(0, round((perf_counter() - started) * 1000))
    if parsed is None:
        return RuntimeStatus(
            provider="ollama",
            ok=False,
            latency_ms=latency_ms,
            detail="tag list unreachable",
        )
    models = parsed.get("models")
    name = None
    if isinstance(models, list) and models:
        first = models[0]
        if isinstance(first, dict) and isinstance(
            first.get("name"), str
        ):
            name = first["name"]
    return RuntimeStatus(
        provider="ollama",
        ok=True,
        model=name,
        latency_ms=latency_ms,
        detail="" if name else "no models listed",
    )


def llamacpp_runtime_status(
    base_url: str,
    *,
    timeout: float = STATUS_TIMEOUT_SECONDS,
) -> RuntimeStatus:
    """Probe llama-server health plus the loaded model id."""

    root = base_url.rstrip("/")
    started = perf_counter()
    try:
        with urlopen(f"{root}/health", timeout=timeout) as response:
            healthy = response.status == 200
    except (OSError, URLError, TimeoutError, ValueError):
        healthy = False
    latency_ms = max(0, round((perf_counter() - started) * 1000))
    if not healthy:
        return RuntimeStatus(
            provider="llama.cpp",
            ok=False,
            latency_ms=latency_ms,
            detail="health check failed",
        )
    parsed = _get_json(f"{root}/v1/models", timeout)
    model: str | None = None
    if parsed is not None:
        data = parsed.get("data")
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict) and isinstance(
                first.get("id"), str
            ):
                model = first["id"]
    return RuntimeStatus(
        provider="llama.cpp",
        ok=True,
        model=model,
        latency_ms=latency_ms,
        detail="" if model else "model id unknown",
    )
