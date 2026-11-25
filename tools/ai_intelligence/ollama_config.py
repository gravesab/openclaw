"""Configuration and model-name translation for the Ollama provider."""

from __future__ import annotations

from dataclasses import dataclass
from os import environ
from urllib.parse import urlparse

from tools.ai_intelligence.egress_allowlist import host_allowed


class OllamaConfigurationError(ValueError):
    """Raised when Ollama provider configuration is invalid."""


MODEL_NAME_MAP: dict[str, str] = {
    "ollama-hermes3-8b": "hermes3:8b",
    "ollama-gemma3-12b": "gemma3:12b",
    "ollama-gemma4-12b-mlx": "gemma4:12b-mlx",
    "ollama-llama3.2-3b": "llama3.2:3b",
    "ollama-llama3.3": "llama3.3:latest",
    "ollama-glm-4.7-flash": "glm-4.7-flash",
    "ollama-nomic-embed-text": "nomic-embed-text",
}


def _is_allowed_host(hostname: str) -> bool:
    """Loopback allowlist. RFC1918 requires RANCH_ALLOW_PRIVATE_LAN=1."""
    return host_allowed(hostname, service="ollama", allowlist_env="OLLAMA_HOST_ALLOWLIST")


@dataclass(frozen=True)
class OllamaConfig:
    """Runtime configuration for an Ollama server."""

    base_url: str
    default_timeout_seconds: float = 60.0

    def __post_init__(self) -> None:
        normalized_url = self.base_url.rstrip("/")
        object.__setattr__(self, "base_url", normalized_url)
        parsed = urlparse(normalized_url)
        if parsed.scheme not in {"http", "https"}:
            raise OllamaConfigurationError("Ollama base URL must use http or https")
        if not parsed.hostname:
            raise OllamaConfigurationError("Ollama base URL must include a hostname")
        if not _is_allowed_host(parsed.hostname):
            raise OllamaConfigurationError(
                f"DEV-only egress blocked: {parsed.hostname} not allowed. "
                f"Use 127.0.0.1, localhost, or ::1"
            )
        if self.default_timeout_seconds <= 0:
            raise OllamaConfigurationError("Default timeout must be greater than zero")

    @classmethod
    def from_env(cls) -> "OllamaConfig":
        """Build configuration from environment variables."""
        base_url = environ.get("OPENCLAW_OLLAMA_BASE_URL", "http://127.0.0.1:11434")
        raw_timeout = environ.get("OPENCLAW_OLLAMA_TIMEOUT_SECONDS", "60")
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise OllamaConfigurationError("OPENCLAW_OLLAMA_TIMEOUT_SECONDS must be numeric") from exc
        return cls(base_url=base_url, default_timeout_seconds=timeout)


def to_ollama_model_name(model_id: str) -> str:
    """Translate an AI Intelligence model ID into an Ollama model name."""
    normalized_id = model_id.strip()
    if not normalized_id:
        raise OllamaConfigurationError("model_id must not be blank")
    try:
        return MODEL_NAME_MAP[normalized_id]
    except KeyError as exc:
        raise OllamaConfigurationError(f"Unsupported Ollama model ID: {normalized_id}") from exc


def is_ollama_model_id(model_id: str) -> bool:
    """Return whether a model ID belongs to the Ollama provider."""
    return model_id.strip().startswith("ollama-")
