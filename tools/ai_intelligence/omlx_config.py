"""Configuration and model-name translation for the oMLX provider."""

from __future__ import annotations

from dataclasses import dataclass
from os import environ
from urllib.parse import urlparse


class OMLXConfigurationError(ValueError):
    """Raised when oMLX provider configuration is invalid."""


MODEL_NAME_MAP: dict[str, str] = {
    "omlx-qwen3.5-9b-4bit": "Qwen3.5-9B-4bit",
}


@dataclass(frozen=True)
class OMLXConfig:
    """Runtime configuration for the M4 oMLX server."""

    base_url: str
    api_key: str
    default_timeout_seconds: float = 300.0

    def __post_init__(self) -> None:
        normalized_url = self.base_url.rstrip("/")
        object.__setattr__(self, "base_url", normalized_url)
        parsed = urlparse(normalized_url)
        if parsed.scheme not in {"http", "https"}:
            raise OMLXConfigurationError(
                "oMLX base URL must use http or https"
            )
        if not parsed.hostname:
            raise OMLXConfigurationError(
                "oMLX base URL must include a hostname"
            )
        if not self.api_key.strip():
            raise OMLXConfigurationError(
                "oMLX API key must not be blank"
            )
        if self.default_timeout_seconds <= 0:
            raise OMLXConfigurationError(
                "Default timeout must be greater than zero"
            )

    @classmethod
    def from_env(cls) -> "OMLXConfig":
        raw_timeout = environ.get(
            "OPENCLAW_OMLX_TIMEOUT_SECONDS", "300"
        )
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise OMLXConfigurationError(
                "OPENCLAW_OMLX_TIMEOUT_SECONDS must be numeric"
            ) from exc

        return cls(
            base_url=environ.get(
                "OPENCLAW_OMLX_BASE_URL",
                "http://10.0.2.2:8000/v1",
            ),
            api_key=environ.get("OPENCLAW_OMLX_API_KEY", ""),
            default_timeout_seconds=timeout,
        )


def to_omlx_model_name(model_id: str) -> str:
    """Translate an AI Intelligence model ID into an oMLX model name."""

    normalized_id = model_id.strip()
    if not normalized_id:
        raise OMLXConfigurationError("model_id must not be blank")
    try:
        return MODEL_NAME_MAP[normalized_id]
    except KeyError as exc:
        raise OMLXConfigurationError(
            f"Unsupported oMLX model ID: {normalized_id}"
        ) from exc


def is_omlx_model_id(model_id: str) -> bool:
    """Return whether a model ID belongs to the oMLX provider."""

    return model_id.strip().startswith("omlx-")
