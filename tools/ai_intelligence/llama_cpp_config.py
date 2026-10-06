"""Configuration for a local llama.cpp server.

llama.cpp is optional. The router loads it only when a base URL is set, and it
does not assume a model is installed until the model map names one.
"""

from __future__ import annotations

from dataclasses import dataclass
from os import environ
from urllib.parse import urlparse


class LlamaCppConfigurationError(ValueError):
    """Raised when llama.cpp configuration is invalid."""


@dataclass(frozen=True)
class LlamaCppConfig:
    """Runtime configuration for llama-server's OpenAI-compatible API."""

    base_url: str
    model_names: dict[str, str]
    api_key: str = ""
    default_timeout_seconds: float = 300.0

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
        if self.default_timeout_seconds <= 0:
            raise LlamaCppConfigurationError(
                "llama.cpp timeout must be greater than zero"
            )
        invalid_names = [
            key
            for key, value in self.model_names.items()
            if not key.startswith("llama-cpp-") or not value.strip()
        ]
        if invalid_names:
            raise LlamaCppConfigurationError(
                "llama.cpp model ids must use the llama-cpp- prefix "
                "and a served name"
            )

    @classmethod
    def from_env(cls) -> "LlamaCppConfig":
        raw_timeout = environ.get("OPENCLAW_LLAMA_CPP_TIMEOUT_SECONDS", "300")
        try:
            timeout = float(raw_timeout)
        except ValueError as exc:
            raise LlamaCppConfigurationError(
                "OPENCLAW_LLAMA_CPP_TIMEOUT_SECONDS must be numeric"
            ) from exc
        return cls(
            base_url=environ.get("OPENCLAW_LLAMA_CPP_BASE_URL", ""),
            model_names=parse_model_map(
                environ.get("OPENCLAW_LLAMA_CPP_MODELS", "")
            ),
            api_key=environ.get("OPENCLAW_LLAMA_CPP_API_KEY", ""),
            default_timeout_seconds=timeout,
        )


def is_llama_cpp_configured() -> bool:
    """Return whether an operator pointed the router at a llama.cpp server."""

    return bool(environ.get("OPENCLAW_LLAMA_CPP_BASE_URL", "").strip())


def parse_model_map(raw: str) -> dict[str, str]:
    """Parse `llama-cpp-id=served-name` pairs separated by commas."""

    mapping: dict[str, str] = {}
    for item in raw.split(","):
        entry = item.strip()
        if not entry:
            continue
        model_id, separator, served_name = entry.partition("=")
        if not separator or not model_id.strip() or not served_name.strip():
            raise LlamaCppConfigurationError(
                "OPENCLAW_LLAMA_CPP_MODELS entries must use id=served-name"
            )
        mapping[model_id.strip()] = served_name.strip()
    return mapping


def is_llama_cpp_model_id(model_id: str) -> bool:
    """Return whether a model id belongs to the llama.cpp provider."""

    return model_id.strip().startswith("llama-cpp-")
