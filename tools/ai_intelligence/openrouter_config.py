"""Configuration and model-name translation for the OpenRouter provider."""

from __future__ import annotations

from dataclasses import dataclass
from os import environ
from urllib.parse import urlparse

from tools.ai_intelligence.ai_environment import (
    AIStackEnv,
    assert_endpoint_allowed,
    stack_env_from_env,
)


class OpenRouterConfigurationError(ValueError):
    """Raised when the OpenRouter fallback is misconfigured."""


API_KEY_ENV = "OPENROUTER_API_KEY"
BASE_URL_ENV = "OPENCLAW_OPENROUTER_BASE_URL"
TIMEOUT_ENV = "OPENCLAW_OPENROUTER_TIMEOUT_SECONDS"
DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"


@dataclass(frozen=True)
class OpenRouterConfig:
    """Cloud fallback endpoint configuration (third-party, both stacks)."""

    base_url: str
    api_key: str
    default_timeout_seconds: float = 60.0
    stack_env: AIStackEnv | None = None

    def __post_init__(self) -> None:
        normalized_url = self.base_url.rstrip("/")
        object.__setattr__(self, "base_url", normalized_url)
        parsed = urlparse(normalized_url)
        if parsed.scheme not in {"http", "https"}:
            raise OpenRouterConfigurationError(
                "OpenRouter base URL must use http or https"
            )
        if not parsed.hostname:
            raise OpenRouterConfigurationError(
                "OpenRouter base URL must include a hostname"
            )
        env = self.stack_env or stack_env_from_env()
        try:
            assert_endpoint_allowed(normalized_url, env)
        except ValueError as exc:
            raise OpenRouterConfigurationError(str(exc)) from exc
        if not self.api_key.strip():
            raise OpenRouterConfigurationError(
                "OpenRouter API key must not be blank"
            )
        if self.default_timeout_seconds <= 0:
            raise OpenRouterConfigurationError(
                "Default timeout must be greater than zero"
            )

    @classmethod
    def from_env(cls) -> "OpenRouterConfig":
        raw_timeout = environ.get(TIMEOUT_ENV, "60")
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise OpenRouterConfigurationError(
                f"{TIMEOUT_ENV} must be numeric"
            ) from exc
        return cls(
            base_url=environ.get(BASE_URL_ENV, DEFAULT_BASE_URL),
            api_key=environ.get(API_KEY_ENV, ""),
            default_timeout_seconds=timeout,
        )


def to_openrouter_model_name(model_id: str) -> str:
    """Translate a routing model ID to an OpenRouter model slug.

    The first dash after the prefix becomes the vendor separator, so
    ``openrouter-moonshotai-kimi-k2`` addresses ``moonshotai/kimi-k2``.
    """

    normalized_id = model_id.strip()
    if not normalized_id:
        raise OpenRouterConfigurationError("model_id must not be blank")
    if not is_openrouter_model_id(normalized_id):
        raise OpenRouterConfigurationError(
            f"Unsupported OpenRouter model ID: {normalized_id}"
        )
    rest = normalized_id[len("openrouter-"):]
    vendor, separator, name = rest.partition("-")
    if not separator or not vendor or not name:
        raise OpenRouterConfigurationError(
            f"OpenRouter model ID needs a vendor and model: "
            f"{normalized_id}"
        )
    return f"{vendor}/{name}"


def is_openrouter_model_id(model_id: str) -> bool:
    """Return whether the model ID belongs to the OpenRouter fallback."""

    return model_id.strip().startswith("openrouter-")


def is_openrouter_configured() -> bool:
    """Return whether an OpenRouter API key is present."""

    return bool(environ.get(API_KEY_ENV, "").strip())
