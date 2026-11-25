"""Configuration and model-name translation for the llama.cpp provider."""

from __future__ import annotations

from dataclasses import dataclass
from os import environ
from urllib.parse import urlparse

from tools.ai_intelligence.ai_environment import (
    AIStackEnv,
    assert_endpoint_allowed,
    stack_env_from_env,
)


class LlamaCppConfigurationError(ValueError):
    """Raised when the llama.cpp runtime is misconfigured."""


MODEL_NAME_MAP: dict[str, str] = {
    "llama-cpp-qwen3.5-9b": "qwen3.5-9b",
}

BASE_URL_ENV = "OPENCLAW_LLAMACPP_BASE_URL"
TIMEOUT_ENV = "OPENCLAW_LLAMACPP_TIMEOUT_SECONDS"
DEFAULT_BASE_URL = "http://127.0.0.1:8088"


@dataclass(frozen=True)
class LlamaCppConfig:
    """Local llama-server (OpenAI-compatible) endpoint configuration."""

    base_url: str
    default_timeout_seconds: float = 60.0
    stack_env: AIStackEnv | None = None

    def __post_init__(self) -> None:
        normalized_url = self.base_url.rstrip("/")
        object.__setattr__(self, "base_url", normalized_url)
        parsed = urlparse(normalized_url)
        if parsed.scheme not in {"http", "https"}:
            raise LlamaCppConfigurationError(
                "llama.cpp base URL must use http or https"
            )
        if not parsed.hostname:
            raise LlamaCppConfigurationError(
                "llama.cpp base URL must include a hostname"
            )
        env = self.stack_env or stack_env_from_env()
        try:
            assert_endpoint_allowed(normalized_url, env)
        except ValueError as exc:
            raise LlamaCppConfigurationError(str(exc)) from exc
        if self.default_timeout_seconds <= 0:
            raise LlamaCppConfigurationError(
                "Default timeout must be greater than zero"
            )

    @classmethod
    def from_env(cls) -> "LlamaCppConfig":
        raw_timeout = environ.get(TIMEOUT_ENV, "60")
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise LlamaCppConfigurationError(
                f"{TIMEOUT_ENV} must be numeric"
            ) from exc
        return cls(
            base_url=environ.get(BASE_URL_ENV, DEFAULT_BASE_URL),
            default_timeout_seconds=timeout,
        )


def to_llamacpp_model_name(model_id: str) -> str:
    """Translate a routing model ID to the llama-server model name."""

    normalized_id = model_id.strip()
    if not normalized_id:
        raise LlamaCppConfigurationError("model_id must not be blank")
    try:
        return MODEL_NAME_MAP[normalized_id]
    except KeyError as exc:
        raise LlamaCppConfigurationError(
            f"Unsupported llama.cpp model ID: {normalized_id}"
        ) from exc


def is_llamacpp_model_id(model_id: str) -> bool:
    """Return whether the model ID belongs to the llama.cpp runtime."""

    return model_id.strip().startswith("llama-cpp-")


def is_llamacpp_configured() -> bool:
    """Return whether the operator pointed at a llama.cpp server.

    Registration stays opt-in: unset means the default stack keeps its
    tested provider shape, and no build ever probes the network.
    """

    return bool(environ.get(BASE_URL_ENV, "").strip())
