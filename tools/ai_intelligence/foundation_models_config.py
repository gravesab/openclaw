"""Configuration for the local Apple Foundation Models helper."""

from __future__ import annotations

from dataclasses import dataclass
from os import environ
from pathlib import Path


class FoundationModelsConfigurationError(ValueError):
    """Raised when the Foundation Models helper is unsafe to invoke."""


MODEL_ID = "apple-foundation-models"
AI_INTELLIGENCE_ENVIRONMENT_ENV = "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT"


@dataclass(frozen=True)
class FoundationModelsConfig:
    """DEV-only configuration for a local macOS helper."""

    command: Path
    default_timeout_seconds: float = 30.0

    def __post_init__(self) -> None:
        if not self.command.is_absolute():
            raise FoundationModelsConfigurationError(
                "Foundation Models helper command must be absolute"
            )
        if self.default_timeout_seconds <= 0:
            raise FoundationModelsConfigurationError(
                "Foundation Models timeout must be greater than zero"
            )

    @classmethod
    def from_env(cls) -> "FoundationModelsConfig":
        raw_timeout = environ.get(
            "OPENCLAW_APPLE_FOUNDATION_MODELS_TIMEOUT_SECONDS", "30"
        )
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise FoundationModelsConfigurationError(
                "OPENCLAW_APPLE_FOUNDATION_MODELS_TIMEOUT_SECONDS must be numeric"
            ) from exc

        return cls(
            command=Path(
                environ.get("OPENCLAW_APPLE_FOUNDATION_MODELS_COMMAND", "")
            ),
            default_timeout_seconds=timeout,
        )


def is_foundation_models_configured() -> bool:
    """Return whether the DEV-only helper was explicitly configured."""

    return (
        environ.get(AI_INTELLIGENCE_ENVIRONMENT_ENV) == "development"
        and bool(
            environ.get("OPENCLAW_APPLE_FOUNDATION_MODELS_COMMAND", "").strip()
        )
    )


def is_foundation_models_model_id(model_id: str) -> bool:
    """Return whether a model ID belongs to the Foundation Models provider."""

    return model_id.strip() == MODEL_ID
